/*
 * bridge_client implementation — see bridge_client.h.
 *
 * One worker thread owns the socket and loops:
 *   - send the pending focus key, if any
 *   - select() with a short timeout, then recv() when readable
 *   - dispatch each complete line to the select callback
 *
 * On any socket error the connection is dropped and retried, so the overlay can
 * be started, stopped or restarted freely. Nothing here blocks the game.
 *
 * Winsock is resolved dynamically (no ws2_32 import), so the DLL keeps
 * importing only KERNEL32. Do not call winsock functions directly.
 */

#include <winsock2.h>
#include <windows.h>
#include <stdint.h>

#include "bridge_client.h"

#define BRIDGE_DEFAULT_PORT 45780
#define BRIDGE_POLL_MS 100
#define BRIDGE_RECONNECT_WAIT_MS 500
#define BRIDGE_BUFFER_MAX 1024

typedef int (WINAPI *fn_wsastartup)(WORD version, WSADATA* data);
typedef SOCKET (WINAPI *fn_socket)(int af, int type, int protocol);
typedef int (WINAPI *fn_connect)(SOCKET s, const struct sockaddr* name, int namelen);
typedef int (WINAPI *fn_send)(SOCKET s, const char* buf, int len, int flags);
typedef int (WINAPI *fn_recv)(SOCKET s, char* buf, int len, int flags);
typedef int (WINAPI *fn_select)(int nfds, fd_set* readfds, fd_set* writefds,
                                fd_set* exceptfds, struct timeval* timeout);
typedef int (WINAPI *fn_closesocket)(SOCKET s);

typedef struct BridgeWinsock {
    HMODULE lib;
    fn_wsastartup startup;
    fn_socket socket_fn;
    fn_connect connect_fn;
    fn_send send_fn;
    fn_recv recv_fn;
    fn_select select_fn;
    fn_closesocket closesocket_fn;
    int ready;
} BridgeWinsock;

static BridgeWinsock g_ws;
static bridge_log_fn g_log;
static bridge_select_fn g_on_select;
static int g_port = BRIDGE_DEFAULT_PORT;
static SOCKET g_sock = INVALID_SOCKET;
static volatile LONG64 g_pending_key;         /* latest focus key, 0 = none */
static volatile LONG64 g_pending_raise_key;   /* latest raise key, 0 = none */
static LONG g_started;
static LONG g_reported_down;            /* log once per connection state */

static void LogLine(const char* message) {
    if (g_log) g_log(message);
}

static int EnsureWinsock(void) {
    HMODULE lib;
    if (g_ws.ready) return 1;
    lib = LoadLibraryA("ws2_32.dll");
    if (!lib) return 0;
    g_ws.lib = lib;
    g_ws.startup = (fn_wsastartup)GetProcAddress(lib, "WSAStartup");
    g_ws.socket_fn = (fn_socket)GetProcAddress(lib, "socket");
    g_ws.connect_fn = (fn_connect)GetProcAddress(lib, "connect");
    g_ws.send_fn = (fn_send)GetProcAddress(lib, "send");
    g_ws.recv_fn = (fn_recv)GetProcAddress(lib, "recv");
    g_ws.select_fn = (fn_select)GetProcAddress(lib, "select");
    g_ws.closesocket_fn = (fn_closesocket)GetProcAddress(lib, "closesocket");
    if (!g_ws.startup || !g_ws.socket_fn || !g_ws.connect_fn || !g_ws.send_fn
            || !g_ws.recv_fn || !g_ws.select_fn || !g_ws.closesocket_fn) {
        return 0;
    }
    {
        WSADATA data;
        if (g_ws.startup(MAKEWORD(2, 2), &data) != 0) return 0;
    }
    g_ws.ready = 1;
    return 1;
}

/* ── formatting (no CRT) ─────────────────────────────────────────────────── */

static int Append(char* dst, int pos, const char* src) {
    while (*src) dst[pos++] = *src++;
    return pos;
}

static int AppendInt64(char* dst, int pos, int64_t value) {
    char digits[24];
    int n = 0;
    int negative = value < 0;
    uint64_t magnitude = negative ? (uint64_t)(-value) : (uint64_t)value;
    if (magnitude == 0) digits[n++] = '0';
    while (magnitude > 0) {
        digits[n++] = (char)('0' + (int)(magnitude % 10u));
        magnitude /= 10u;
    }
    if (negative) dst[pos++] = '-';
    while (n > 0) dst[pos++] = digits[--n];
    return pos;
}

/* ── connection ──────────────────────────────────────────────────────────── */

static void CloseSocket(void) {
    if (g_sock != INVALID_SOCKET) {
        g_ws.closesocket_fn(g_sock);
        g_sock = INVALID_SOCKET;
    }
}

static int OpenSocket(void) {
    struct sockaddr_in address;

    if (!EnsureWinsock()) return 0;
    g_sock = g_ws.socket_fn(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (g_sock == INVALID_SOCKET) return 0;

    address.sin_family = AF_INET;
    address.sin_port = (unsigned short)(((unsigned)(g_port & 0xFF) << 8)
                                        | ((unsigned)g_port >> 8));
    address.sin_addr.s_addr = 0x0100007Fu;   /* 127.0.0.1, network order */

    if (g_ws.connect_fn(g_sock, (const struct sockaddr*)&address,
                        (int)sizeof address) != 0) {
        CloseSocket();
        return 0;
    }
    return 1;
}

static void SendBridgeMessage(const char* type, int64_t key) {
    char message[96];
    int pos = 0;
    pos = Append(message, pos, "{\"v\":1,\"type\":\"");
    pos = Append(message, pos, type);
    pos = Append(message, pos, "\",\"key\":");
    pos = AppendInt64(message, pos, key);
    pos = Append(message, pos, "}\n");
    if (g_ws.send_fn(g_sock, message, pos, 0) <= 0) {
        CloseSocket();
    }
}

/* Minimal scan for a select command; the overlay controls the exact shape:
 *   {"v":1,"type":"select","key":341}                                      */
static int ParseSelectKey(const char* line, int length, int64_t* out_key) {
    int i;
    int seen_select = 0;
    int64_t value = 0;
    int negative = 0;
    int have_digits = 0;

    for (i = 0; i + 6 <= length; i++) {
        if (line[i] == 's' && line[i + 1] == 'e' && line[i + 2] == 'l'
                && line[i + 3] == 'e' && line[i + 4] == 'c'
                && line[i + 5] == 't') {
            seen_select = 1;
            break;
        }
    }
    if (!seen_select) return 0;

    for (i = 0; i + 5 < length; i++) {
        if (line[i] == '"' && line[i + 1] == 'k' && line[i + 2] == 'e'
                && line[i + 3] == 'y' && line[i + 4] == '"') {
            int j = i + 5;
            while (j < length && (line[j] == ' ' || line[j] == '\t')) j++;
            if (j < length && line[j] == ':') j++;
            while (j < length && (line[j] == ' ' || line[j] == '\t')) j++;
            if (j < length && line[j] == '-') { negative = 1; j++; }
            while (j < length && line[j] >= '0' && line[j] <= '9') {
                value = value * 10 + (line[j] - '0');
                have_digits = 1;
                j++;
            }
            break;
        }
    }
    if (!have_digits) return 0;
    *out_key = negative ? -value : value;
    return 1;
}

static void DispatchLine(const char* line, int length) {
    int64_t key;
    if (ParseSelectKey(line, length, &key) && g_on_select) {
        g_on_select(key);
    }
}

/* ── worker ──────────────────────────────────────────────────────────────── */

static DWORD WINAPI BridgeWorker(LPVOID unused) {
    char buffer[BRIDGE_BUFFER_MAX];
    int used = 0;

    (void)unused;
    for (;;) {
        int64_t key;

        if (g_sock == INVALID_SOCKET) {
            if (!OpenSocket()) {
                if (InterlockedExchange(&g_reported_down, 1) == 0) {
                    LogLine("bridge: overlay not reachable on 127.0.0.1");
                }
                Sleep(BRIDGE_RECONNECT_WAIT_MS);
                continue;
            }
            used = 0;
            if (InterlockedExchange(&g_reported_down, 0) == 1) {
                LogLine("bridge: overlay connected");
            }
        }

        key = (int64_t)InterlockedExchange64(&g_pending_key, 0);
        if (key != 0) SendBridgeMessage("focus", key);
        key = (int64_t)InterlockedExchange64(&g_pending_raise_key, 0);
        if (key != 0) SendBridgeMessage("raise", key);
        if (g_sock == INVALID_SOCKET) continue;

        {
            fd_set readable;
            struct timeval wait;
            int ready;
            int n;
            int i;

            FD_ZERO(&readable);
            FD_SET(g_sock, &readable);
            wait.tv_sec = 0;
            wait.tv_usec = BRIDGE_POLL_MS * 1000;
            ready = g_ws.select_fn(0, &readable, NULL, NULL, &wait);
            if (ready <= 0) continue;

            n = g_ws.recv_fn(g_sock, buffer + used, BRIDGE_BUFFER_MAX - used - 1, 0);
            if (n <= 0) {
                CloseSocket();
                continue;
            }
            used += n;
            buffer[used] = '\0';

            while (1) {
                int newline = -1;
                for (i = 0; i < used; i++) {
                    if (buffer[i] == '\n') { newline = i; break; }
                }
                if (newline < 0) break;
                DispatchLine(buffer, newline);
                {
                    int remaining = used - newline - 1;
                    for (i = 0; i < remaining; i++) {
                        buffer[i] = buffer[newline + 1 + i];
                    }
                    used = remaining;
                }
            }
            if (used >= BRIDGE_BUFFER_MAX - 1) used = 0;   /* junk without newline */
        }
    }
}

/* ── public API ──────────────────────────────────────────────────────────── */

void bridge_client_start(int port, bridge_log_fn log_fn, bridge_select_fn on_select) {
    if (port > 0) g_port = port;
    if (log_fn) g_log = log_fn;
    if (on_select) g_on_select = on_select;
    if (InterlockedCompareExchange(&g_started, 1, 0) != 0) return;

    if (!CreateThread(NULL, 0, BridgeWorker, NULL, 0, NULL)) {
        g_started = 0;
        return;
    }
    LogLine("bridge: sender ready");
}

void bridge_client_send_key(int64_t key) {
    if (!g_started || key == 0) return;
    InterlockedExchange64(&g_pending_key, key);
}

void bridge_client_send_raise(int64_t key) {
    if (!g_started || key == 0) return;
    InterlockedExchange64(&g_pending_raise_key, key);
}

/*
 * bridge_client implementation — see bridge_client.h.
 *
 * Wire format (one line per request, matching the overlay's core/bridge.py):
 *
 *     {"v":1,"type":"focus","key":341}\n
 *
 * Connection policy: connect, send, close, per request. Selections are
 * infrequent and a persistent socket would need reconnect logic for an overlay
 * that starts later anyway. The worker never touches the game's state.
 */

#include <winsock2.h>
#include <windows.h>
#include <stdint.h>

#include "bridge_client.h"

#define BRIDGE_DEFAULT_PORT 45780
#define BRIDGE_SEND_TIMEOUT_MS 2000u

typedef int (WINAPI *fn_wsastartup)(WORD version, WSADATA* data);
typedef SOCKET (WINAPI *fn_socket)(int af, int type, int protocol);
typedef int (WINAPI *fn_connect)(SOCKET s, const struct sockaddr* name, int namelen);
typedef int (WINAPI *fn_send)(SOCKET s, const char* buf, int len, int flags);
typedef int (WINAPI *fn_closesocket)(SOCKET s);
typedef int (WINAPI *fn_wsacleanup)(void);
typedef int (WINAPI *fn_setsockopt)(SOCKET s, int level, int name,
                                    const char* value, int len);

typedef struct BridgeWinsock {
    HMODULE lib;
    fn_wsastartup startup;
    fn_socket socket_fn;
    fn_connect connect_fn;
    fn_send send_fn;
    fn_closesocket closesocket_fn;
    fn_wsacleanup cleanup;
    fn_setsockopt setsockopt_fn;
    int ready;
} BridgeWinsock;

static BridgeWinsock g_ws;
static bridge_log_fn g_log;
static int g_port = BRIDGE_DEFAULT_PORT;
static HANDLE g_wake;                 /* auto-reset: new key queued */
static volatile LONG64 g_pending_key; /* latest key, 0 = nothing */
static LONG g_started;
static LONG g_last_connect_failed;    /* for one-line-per-state logging */

static void LogLine(const char* message) {
    if (g_log) g_log(message);
}

static void* ResolveProc(HMODULE lib, const char* name) {
    return (void*)GetProcAddress(lib, name);
}

static int EnsureWinsock(void) {
    HMODULE lib;
    if (g_ws.ready) return 1;
    lib = LoadLibraryA("ws2_32.dll");
    if (!lib) return 0;
    g_ws.lib = lib;
    g_ws.startup = (fn_wsastartup)ResolveProc(lib, "WSAStartup");
    g_ws.socket_fn = (fn_socket)ResolveProc(lib, "socket");
    g_ws.connect_fn = (fn_connect)ResolveProc(lib, "connect");
    g_ws.send_fn = (fn_send)ResolveProc(lib, "send");
    g_ws.closesocket_fn = (fn_closesocket)ResolveProc(lib, "closesocket");
    g_ws.cleanup = (fn_wsacleanup)ResolveProc(lib, "WSACleanup");
    g_ws.setsockopt_fn = (fn_setsockopt)ResolveProc(lib, "setsockopt");
    if (!g_ws.startup || !g_ws.socket_fn || !g_ws.connect_fn || !g_ws.send_fn
            || !g_ws.closesocket_fn) {
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

static int BuildFocusMessage(int64_t key, char* out, int capacity) {
    int pos = 0;
    pos = Append(out, pos, "{\"v\":1,\"type\":\"focus\",\"key\":");
    pos = AppendInt64(out, pos, key);
    pos = Append(out, pos, "}\n");
    if (pos >= capacity) return 0;
    return pos;
}

/* ── transport ───────────────────────────────────────────────────────────── */

static void DeliverKey(int64_t key) {
    SOCKET sock;
    struct sockaddr_in address;
    char message[96];
    int length;
    DWORD timeout = BRIDGE_SEND_TIMEOUT_MS;

    if (!EnsureWinsock()) return;
    length = BuildFocusMessage(key, message, (int)sizeof message);
    if (length <= 0) return;

    sock = g_ws.socket_fn(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return;

    if (g_ws.setsockopt_fn) {
        g_ws.setsockopt_fn(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&timeout,
                           (int)sizeof timeout);
    }

    address.sin_family = AF_INET;
    address.sin_port = (unsigned short)(((unsigned)(g_port & 0xFF) << 8)
                                        | ((unsigned)g_port >> 8));
    address.sin_addr.s_addr = 0x0100007Fu;   /* 127.0.0.1, network order */

    if (g_ws.connect_fn(sock, (const struct sockaddr*)&address,
                        (int)sizeof address) != 0) {
        g_ws.closesocket_fn(sock);
        if (InterlockedExchange(&g_last_connect_failed, 1) == 0) {
            LogLine("bridge: overlay not reachable on 127.0.0.1 "
                    "(is the overlay running?)");
        }
        return;
    }
    if (InterlockedExchange(&g_last_connect_failed, 0) == 1) {
        LogLine("bridge: overlay reachable again");
    }

    g_ws.send_fn(sock, message, length, 0);
    g_ws.closesocket_fn(sock);
}

static DWORD WINAPI BridgeWorker(LPVOID unused) {
    (void)unused;
    for (;;) {
        int64_t key;
        WaitForSingleObject(g_wake, INFINITE);
        key = (int64_t)InterlockedExchange64(&g_pending_key, 0);
        if (key != 0) DeliverKey(key);
    }
}

/* ── public API ──────────────────────────────────────────────────────────── */

void bridge_client_start(int port, bridge_log_fn log_fn) {
    if (port > 0) g_port = port;
    if (log_fn) g_log = log_fn;
    if (InterlockedCompareExchange(&g_started, 1, 0) != 0) return;

    g_wake = CreateEventA(NULL, FALSE, FALSE, NULL);   /* auto-reset */
    if (!g_wake) {
        g_started = 0;
        return;
    }
    if (!CreateThread(NULL, 0, BridgeWorker, NULL, 0, NULL)) {
        CloseHandle(g_wake);
        g_wake = NULL;
        g_started = 0;
        return;
    }
    LogLine("bridge: sender ready");
}

void bridge_client_send_key(int64_t key) {
    if (!g_wake || key == 0) return;
    InterlockedExchange64(&g_pending_key, key);
    SetEvent(g_wake);
}

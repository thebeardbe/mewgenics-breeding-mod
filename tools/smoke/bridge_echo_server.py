"""Tiny loopback server for tools/smoke: reply to a focus with a select.

Used by the local Wine test for the bidirectional bridge. Not part of the app.

    python3 tools/smoke/bridge_echo_server.py [port]

Prints every line received, and answers the first focus with a select command
for key 423.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 45799
REPLY_KEY = 423
RUN_SECONDS = int(os.environ.get("BRIDGE_ECHO_SECONDS", "12"))


def handle(conn: socket.socket) -> None:
    buffer = b""
    replied = False
    with conn:
        while True:
            try:
                chunk = conn.recv(4096)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                print("server received:", line.decode("utf-8", "replace"), flush=True)
                if not replied:
                    replied = True
                    reply = json.dumps(
                        {"v": 1, "type": "select", "key": REPLY_KEY}
                    ).encode("utf-8") + b"\n"
                    conn.sendall(reply)
                    print("server sent: select", REPLY_KEY, flush=True)


def main() -> int:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", PORT))
    server.listen(5)
    server.settimeout(0.5)
    print(f"echo server listening on 127.0.0.1:{PORT}", flush=True)

    deadline = time.time() + RUN_SECONDS
    while time.time() < deadline:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
    server.close()
    print("echo server done", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

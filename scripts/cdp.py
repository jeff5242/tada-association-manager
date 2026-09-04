#!/usr/bin/env python3
"""在報到機本機透過 Chromium CDP（127.0.0.1:9222）執行 JS。

用法（SSH 進樹莓派後）：
  python3 ~/cdp.py 'document.title'
  python3 ~/cdp.py 'location.href="https://tada-ai.org.tw/kiosk/"'

畫面截圖另用：grim /tmp/screen.png（Wayland 原生工具，不走 CDP）。
"""
import base64
import json
import os
import socket
import struct
import sys
import urllib.request

DEBUG_HOST = "127.0.0.1:9222"


def find_page_ws():
    tabs = json.load(urllib.request.urlopen(f"http://{DEBUG_HOST}/json", timeout=5))
    pages = [t for t in tabs if t.get("type") == "page"]
    if not pages:
        sys.exit("找不到分頁")
    return pages[0]["webSocketDebuggerUrl"]


def ws_connect(url):
    from urllib.parse import urlparse

    u = urlparse(url)
    s = socket.create_connection((u.hostname, u.port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(
        (
            f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    return s


def ws_send(s, obj):
    data = json.dumps(obj).encode()
    hdr = bytearray([0x81])
    n = len(data)
    if n < 126:
        hdr.append(0x80 | n)
    elif n < 65536:
        hdr.append(0x80 | 126)
        hdr += struct.pack(">H", n)
    else:
        hdr.append(0x80 | 127)
        hdr += struct.pack(">Q", n)
    mask = os.urandom(4)
    hdr += mask
    s.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_recv(s):
    def rd(n):
        d = b""
        while len(d) < n:
            chunk = s.recv(n - len(d))
            if not chunk:
                sys.exit("連線中斷")
            d += chunk
        return d

    hdr = rd(2)
    ln = hdr[1] & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", rd(2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", rd(8))[0]
    return rd(ln)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    expr = sys.argv[1]
    s = ws_connect(find_page_ws())
    ws_send(
        s,
        {
            "id": 1,
            "method": "Runtime.evaluate",
            "params": {"expression": expr, "returnByValue": True, "awaitPromise": True},
        },
    )
    while True:
        msg = json.loads(ws_recv(s))
        if msg.get("id") == 1:
            result = msg.get("result", {}).get("result", {})
            if "value" in result:
                print(json.dumps(result["value"], ensure_ascii=False))
            else:
                print(json.dumps(result, ensure_ascii=False))
            break


if __name__ == "__main__":
    main()

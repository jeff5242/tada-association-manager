#!/usr/bin/env python3
"""把 Chromium 視窗移到指定座標並全螢幕（用 CDP，勝過 Wayland 下失效的 --window-position）。
用法：cdp-fullscreen.py <debug_port> <x> <y>
labwc/Xwayland 下，全螢幕會落在含該座標的螢幕上 → 精準指定視窗去哪顆螢幕。"""
import base64
import hashlib  # noqa: F401  (握手驗證省略，本機 127.0.0.1 專用)
import json
import os
import socket
import struct
import sys
import time
import urllib.request

PORT, X, Y = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])


def targets():
    return json.load(urllib.request.urlopen(f'http://127.0.0.1:{PORT}/json', timeout=5))


page = None
for _ in range(30):   # 最多等 30 秒讓 Chromium 起來
    try:
        pages = [t for t in targets() if t['type'] == 'page']
        if pages:
            page = pages[0]
            break
    except Exception:
        pass
    time.sleep(1)
if not page:
    sys.exit('chromium debug port not ready')

path = page['webSocketDebuggerUrl'].split(str(PORT), 1)[1]
s = socket.create_connection(('127.0.0.1', PORT), timeout=10)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n'
           f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n'
           'Sec-WebSocket-Version: 13\r\n\r\n').encode())
buf = b''
while b'\r\n\r\n' not in buf:
    buf += s.recv(4096)


def send(obj):
    data = json.dumps(obj).encode()
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    ln = len(data)
    if ln < 126:
        hdr = struct.pack('!BB', 0x81, 0x80 | ln)
    elif ln < 65536:
        hdr = struct.pack('!BBH', 0x81, 0xFE, ln)
    else:
        hdr = struct.pack('!BBQ', 0x81, 0xFF, ln)
    s.sendall(hdr + mask + masked)


def recv_id(want):
    while True:
        hdr = s.recv(2)
        ln = hdr[1] & 0x7F
        if ln == 126:
            ln = struct.unpack('!H', s.recv(2))[0]
        elif ln == 127:
            ln = struct.unpack('!Q', s.recv(8))[0]
        data = b''
        while len(data) < ln:
            data += s.recv(ln - len(data))
        msg = json.loads(data)
        if msg.get('id') == want:
            return msg


send({'id': 1, 'method': 'Browser.getWindowForTarget', 'params': {'targetId': page['id']}})
win = recv_id(1)['result']['windowId']

# labwc 依「視窗當下位置」決定全螢幕落在哪顆螢幕 → 必須先移過去、確認就位、再全螢幕
mid = 10
for attempt in range(6):
    mid += 1
    send({'id': mid, 'method': 'Browser.setWindowBounds',
          'params': {'windowId': win, 'bounds': {'windowState': 'normal', 'left': X, 'top': Y,
                                                 'width': 480, 'height': 320}}})
    recv_id(mid)
    time.sleep(1.5)
    mid += 1
    send({'id': mid, 'method': 'Browser.getWindowForTarget', 'params': {'targetId': page['id']}})
    b = recv_id(mid)['result']['bounds']
    if abs(b.get('left', -9999) - X) <= 60 and abs(b.get('top', -9999) - Y) <= 60:
        break
else:
    print('warn: window never reached target pos, bounds now', b)

send({'id': 30, 'method': 'Browser.setWindowBounds',
      'params': {'windowId': win, 'bounds': {'windowState': 'fullscreen'}}})
recv_id(30)
time.sleep(1)
send({'id': 31, 'method': 'Browser.getWindowForTarget', 'params': {'targetId': page['id']}})
print('final', recv_id(31)['result']['bounds'])

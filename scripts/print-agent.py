#!/usr/bin/env python3
"""TADA 報到列印代理（樹莓派本機服務）

報到機頁面（Chromium）在報到成功後 POST http://127.0.0.1:8043/print，
本服務把「姓名／會員編號／桌號／QR」渲染成點陣圖，
以 Star raster 指令直送 TSP650II（TCP 9100），不經 CUPS、不需 sudo。

端點：
  GET  /health   服務與印表機連線狀態
  GET  /test     列印測試單
  POST /print    {"name","member_no","table_no","qr","title","footer"} → 列印
  POST /preview  同 /print 參數，只產生 /tmp/slip-preview.png 不送印（除錯用）

印表機位址：優先讀 ~/.config/tada-printer.conf 的 PRINTER_IP=...；
沒有設定時自動從 NetworkManager 共享網段的 DHCP 租約檔取第一台裝置。
"""
import json
import os
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image, ImageDraw, ImageFont
import qrcode

LISTEN_ADDR = ("127.0.0.1", 8043)
PRINTER_PORT = 9100
CONF_PATH = os.path.expanduser("~/.config/tada-printer.conf")
LEASE_PATH = "/var/lib/NetworkManager/dnsmasq-eth0.leases"
FONT_REGULAR = os.path.expanduser("~/fonts/NotoSansCJKtc-Regular.otf")
FONT_BOLD = os.path.expanduser("~/fonts/NotoSansCJKtc-Bold.otf")
FONT_FALLBACK = "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf"
PAPER_DOTS = 576          # 80mm 紙、72mm 可印寬 @203dpi
ROW_BYTES = PAPER_DOTS // 8


def scan_for_printer():
    """掃 eth0 共享網段找開 9100 埠的裝置（印表機換 IP 時的備援）。"""
    for i in range(2, 255):
        ip = f"10.42.0.{i}"
        try:
            with socket.create_connection((ip, PRINTER_PORT), timeout=0.15):
                return ip
        except OSError:
            continue
    return None


def save_printer_ip(ip):
    try:
        os.makedirs(os.path.dirname(CONF_PATH), exist_ok=True)
        with open(CONF_PATH, "w") as f:
            f.write(f"PRINTER_IP={ip}\n")
    except OSError:
        pass


def find_printer_ip():
    conf_ip = None
    try:
        with open(CONF_PATH) as f:
            for line in f:
                if line.startswith("PRINTER_IP="):
                    conf_ip = line.split("=", 1)[1].strip() or None
    except OSError:
        pass
    if conf_ip and printer_reachable(conf_ip, timeout=1):
        return conf_ip
    try:
        with open(LEASE_PATH) as f:
            first = f.readline().split()
            if len(first) >= 3 and printer_reachable(first[2], timeout=1):
                save_printer_ip(first[2])
                return first[2]
    except OSError:
        pass
    found = scan_for_printer()
    if found:
        save_printer_ip(found)
        return found
    return conf_ip  # 全部失敗：回報設定值，由呼叫端回傳連線錯誤


def printer_reachable(ip, timeout=2, retries=3):
    # Star 網卡的 9100 一次僅接受一條連線：連續探測會被拒，須小退避重試
    for attempt in range(retries):
        try:
            with socket.create_connection((ip, PRINTER_PORT), timeout=timeout):
                return True
        except OSError:
            if attempt < retries - 1:
                time.sleep(0.6)
    return False


def font(size, bold=False):
    path = FONT_BOLD if bold else FONT_REGULAR
    if not os.path.exists(path):
        path = FONT_FALLBACK
    return ImageFont.truetype(path, size)


def draw_center(draw, y, text, fnt, width=PAPER_DOTS):
    x0, y0, x1, y1 = draw.textbbox((0, y), text, font=fnt)
    draw.text(((width - (x1 - x0)) // 2 - x0, y), text, font=fnt, fill=0)
    return y1 + 8


def render_slip(data):
    """把報到資料畫成 1-bit 點陣圖（寬 576）。"""
    name = str(data.get("name") or "").strip()
    member_no = str(data.get("member_no") or "").strip()
    table_no = str(data.get("table_no") or "").strip()
    title = str(data.get("title") or "第六屆會員大會・報到").strip()
    footer = str(data.get("footer") or "").strip()
    qr_text = str(data.get("qr") or "").strip()

    img = Image.new("L", (PAPER_DOTS, 2200), 255)
    d = ImageDraw.Draw(img)
    y = 16
    y = draw_center(d, y, "台灣科技農企業發展協會", font(30))
    y = draw_center(d, y, title, font(40, bold=True))
    y += 8
    d.line([(24, y), (PAPER_DOTS - 24, y)], fill=0, width=3)
    y += 18

    if name:
        y = draw_center(d, y, name, font(76, bold=True))
    if member_no:
        y = draw_center(d, y, f"會員編號 {member_no}", font(32))
    if table_no:
        y += 14
        y = draw_center(d, y, f"桌號 {table_no}", font(96, bold=True))
    if qr_text:
        y += 16
        qr = qrcode.QRCode(border=1, box_size=8,
                           error_correction=qrcode.constants.ERROR_CORRECT_M)
        qr.add_data(qr_text)
        qr.make(fit=True)
        qimg = qr.make_image(fill_color="black", back_color="white").convert("L")
        if qimg.width > 320:
            qimg = qimg.resize((320, 320), Image.NEAREST)
        img.paste(qimg, ((PAPER_DOTS - qimg.width) // 2, y))
        y += qimg.height + 6
    if footer:
        y += 6
        y = draw_center(d, y, footer, font(26))
    y = draw_center(d, y + 4, time.strftime("%Y-%m-%d %H:%M:%S"), font(24))
    y += 24
    return img.crop((0, 0, PAPER_DOTS, y)).convert("1")


def star_raster(img):
    """1-bit 影像 → Star raster 位元流（含進紙與裁刀）。"""
    if img.width != PAPER_DOTS:
        img = img.resize((PAPER_DOTS, img.height * PAPER_DOTS // img.width))
    raw = img.tobytes()  # mode "1"：每列 72 bytes，1=白 0=黑（PIL: 1 bit/px，bit set=white）
    out = bytearray()
    out += b"\x1b*rA"          # 進入 raster 模式
    out += b"\x1b*rP0\x00"     # 連續紙（頁長 0）
    n1, n2 = ROW_BYTES & 0xFF, ROW_BYTES >> 8
    for row in range(img.height):
        line = raw[row * ROW_BYTES:(row + 1) * ROW_BYTES]
        out += b"b" + bytes([n1, n2]) + bytes(b ^ 0xFF for b in line)  # 反相：1=印
    out += b"\x1b*rC"          # 頁結束 → 進紙＋裁切
    out += b"\x1b*rB"          # 離開 raster 模式
    return bytes(out)


def send_to_printer(payload, retries=4):
    ip = find_printer_ip()
    if not ip:
        return False, "printer_ip_unknown"
    last_err = None
    for attempt in range(retries):
        try:
            with socket.create_connection((ip, PRINTER_PORT), timeout=5) as s:
                s.sendall(payload)
            return True, ip
        except OSError as e:
            last_err = e
            if attempt < retries - 1:
                time.sleep(0.8)
    return False, f"{ip}: {last_err}"


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._json(200, {"ok": True})

    def do_GET(self):
        if self.path.startswith("/health"):
            ip = find_printer_ip()
            self._json(200, {"ok": True, "printer_ip": ip,
                             "reachable": bool(ip and printer_reachable(ip))})
        elif self.path.startswith("/test"):
            img = render_slip({"name": "測試列印", "member_no": "00000000",
                               "table_no": "T1", "qr": "https://tada-ai.org.tw/",
                               "footer": "TADA 報到列印測試"})
            ok, info = send_to_printer(star_raster(img))
            self._json(200 if ok else 502, {"ok": ok, "info": info})
        else:
            self._json(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"ok": False, "error": "bad_json"})
            return
        if self.path.startswith("/preview"):
            img = render_slip(data)
            img.save("/tmp/slip-preview.png")
            self._json(200, {"ok": True, "preview": "/tmp/slip-preview.png",
                             "size": [img.width, img.height]})
        elif self.path.startswith("/print"):
            ok, info = send_to_printer(star_raster(render_slip(data)))
            self._json(200 if ok else 502, {"ok": ok, "info": info})
        else:
            self._json(404, {"ok": False, "error": "not_found"})

    def log_message(self, fmt, *args):
        pass  # 常駐服務不刷 journal；錯誤由回應碼表達


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN_ADDR, Handler).serve_forever()

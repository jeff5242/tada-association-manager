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
HEAD_DOTS = 576           # 印字頭全寬（80mm 紙、72mm 可印區 @203dpi）
ROW_BYTES = HEAD_DOTS // 8


def content_dots():
    """實際紙寬的可印點數：conf 設 PAPER_MM=58 時內容縮到 400 點並靠右。"""
    try:
        with open(CONF_PATH) as f:
            for line in f:
                if line.startswith("PAPER_MM="):
                    if line.split("=", 1)[1].strip() == "58":
                        return 384   # 尺規實測：紙可印範圍＝印字頭左側 0~384 點
    except OSError:
        pass
    return HEAD_DOTS


PAPER_DOTS = HEAD_DOTS  # render_slip 以 content_dots() 為準；此常數保留給舊引用


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


# Code 39 編碼表（9 元素 窄n/寬w，條/空交錯、以條開始）；僅收錄會員編號會用到的字元
CODE39 = {
    "0": "nnnwwnwnn", "1": "wnnwnnnnw", "2": "nnwwnnnnw", "3": "wnwwnnnnn",
    "4": "nnnwwnnnw", "5": "wnnwwnnnn", "6": "nnwwwnnnn", "7": "nnnwnnwnw",
    "8": "wnnwnnwnn", "9": "nnwwnnwnn", "-": "nwnnnnwnw", "*": "nwnnwnwnn",
}


def code39_img(text, height=96, narrow=2, wide=5):
    """會員編號 → Code 39 條碼影像；含起止符，字元不支援時回 None。"""
    seq = "*" + str(text).upper() + "*"
    bars = []
    for ch in seq:
        pat = CODE39.get(ch)
        if pat is None:
            return None
        for i, c in enumerate(pat):
            bars.append((i % 2 == 0, wide if c == "w" else narrow))
        bars.append((False, narrow))          # 字元間窄空白
    total = sum(bw for _, bw in bars)
    img = Image.new("L", (total, height), 255)
    d = ImageDraw.Draw(img)
    x = 0
    for is_bar, bw in bars:
        if is_bar:
            d.rectangle([x, 0, x + bw - 1, height], fill=0)
        x += bw
    return img


def render_slip(data):
    """把報到資料畫成 1-bit 點陣圖（寬 576）。"""
    name = str(data.get("name") or "").strip()
    member_no = str(data.get("member_no") or "").strip()
    table_no = str(data.get("table_no") or "").strip()
    title = str(data.get("title") or "第六屆會員大會・報到").strip()
    footer = str(data.get("footer") or "").strip()
    qr_text = str(data.get("qr") or "").strip()

    w = content_dots()
    sc = w / HEAD_DOTS          # 58mm 紙時等比縮小字級
    fs = lambda n: max(14, int(n * sc))
    img = Image.new("L", (w, 2400), 255)
    d = ImageDraw.Draw(img)
    y = 16
    y = draw_center(d, y, "台灣科技農企業發展協會", font(fs(30)), w)
    y = draw_center(d, y, title, font(fs(40), bold=True), w)
    y += 8
    d.line([(16, y), (w - 16, y)], fill=0, width=3)
    y += 18

    if name:
        y = draw_center(d, y, name, font(fs(76), bold=True), w)
    if member_no:
        y = draw_center(d, y, f"會員編號 {member_no}", font(fs(52), bold=True), w)
    if table_no:
        y += 14
        y = draw_center(d, y, f"桌號 {table_no}", font(fs(96), bold=True), w)
    checklist = [str(c).strip() for c in (data.get("checklist") or []) if str(c).strip()]
    if checklist:
        y += 16
        d.line([(16, y), (w - 16, y)], fill=0, width=2)
        y += 14
        box = fs(40)
        fnt_c = font(fs(38), bold=True)
        col_w = w // 2
        row_h = box + 22
        for i, label in enumerate(checklist):
            cx = (i % 2) * col_w + fs(28)
            cy = y + (i // 2) * row_h
            d.rectangle([cx, cy, cx + box, cy + box], outline=0, width=4)
            d.text((cx + box + 12, cy - fs(4)), label, font=fnt_c, fill=0)
        y += ((len(checklist) + 1) // 2) * row_h + 6
        d.line([(16, y), (w - 16, y)], fill=0, width=2)
        y += 10
    notice = str(data.get("notice") or "").strip()
    if notice:
        y += 8
        for size in (34, 30, 26, 22, 18):   # 窄紙自動縮字避免爆框
            fnt_n = font(fs(size), bold=True)
            x0, y0, x1, y1 = d.textbbox((0, y), notice, font=fnt_n)
            if (x1 - x0) + fs(12) * 2 <= w - 8:
                break
        pad = fs(12)
        bw = (x1 - x0) + pad * 2
        bx = (w - bw) // 2
        d.rectangle([bx, y, bx + bw, y1 + pad], outline=0, width=4)
        d.text((bx + pad - x0, y + pad // 2), notice, font=fnt_n, fill=0)
        y = y1 + pad + 12
    barcode = str(data.get("barcode") or "").strip()
    if barcode:
        y += 14
        bimg = code39_img(barcode)
        if bimg is not None and bimg.width > w - 12:
            bimg = code39_img(barcode, narrow=1, wide=3)   # 過長時縮窄（編號含-時）
        if bimg is not None and bimg.width <= w - 4:
            img.paste(bimg, ((w - bimg.width) // 2, y))
            y += bimg.height + 8
    if qr_text:
        y += 16
        qr = qrcode.QRCode(border=1, box_size=8,
                           error_correction=qrcode.constants.ERROR_CORRECT_M)
        qr.add_data(qr_text)
        qr.make(fit=True)
        qimg = qr.make_image(fill_color="black", back_color="white").convert("L")
        qmax = min(320, w - 40)
        if qimg.width > qmax:
            qimg = qimg.resize((qmax, qmax), Image.NEAREST)
        img.paste(qimg, ((w - qimg.width) // 2, y))
        y += qimg.height + 6
    if footer:
        y += 6
        y = draw_center(d, y, footer, font(fs(26)), w)
    y = draw_center(d, y + 4, time.strftime("%Y-%m-%d %H:%M:%S"), font(fs(24)), w)
    y += 24
    img = img.crop((0, 0, w, y))
    if w < HEAD_DOTS:
        # 窄紙走印字頭左側（實測：右對齊會被切右半）→ 內容貼齊左緣
        full = Image.new("L", (HEAD_DOTS, y), 255)
        full.paste(img, (0, 0))
        img = full
    return img.convert("1")


def star_raster(img):
    """1-bit 影像 → Star raster 位元流（含進紙與裁刀）。"""
    if img.width != HEAD_DOTS:
        img = img.resize((HEAD_DOTS, img.height * HEAD_DOTS // img.width))
    raw = img.tobytes()  # mode "1"：每列 72 bytes，1=白 0=黑（PIL: 1 bit/px，bit set=white）
    out = bytearray()
    # 防卡死：若前一筆傳輸中斷、印表機殘留在 raster 模式吞資料，
    # 先送「離開 raster」把它救回；正常狀態下此指令無害。
    out += b"\x1b*rB"
    out += b"\x1b*rA"          # 進入 raster 模式
    out += b"\x1b*rP0\x00"     # 連續紙（頁長 0）
    n1, n2 = ROW_BYTES & 0xFF, ROW_BYTES >> 8
    for row in range(img.height):
        line = raw[row * ROW_BYTES:(row + 1) * ROW_BYTES]
        out += b"b" + bytes([n1, n2]) + bytes(b ^ 0xFF for b in line)  # 反相：1=印
    out += b"\x1b\x0c\x00"     # raster form feed：印出整頁＋進紙裁切（實機驗證）
    out += b"\x1b*rB"          # 離開 raster 模式
    return bytes(out)


def send_to_printer(payload, retries=4):
    ip = find_printer_ip()
    if not ip:
        return False, "printer_ip_unknown"
    last_err = None
    for attempt in range(retries):
        try:
            with socket.create_connection((ip, PRINTER_PORT), timeout=10) as s:
                s.sendall(payload)
                # 大張單據：立刻斷線會被印表機丟包。送完先半關寫入端，
                # 等對方消化完（讀到 EOF 或逾時）再關，確保整份資料進機器。
                try:
                    s.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                s.settimeout(6)
                try:
                    while s.recv(4096):
                        pass
                except OSError:
                    pass
                time.sleep(0.5 + min(2.5, len(payload) / 60000))
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

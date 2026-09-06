#!/usr/bin/env python3
"""
TADA 報到機本地代理（kiosk-agent）— 離線優先架構
====================================================
跑在樹莓派 127.0.0.1:8080，報到頁改由本代理供應。代理模擬報到頁會用到的
Supabase REST 表面，讀寫一律先走本地 SQLite，背景執行緒負責與 server 同步：

  · 連線正常：報到寫入本地後立即回應，佇列背景回放到 Supabase（回應時間不受網路影響）
  · 斷線：名冊查詢、報到、列印全部照常（本地快照），佇列累積
  · 復線：佇列自動回放；server 回 already_checked_in 即視為兩機 merge 完成（先到先贏）
  · 裝置管理：開機向 tada_devices 註冊（heartbeat 每輪更新），後台把 managed 打開
    後才會下載名冊快照（server 端控制哪些機器持有離線資料）

測試開關：touch /tmp/kiosk-agent-offline 可強制離線模式（模擬斷網）。
限制：離線期間無法簽發線上投票 token（uuids 回空陣列）；紙本領票流程不受影響。
"""
import json
import os
import re
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = '1.0.0'
PORT = 8080
SB_URL = os.environ.get('TADA_SB_URL', 'https://ldjugtfxtxnpvkqvjxew.supabase.co')
SB_KEY = os.environ.get('TADA_SB_KEY', 'sb_publishable_08XiE2fH7iY_nlr_K4NQ4w_kJZPkjnj')  # anon 公開金鑰（與網頁同）
SITE = 'https://tada-ai.org.tw'
DB_PATH = os.path.expanduser('~/kiosk-agent.db')
OFFLINE_FLAG = '/tmp/kiosk-agent-offline'   # 測試用：存在即強制離線
SYNC_INTERVAL = 10                          # 秒
SNAPSHOT_INTERVAL = 60                      # 名冊快照最短間隔（秒）

PAGE_ASSETS = {  # 離線供應報到頁需要的靜態資源：本地路徑 → 來源
    '/assets/liff-common.js': SITE + '/assets/liff-common.js',
    '/assets/qrcode.min.js': 'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js',
    '/assets/line/oa-qr.png': SITE + '/assets/line/oa-qr.png',
}


# ── curl 包裝（本專案鐵律：Supabase 一律 curl，urllib 有 SSL 問題）─────────
def curl(url, method='GET', body=None, headers=None, timeout=6):
    cmd = ['curl', '-s', '--max-time', str(timeout), '-X', method, url,
           '-H', f'apikey: {SB_KEY}', '-H', f'Authorization: Bearer {SB_KEY}',
           '-H', 'Content-Type: application/json',
           '-w', '\n%{http_code}']
    for h in (headers or []):
        cmd += ['-H', h]
    if body is not None:
        cmd += ['-d', json.dumps(body) if not isinstance(body, str) else body]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 4).stdout
        payload, _, code = out.rpartition('\n')
        return int(code or 0), payload
    except Exception:
        return 0, ''


def curl_bytes(url, timeout=15):
    try:
        p = subprocess.run(['curl', '-s', '--max-time', str(timeout), url],
                           capture_output=True, timeout=timeout + 4)
        return p.stdout if p.returncode == 0 and p.stdout else None
    except Exception:
        return None


# ── SQLite ────────────────────────────────────────────────────────────────
def db():
    c = sqlite3.connect(DB_PATH, timeout=10)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    with db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS members(
          member_no TEXT PRIMARY KEY, data TEXT,
          local_checked INTEGER DEFAULT 0, local_source TEXT, local_time TEXT);
        CREATE TABLE IF NOT EXISTS basics(
          member_no TEXT PRIMARY KEY, name TEXT, mobile TEXT, tax_id TEXT, company TEXT);
        CREATE TABLE IF NOT EXISTS proxies(id TEXT PRIMARY KEY, data TEXT);
        CREATE TABLE IF NOT EXISTS rsvp(name TEXT PRIMARY KEY, table_no TEXT);
        CREATE TABLE IF NOT EXISTS assets(path TEXT PRIMARY KEY, content BLOB, ctype TEXT);
        CREATE TABLE IF NOT EXISTS queue(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          member_no TEXT, fn TEXT, source TEXT, created_at TEXT,
          synced INTEGER DEFAULT 0, result TEXT, synced_at TEXT);
        """)


def kv_get(k, default=None):
    with db() as c:
        r = c.execute('SELECT v FROM kv WHERE k=?', (k,)).fetchone()
    return json.loads(r['v']) if r else default


def kv_set(k, v):
    with db() as c:
        c.execute('INSERT INTO kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v',
                  (k, json.dumps(v)))


# ── 裝置身分 ──────────────────────────────────────────────────────────────
def device_id():
    host = socket.gethostname()
    mac = ''
    for iface in ('eth0', 'wlan0'):
        try:
            mac = open(f'/sys/class/net/{iface}/address').read().strip().replace(':', '')[-6:]
            break
        except Exception:
            continue
    return f'{host}-{mac or "nomac"}'


def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return ''


DEVICE_ID = device_id()
# TADA_MANAGED=1：不等 server 端 managed 旗標直接啟用快照（測試／tada_devices 未建時的備援）
FORCE_MANAGED = os.environ.get('TADA_MANAGED') == '1'
STATE = {'online': False, 'managed': FORCE_MANAGED, 'last_sync': None, 'last_snapshot': 0,
         'election_id': None, 'sync_error': ''}


# ── 同步：快照下載 ────────────────────────────────────────────────────────
def is_online():
    if os.path.exists(OFFLINE_FLAG):
        return False
    code, _ = curl(f'{SB_URL}/rest/v1/tada_v_election?limit=1', timeout=4)
    return code == 200


def snapshot_pull():
    """下載場次／名冊／委託／桌次快照到本地。只覆蓋 server 欄位，保留本地報到 overlay。"""
    code, body = curl(f'{SB_URL}/rest/v1/tada_v_election?status=in.(checkin,open)&order=created_at.desc&limit=1')
    if code != 200:
        return False
    elections = json.loads(body or '[]')
    if not elections:
        kv_set('election', None)
        return True
    e = elections[0]
    kv_set('election', e)
    STATE['election_id'] = e['id']
    eid = e['id']

    code, body = curl(f'{SB_URL}/rest/v1/tada_v_candidates?election_id=eq.{eid}&order=position.asc,sort.asc,no.asc')
    if code == 200:
        kv_set('candidates', json.loads(body or '[]'))

    code, body = curl(f'{SB_URL}/rest/v1/tada_v_members?election_id=eq.{eid}', timeout=20)
    if code == 200:
        rows = json.loads(body or '[]')
        with db() as c:
            for m in rows:
                c.execute("""INSERT INTO members(member_no,data) VALUES(?,?)
                             ON CONFLICT(member_no) DO UPDATE SET data=excluded.data""",
                          (m['member_no'], json.dumps(m)))
                # server 已記到 → 清掉本地 overlay（server 為準）
                if m.get('is_checked_in'):
                    c.execute('UPDATE members SET local_checked=0 WHERE member_no=?', (m['member_no'],))

    code, body = curl(f'{SB_URL}/rest/v1/tada_members?hidden=eq.false&select=member_no,name,mobile,tax_id,company', timeout=20)
    if code == 200:
        with db() as c:
            for m in json.loads(body or '[]'):
                if m.get('member_no'):
                    c.execute("""INSERT INTO basics(member_no,name,mobile,tax_id,company)
                                 VALUES(?,?,?,?,?)
                                 ON CONFLICT(member_no) DO UPDATE SET name=excluded.name,
                                   mobile=excluded.mobile, tax_id=excluded.tax_id, company=excluded.company""",
                              (m['member_no'], m.get('name'), m.get('mobile'), m.get('tax_id'), m.get('company')))

    code, body = curl(f'{SB_URL}/rest/v1/tada_v_proxy?election_id=eq.{eid}', timeout=15)
    if code == 200:
        with db() as c:
            c.execute('DELETE FROM proxies')
            for p in json.loads(body or '[]'):
                c.execute('INSERT INTO proxies(id,data) VALUES(?,?)', (str(p['id']), json.dumps(p)))

    code, body = curl(f'{SB_URL}/rest/v1/tada_rsvp?select=display_name,table_no&hidden=is.false', timeout=15)
    if code == 200:
        with db() as c:
            for r in json.loads(body or '[]'):
                if r.get('display_name'):
                    c.execute("""INSERT INTO rsvp(name,table_no) VALUES(?,?)
                                 ON CONFLICT(name) DO UPDATE SET table_no=excluded.table_no""",
                              (r['display_name'], r.get('table_no') or ''))

    # 報到頁與靜態資源
    html = curl_bytes(SITE + '/kiosk/index.html')
    if html:
        with db() as c:
            c.execute("""INSERT INTO assets(path,content,ctype) VALUES('/index.html',?,?)
                         ON CONFLICT(path) DO UPDATE SET content=excluded.content""",
                      (html, 'text/html; charset=utf-8'))
    for path, src in PAGE_ASSETS.items():
        blob = curl_bytes(src)
        if blob:
            ctype = ('application/javascript' if path.endswith('.js')
                     else 'image/png' if path.endswith('.png') else 'application/octet-stream')
            with db() as c:
                c.execute("""INSERT INTO assets(path,content,ctype) VALUES(?,?,?)
                             ON CONFLICT(path) DO UPDATE SET content=excluded.content""",
                          (path, blob, ctype))
    STATE['last_snapshot'] = time.time()
    return True


# ── 同步：佇列回放（兩機 merge 即在此發生：先回放先贏）──────────────────
def queue_replay():
    with db() as c:
        rows = c.execute('SELECT * FROM queue WHERE synced=0 ORDER BY id').fetchall()
    for q in rows:
        eid = STATE.get('election_id') or (kv_get('election') or {}).get('id')
        if not eid:
            return
        code, body = curl(f'{SB_URL}/rest/v1/rpc/{q["fn"]}', 'POST',
                          {'p_election': eid, 'p_member_no': q['member_no']}, timeout=8)
        if code != 200:
            return   # 網路又斷了，下一輪再試
        try:
            res = json.loads(body)
        except Exception:
            res = {}
        # ok=回放成功；already_checked_in=另一台已報（merge：先到先贏）→ 都算完成
        if res.get('ok') or res.get('error') in ('already_checked_in', 'delegated_away'):
            curl(f'{SB_URL}/rest/v1/tada_v_members?election_id=eq.{eid}&member_no=eq.{urllib.parse.quote(q["member_no"])}',
                 'PATCH', {'checkin_source': q['source']}, headers=['Prefer: return=minimal'])
            with db() as c:
                c.execute('UPDATE queue SET synced=1, result=?, synced_at=? WHERE id=?',
                          (json.dumps(res), time.strftime('%Y-%m-%dT%H:%M:%S'), q['id']))


def pending_count():
    with db() as c:
        return c.execute('SELECT COUNT(*) n FROM queue WHERE synced=0').fetchone()['n']


# ── 同步：裝置註冊 heartbeat ──────────────────────────────────────────────
def heartbeat():
    body = {'device_id': DEVICE_ID, 'hostname': socket.gethostname(), 'ip': local_ip(),
            'version': VERSION, 'pending_count': pending_count(),
            'election_id': STATE.get('election_id'),
            'last_seen': time.strftime('%Y-%m-%dT%H:%M:%S+08:00')}
    code, resp = curl(f'{SB_URL}/rest/v1/tada_devices?on_conflict=device_id', 'POST', body,
                      headers=['Prefer: resolution=merge-duplicates,return=representation'])
    if code in (200, 201) and not FORCE_MANAGED:
        try:
            row = json.loads(resp)[0]
            STATE['managed'] = bool(row.get('managed'))
        except Exception:
            pass


def sync_loop():
    while True:
        try:
            STATE['online'] = is_online()
            if STATE['online']:
                heartbeat()
                queue_replay()
                if STATE['managed'] and time.time() - STATE['last_snapshot'] > SNAPSHOT_INTERVAL:
                    snapshot_pull()
                STATE['last_sync'] = time.strftime('%H:%M:%S')
                STATE['sync_error'] = ''
        except Exception as e:
            STATE['sync_error'] = str(e)[:200]
        time.sleep(SYNC_INTERVAL)


# ── 本地資料存取（模擬 RPC 邏輯）──────────────────────────────────────────
def member_get(no):
    with db() as c:
        r = c.execute('SELECT * FROM members WHERE member_no=?', (no,)).fetchone()
    if not r:
        return None
    m = json.loads(r['data'])
    if r['local_checked']:
        m['is_checked_in'] = True
        m['checkin_source'] = r['local_source']
    return m


def active_proxies():
    with db() as c:
        rows = c.execute('SELECT data FROM proxies').fetchall()
    out = []
    for r in rows:
        p = json.loads(r['data'])
        if p.get('agreed') and (p.get('status') or 'active') == 'active':
            out.append(p)
    return out


def proxy_mine_local(name, no):
    res = {'delegated': False, 'is_delegate_for': None}
    for p in active_proxies():
        if (no and p.get('principal_no') == no) or p.get('principal_name') == name:
            res.update({'delegated': True, 'delegate_name': p.get('delegate_name'),
                        'proxy_attend': bool(p.get('proxy_attend')), 'proxy_vote': bool(p.get('proxy_vote'))})
        if (no and p.get('delegate_no') == no) or p.get('delegate_name') == name:
            res.update({'is_delegate_for': p.get('principal_name'),
                        'delegate_attend': bool(p.get('proxy_attend')),
                        'delegate_vote': bool(p.get('proxy_vote'))})
    return res


def checkin_local(fn, member_no, source):
    """離線報到：驗證＋寫本地 overlay＋排入佇列。回傳形狀對齊 server RPC。"""
    m = member_get(member_no)
    if not m:
        return {'ok': False, 'error': 'not_found'}
    if m.get('is_checked_in'):
        return {'ok': False, 'error': 'already_checked_in'}
    pm = proxy_mine_local(m.get('name'), member_no)
    if pm.get('delegated') and pm.get('proxy_attend'):
        return {'ok': False, 'error': 'delegated_away', 'delegate_name': pm.get('delegate_name')}
    can_vote = m.get('can_vote') is not False
    self_ballot = 0 if (pm.get('delegated') and pm.get('proxy_vote')) else (1 if can_vote else 0)
    proxy_vote_count = sum(1 for p in active_proxies()
                           if p.get('proxy_vote') and
                           (p.get('delegate_no') == member_no or p.get('delegate_name') == m.get('name')))
    now = time.strftime('%Y-%m-%dT%H:%M:%S')
    with db() as c:
        c.execute('UPDATE members SET local_checked=1, local_source=?, local_time=? WHERE member_no=?',
                  (source, now, member_no))
        c.execute('INSERT INTO queue(member_no,fn,source,created_at) VALUES(?,?,?,?)',
                  (member_no, fn, source, now))
    return {'ok': True, 'offline': not STATE['online'], 'name': m.get('name'),
            'member_no': member_no, 'member_type': m.get('member_type'), 'rep': m.get('rep'),
            'can_vote': can_vote, 'self_ballot': self_ballot,
            'proxy_vote_count': proxy_vote_count,
            'ballots': self_ballot + proxy_vote_count, 'attend_rep': 0, 'uuids': []}


# ── RPC 模擬（鍵盤查詢）───────────────────────────────────────────────────
def rpc_member_by_mobile(body):
    q = re.sub(r'\D', '', body.get('p_mobile') or '')
    if len(q) < 8:
        return {'ok': False}
    with db() as c:
        rows = c.execute('SELECT member_no, mobile FROM basics WHERE mobile IS NOT NULL').fetchall()
    for r in rows:
        if re.sub(r'\D', '', r['mobile'] or '') == q:
            return {'ok': True, 'member_no': r['member_no']}
    return {'ok': False}


def _tax_candidates(tax):
    with db() as c:
        return c.execute('SELECT member_no,name,mobile,company FROM basics WHERE tax_id=? ORDER BY member_no',
                         (tax,)).fetchall()


def rpc_candidates_by_tax(body):
    rows = _tax_candidates(body.get('p_tax_id') or '')
    if not rows:
        return {'ok': False}
    cands = []
    for i, r in enumerate(rows):
        n = r['name'] or ''
        masked = n[0] + '○' * max(len(n) - 2, 1) + (n[-1] if len(n) > 1 else '')
        cands.append({'idx': i, 'masked': masked, 'company': r['company'] or ''})
    return {'ok': True, 'candidates': cands}


def rpc_verify_by_tax(body):
    rows = _tax_candidates(body.get('p_tax_id') or '')
    idx = body.get('p_idx')
    if idx is None or idx >= len(rows):
        return {'ok': False}
    mobile = re.sub(r'\D', '', rows[idx]['mobile'] or '')
    if mobile and mobile.endswith(body.get('p_last3') or '???'):
        return {'ok': True, 'member_no': rows[idx]['member_no']}
    return {'ok': False}


def rpc_progress():
    with db() as c:
        total = c.execute('SELECT COUNT(*) n FROM members').fetchone()['n']
        checked = c.execute("""SELECT COUNT(*) n FROM members
                               WHERE local_checked=1 OR json_extract(data,'$.is_checked_in')=1""").fetchone()['n']
    return {'total_members': total, 'checked_in': checked, 'tokens_issued': 0, 'ballots_cast': 0}


# ── 透傳（線上時未模擬的請求直通 Supabase）────────────────────────────────
def passthrough(method, path_qs, body):
    headers = ['Prefer: return=representation'] if method in ('POST', 'PATCH') else []
    code, resp = curl(SB_URL + path_qs, method, body, headers=headers, timeout=8)
    return code, resp


# ── HTTP server ───────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype='application/json'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode() \
            if not isinstance(body, str) else body.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,PATCH,OPTIONS')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self._send(200, '')

    def _serve_asset(self, path):
        with db() as c:
            r = c.execute('SELECT content,ctype FROM assets WHERE path=?', (path,)).fetchone()
        if not r:
            return self._send(404, {'error': 'asset not cached yet'})
        self._send(200, bytes(r['content']), r['ctype'])

    def _serve_page(self):
        with db() as c:
            r = c.execute("SELECT content FROM assets WHERE path='/index.html'").fetchone()
        if not r:
            return self._send(503, '<h1>名冊尚未同步，請先連網一次</h1>', 'text/html; charset=utf-8')
        html = bytes(r['content']).decode('utf-8', 'replace')
        html = html.replace('src="../assets/liff-common.js"', 'src="/assets/liff-common.js"')
        html = html.replace('https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js',
                            '/assets/qrcode.min.js')
        html = html.replace('src="../assets/line/oa-qr.png"', 'src="/assets/line/oa-qr.png"')
        html = html.replace('</head>',
                            f'<script>window.addEventListener("DOMContentLoaded",()=>{{'
                            f'window.TADA_SB_URL="http://127.0.0.1:{PORT}";}});'
                            f'window.TADA_SB_URL="http://127.0.0.1:{PORT}";'
                            f'window.TADA_LOCAL_AGENT=1;</script></head>')
        self._send(200, html, 'text/html; charset=utf-8')

    def _route(self, method):
        parsed = urllib.parse.urlparse(self.path)
        path, qs = parsed.path, urllib.parse.parse_qs(parsed.query)
        body = {}
        if method in ('POST', 'PATCH'):
            ln = int(self.headers.get('Content-Length') or 0)
            if ln:
                try:
                    body = json.loads(self.rfile.read(ln))
                except Exception:
                    body = {}

        # 頁面與資源
        if method == 'GET' and path in ('/', '/index.html', '/kiosk/', '/kiosk/index.html'):
            return self._serve_page()
        if method == 'GET' and path.startswith('/assets/'):
            return self._serve_asset(path)
        if method == 'GET' and path == '/agent/status':
            with db() as c:
                has_page = c.execute("SELECT 1 FROM assets WHERE path='/index.html'").fetchone() is not None
                n_members = c.execute('SELECT COUNT(*) n FROM members').fetchone()['n']
            return self._send(200, {'device_id': DEVICE_ID, 'version': VERSION, **STATE,
                                    'ready': has_page and n_members > 0,
                                    'pending': pending_count(),
                                    'members': rpc_progress()})

        # ── Supabase REST 模擬 ──
        if path == '/rest/v1/tada_v_election':
            e = kv_get('election')
            return self._send(200, [e] if e else [])
        if path == '/rest/v1/tada_v_candidates':
            return self._send(200, kv_get('candidates', []))
        if path == '/rest/v1/tada_v_members' and method == 'GET':
            no = (qs.get('member_no', [''])[0]).replace('eq.', '')
            if no:
                m = member_get(no)
                return self._send(200, [m] if m else [])
            with db() as c:
                rows = c.execute('SELECT member_no FROM members').fetchall()
            return self._send(200, [member_get(r['member_no']) for r in rows])
        if path == '/rest/v1/tada_v_members' and method == 'PATCH':
            # 頁面報到後補寫 checkin_source → 記到本地 overlay 與待回放佇列
            no = (qs.get('member_no', [''])[0]).replace('eq.', '')
            src = body.get('checkin_source')
            if no and src:
                with db() as c:
                    c.execute('UPDATE members SET local_source=? WHERE member_no=?', (src, no))
                    c.execute('UPDATE queue SET source=? WHERE member_no=? AND synced=0', (src, no))
            if STATE['online']:
                passthrough('PATCH', self.path, body)
            return self._send(204, '')
        if path == '/rest/v1/tada_rsvp':
            name = (qs.get('display_name', [''])[0]).replace('eq.', '')
            with db() as c:
                r = c.execute('SELECT table_no FROM rsvp WHERE name=?', (name,)).fetchone()
            return self._send(200, [{'table_no': r['table_no']}] if r else [])

        m_rpc = re.match(r'^/rest/v1/rpc/(\w+)$', path)
        if m_rpc and method == 'POST':
            fn = m_rpc.group(1)
            if fn in ('vote_checkin', 'vote_checkin_paper'):
                # 線上：直通 server（拿真 token、server 直接記錄）；失敗立刻退本地
                if STATE['online']:
                    code, resp = passthrough('POST', self.path, body)
                    if code == 200:
                        try:
                            res = json.loads(resp)
                            if res.get('ok'):   # server 已記 → 本地 overlay 同步標記
                                with db() as c:
                                    c.execute('UPDATE members SET local_checked=1, local_source=? WHERE member_no=?',
                                              ('synced', body.get('p_member_no') or ''))
                        except Exception:
                            pass
                        return self._send(200, resp)
                return self._send(200, checkin_local(fn, body.get('p_member_no') or '',
                                                     self.headers.get('X-Checkin-Source') or 'offline'))
            if fn == 'vote_progress':
                if STATE['online']:
                    code, resp = passthrough('POST', self.path, body)
                    if code == 200:
                        return self._send(200, resp)
                return self._send(200, rpc_progress())
            if fn == 'proxy_mine':
                if STATE['online']:
                    code, resp = passthrough('POST', self.path, body)
                    if code == 200:
                        return self._send(200, resp)
                return self._send(200, proxy_mine_local(body.get('p_name') or '', body.get('p_no') or ''))
            if fn == 'member_by_mobile':
                return self._send(200, rpc_member_by_mobile(body) if not STATE['online']
                                  else json.loads(passthrough('POST', self.path, body)[1] or '{"ok":false}'))
            if fn == 'member_candidates_by_tax':
                return self._send(200, rpc_candidates_by_tax(body) if not STATE['online']
                                  else json.loads(passthrough('POST', self.path, body)[1] or '{"ok":false}'))
            if fn == 'member_verify_by_tax':
                return self._send(200, rpc_verify_by_tax(body) if not STATE['online']
                                  else json.loads(passthrough('POST', self.path, body)[1] or '{"ok":false}'))

        # 其餘 /rest/v1/*：線上透傳、離線 503
        if path.startswith('/rest/v1/'):
            if STATE['online']:
                code, resp = passthrough(method, self.path, body if method != 'GET' else None)
                return self._send(code if code else 502, resp or '[]')
            return self._send(503, {'error': 'offline'})

        self._send(404, {'error': 'not found'})

    def do_GET(self):
        self._route('GET')

    def do_POST(self):
        self._route('POST')

    def do_PATCH(self):
        self._route('PATCH')


def main():
    init_db()
    threading.Thread(target=sync_loop, daemon=True).start()
    print(f'kiosk-agent v{VERSION} device={DEVICE_ID} port={PORT}')
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()


if __name__ == '__main__':
    main()

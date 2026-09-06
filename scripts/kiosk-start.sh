#!/usr/bin/env bash
# TADA 報到機開機自動啟動
# - Bookworm（Wayland/labwc）：由 ~/.config/labwc/autostart 呼叫
# - Bullseye（X11/LXDE）  ：由 ~/.config/lxsession/LXDE-pi/autostart 呼叫
# log 在 /tmp/kiosk.log；Chromium 帶 CDP 9222（僅 127.0.0.1）供 SSH 遠端操作
LOG=/tmp/kiosk.log
exec >>"$LOG" 2>&1
echo "=== kiosk-start $(date) ==="

# 等網路通（最多 120 秒），避免開機比網路快而開出錯誤頁
for i in $(seq 1 60); do
  curl -sI --max-time 2 https://tada-ai.org.tw/kiosk/ >/dev/null && break
  sleep 2
done

# 列印代理（127.0.0.1:8043）
pgrep -f '[p]rint-agent' >/dev/null || (python3 "$HOME/print-agent.py" >>/tmp/print-agent.log 2>&1 &)

# 報到本地代理（127.0.0.1:8080）：離線名冊＋報到佇列＋頁面快取
pgrep -f '[k]iosk-agent' >/dev/null || (python3 "$HOME/kiosk-agent.py" >>/tmp/kiosk-agent.log 2>&1 &)

CHROME_BIN=$(command -v chromium || command -v chromium-browser)
COMMON_FLAGS=(--kiosk --password-store=basic --use-mock-keychain --lang=zh-TW
  --noerrdialogs --disable-infobars --no-first-run
  --disable-session-crashed-bubble --disable-pinch
  --remote-debugging-port=9222)

# 優先走本地代理（離線可用、回應快）；代理 20 秒內沒 ready（含名冊快照）就退回線上版
URL='https://tada-ai.org.tw/kiosk/'
for i in $(seq 1 20); do
  if curl -s --max-time 1 http://127.0.0.1:8080/agent/status | grep -q '"ready": true'; then
    URL='http://127.0.0.1:8080/'
    break
  fi
  sleep 1
done
echo "kiosk URL: $URL"

# HDMI 鏡像投影（Wayland 限定）：偵測外接螢幕原生解析度，縮放到高度貼齊
# DSI 480、DSI 區域置中重疊。wlr-randr 同一道指令會自動避開重疊，且移動
# 其中一顆會把另一顆推開，所以必須分三步：HDMI 定位 → DSI 置中 → HDMI 拉回。
setup_hdmi_mirror() {
  local info W H S LW OFF
  info=$(wlr-randr 2>/dev/null) || return 0
  echo "$info" | grep -q '^HDMI-A-1' || { echo "無 HDMI，跳過鏡像"; return 0; }
  read -r W H <<<"$(echo "$info" | awk '/^HDMI-A-1/{f=1;next} /^[A-Z]/{f=0} f && /preferred/{split($1,a,"x"); print a[1],a[2]; exit}')"
  [ -n "$W" ] && [ -n "$H" ] || { echo "HDMI 解析度偵測失敗"; return 0; }
  S=$(python3 -c "print($H/480)")
  echo "HDMI 鏡像：${W}x${H} scale=$S（DSI/HDMI 皆對齊 0,0，9/4 活動實測配置）"
  # 部分重疊（DSI 置中位移）曾造成實體輸出全黑，故固定完全對齊原點
  wlr-randr --output HDMI-A-1 --mode "${W}x${H}" --scale "$S" --pos 0,0; sleep 1
  wlr-randr --output DSI-1 --pos 0,0
}

if [ -S "/run/user/$(id -u)/wayland-0" ]; then
  # Bookworm / Wayland
  export XDG_RUNTIME_DIR="/run/user/$(id -u)" WAYLAND_DISPLAY=wayland-0
  setup_hdmi_mirror
  "$CHROME_BIN" --ozone-platform=wayland "${COMMON_FLAGS[@]}" "$URL"
else
  # Bullseye / X11
  export DISPLAY=:0
  xset s off; xset -dpms; xset s noblank   # 關閉螢幕保護與休眠
  "$CHROME_BIN" "${COMMON_FLAGS[@]}" "$URL"
fi

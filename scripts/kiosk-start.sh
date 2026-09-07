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
COMMON_FLAGS=(--password-store=basic --use-mock-keychain --lang=zh-TW
  --noerrdialogs --disable-infobars --no-first-run
  --disable-session-crashed-bubble --hide-crash-restore-bubble --disable-pinch)

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

# 雙螢幕＝雙視窗延伸桌面（Wayland 限定）。
# 教訓一：labwc 重疊輸出（鏡像）實體面板會黑屏（截圖正常、面板全黑），不能用。
# 教訓二：HDMI --off 再 --on 在開機階段常開不回來，所以 HDMI 全程保持開啟。
# 做法：兩個 Chromium 都走 Xwayland，用 CDP 先移到目標螢幕座標再全螢幕——
# DSI(0,0) 放互動報到、HDMI(800,0) 放 /wall 顯示牆（依比例自動排 1~2 份）。
place_window() {  # $1=debug port  $2=x  $3=y  $4=名稱  $5=期望left
  local t OUT
  for t in 1 2 3; do
    OUT=$(python3 "$HOME/cdp-fullscreen.py" "$1" "$2" "$3" 2>&1)
    echo "$4 定位第 $t 次：$OUT"
    echo "$OUT" | grep -q "'left': $5" && return 0
    sleep 4
  done
  echo "⚠ $4 定位失敗"
  return 1
}

if [ -S "/run/user/$(id -u)/wayland-0" ]; then
  # Bookworm / Wayland
  export XDG_RUNTIME_DIR="/run/user/$(id -u)" WAYLAND_DISPLAY=wayland-0
  HAS_HDMI=0
  if wlr-randr 2>/dev/null | grep -q '^HDMI-A-1'; then
    HAS_HDMI=1
    wlr-randr --output HDMI-A-1 --scale 1 --pos 800,0   # 保持開啟，僅排到 DSI 右側（不重疊）
    sleep 1
  fi
  wlr-randr --output DSI-1 --pos 0,0

  # 互動報到（DSI）
  DISPLAY=:0 "$CHROME_BIN" --ozone-platform=x11 "${COMMON_FLAGS[@]}" \
    --remote-debugging-port=9222 --window-position=100,100 --window-size=640,400 \
    "$URL" &
  CHROME_PID=$!
  sleep 10
  place_window 9222 100 100 互動報到 0

  # 投影顯示牆（HDMI）
  if [ "$HAS_HDMI" = 1 ]; then
    DISPLAY=:0 "$CHROME_BIN" --ozone-platform=x11 "${COMMON_FLAGS[@]}" \
      --user-data-dir="$HOME/.config/chromium-hdmi" \
      --remote-debugging-port=9223 --window-position=1200,200 --window-size=1280,720 \
      'http://127.0.0.1:8080/wall' >/tmp/chromium-hdmi.log 2>&1 &
    sleep 8
    place_window 9223 1200 200 顯示牆 800
  fi
  wait "$CHROME_PID"
else
  # Bullseye / X11
  export DISPLAY=:0
  xset s off; xset -dpms; xset s noblank   # 關閉螢幕保護與休眠
  "$CHROME_BIN" --kiosk "${COMMON_FLAGS[@]}" "$URL"
fi

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

CHROME_BIN=$(command -v chromium || command -v chromium-browser)
COMMON_FLAGS=(--kiosk --password-store=basic --use-mock-keychain --lang=zh-TW
  --noerrdialogs --disable-infobars --no-first-run
  --disable-session-crashed-bubble --disable-pinch
  --remote-debugging-port=9222)
URL='https://tada-ai.org.tw/kiosk/'

if [ -S "/run/user/$(id -u)/wayland-0" ]; then
  # Bookworm / Wayland
  export XDG_RUNTIME_DIR="/run/user/$(id -u)" WAYLAND_DISPLAY=wayland-0
  "$CHROME_BIN" --ozone-platform=wayland "${COMMON_FLAGS[@]}" "$URL"
else
  # Bullseye / X11
  export DISPLAY=:0
  xset s off; xset -dpms; xset s noblank   # 關閉螢幕保護與休眠
  "$CHROME_BIN" "${COMMON_FLAGS[@]}" "$URL"
fi

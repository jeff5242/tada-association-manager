#!/usr/bin/env bash
# TADA 報到機開機自動啟動（由 ~/.config/labwc/autostart 呼叫）
# log 在 /tmp/kiosk.log；Chromium 帶 CDP 9222（僅 127.0.0.1）供 SSH 遠端操作
LOG=/tmp/kiosk.log
exec >>"$LOG" 2>&1
echo "=== kiosk-start $(date) ==="
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0

# 等網路通（最多 120 秒），避免開機比 Wi-Fi 快而開出錯誤頁
for i in $(seq 1 60); do
  curl -sI --max-time 2 https://tada-ai.org.tw/kiosk/ >/dev/null && break
  sleep 2
done

# 列印代理（127.0.0.1:8043）
pgrep -f '[p]rint-agent' >/dev/null || (python3 "$HOME/print-agent.py" >>/tmp/print-agent.log 2>&1 &)

# 報到畫面
chromium --kiosk --ozone-platform=wayland \
  --password-store=basic --use-mock-keychain --lang=zh-TW \
  --noerrdialogs --disable-infobars --no-first-run \
  --disable-session-crashed-bubble --disable-pinch \
  --remote-debugging-port=9222 \
  'https://tada-ai.org.tw/kiosk/'

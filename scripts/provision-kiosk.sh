#!/usr/bin/env bash
# 把一台全新樹莓派佈建成 TADA 報到機。
#
# 前置：先把 SSH 金鑰裝上去（ssh-copy-id <user>@<host>）
# 用法：bash scripts/provision-kiosk.sh <user>@<host> [--with-printer-share]
#   --with-printer-share  eth0 設成 10.42.0.1/24 共享模式（接 TSP650II 網路印表機用）
set -euo pipefail

TARGET="${1:?用法: provision-kiosk.sh <user>@<host> [--with-printer-share]}"
WITH_PRINTER="${2:-}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "① 複製檔案到 $TARGET …"
scp "$DIR/scripts/print-agent.py" "$DIR/scripts/kiosk-start.sh" "$DIR/scripts/cdp.py" "$TARGET:~/"

echo "② 遠端設定（labwc autostart / 相依套件 / sudoers）…"
ssh "$TARGET" bash -s -- "$WITH_PRINTER" <<'REMOTE'
set -e
WITH_PRINTER="${1:-}"
chmod +x ~/kiosk-start.sh

# labwc autostart：開機自動進報到畫面
mkdir -p ~/.config/labwc
touch ~/.config/labwc/autostart
grep -q 'kiosk-start' ~/.config/labwc/autostart || echo '~/kiosk-start.sh &' >> ~/.config/labwc/autostart

# 列印代理需要 Pillow
python3 -c 'import PIL' 2>/dev/null || { sudo apt-get update -qq; sudo apt-get install -y python3-pil; }

# 現場操作免密碼重啟/關機
echo "$USER ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/shutdown, /usr/sbin/reboot, /usr/sbin/shutdown" | sudo tee /etc/sudoers.d/010-kiosk-power >/dev/null
sudo chmod 440 /etc/sudoers.d/010-kiosk-power

# 印表機共享網段（選用）：eth0 = 10.42.0.1/24 發 DHCP 給印表機
if [ "$WITH_PRINTER" = "--with-printer-share" ]; then
  nmcli -t -f NAME con show | grep -qx 'printer-share' || \
    sudo nmcli con add type ethernet ifname eth0 con-name printer-share \
      ipv4.method shared ipv4.addresses 10.42.0.1/24 autoconnect yes
fi

echo "✓ provision OK on $(hostname)（$USER）"
REMOTE

echo "③ 完成。建議重開機驗證自動啟動：ssh $TARGET sudo reboot"

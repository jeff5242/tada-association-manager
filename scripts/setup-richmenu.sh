#!/usr/bin/env bash
# TADA 會員版 Rich Menu 一鍵註冊腳本
#
# 用途：把 assets/richmenu/member.json（按鈕座標）＋ member.png（背景圖）
#       註冊成 LINE 官方帳號的「預設 Rich Menu」，所有會員都會看到。
#
# 用法：
#   export LINE_CHANNEL_ACCESS_TOKEN='你的_channel_access_token'   # 從 LINE Console → Messaging API 取得
#   bash scripts/setup-richmenu.sh
#
# 重新換版：直接再跑一次即可（會建立新的並設為預設；舊的可用 --list / --delete 清理）。

set -euo pipefail

API="https://api.line.me/v2/bot"
API_DATA="https://api-data.line.me/v2/bot"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSON="$DIR/assets/richmenu/member.json"
IMG="$DIR/assets/richmenu/member.png"

TOKEN="${LINE_CHANNEL_ACCESS_TOKEN:-}"

# ── 前置檢查 ────────────────────────────────────────────────
if [[ -z "$TOKEN" || "$TOKEN" == *"你的"* || "$TOKEN" == *"_channel_access_token"* ]]; then
  echo "❌ 請先設定真實的 LINE_CHANNEL_ACCESS_TOKEN（從 LINE Console → Messaging API 複製）"
  echo "   export LINE_CHANNEL_ACCESS_TOKEN='貼上真實的token'"
  exit 1
fi
[[ -f "$JSON" ]] || { echo "❌ 找不到 $JSON"; exit 1; }
[[ -f "$IMG"  ]] || { echo "❌ 找不到 $IMG";  exit 1; }

AUTH="Authorization: Bearer $TOKEN"

# ── 選單管理指令 ────────────────────────────────────────────
if [[ "${1:-}" == "--list" ]]; then
  echo "目前已註冊的 Rich Menu："
  curl -s -X GET "$API/richmenu/list" -H "$AUTH"; echo; exit 0
fi
if [[ "${1:-}" == "--delete" && -n "${2:-}" ]]; then
  echo "刪除 Rich Menu $2 …"
  curl -s -X DELETE "$API/richmenu/$2" -H "$AUTH"; echo "✓ 已刪除"; exit 0
fi

# ── 1. 建立 Rich Menu（送出座標 JSON）───────────────────────
echo "① 建立 Rich Menu …"
RESP=$(curl -s -X POST "$API/richmenu" -H "$AUTH" -H "Content-Type: application/json" -d @"$JSON")
RICH_MENU_ID=$(echo "$RESP" | sed -n 's/.*"richMenuId":"\([^"]*\)".*/\1/p')
if [[ -z "$RICH_MENU_ID" ]]; then
  echo "❌ 建立失敗：$RESP"; exit 1
fi
echo "   ✓ richMenuId = $RICH_MENU_ID"

# ── 2. 上傳背景圖 ───────────────────────────────────────────
echo "② 上傳背景圖 …"
UP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_DATA/richmenu/$RICH_MENU_ID/content" \
  -H "$AUTH" -H "Content-Type: image/png" --data-binary @"$IMG")
if [[ "$UP" != "200" ]]; then
  echo "❌ 上傳圖片失敗（HTTP $UP）"; exit 1
fi
echo "   ✓ 圖片已上傳"

# ── 3. 設為所有使用者的預設選單 ─────────────────────────────
echo "③ 設為預設選單（全體會員）…"
DEF=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/user/all/richmenu/$RICH_MENU_ID" -H "$AUTH" -H "Content-Length: 0")
if [[ "$DEF" != "200" ]]; then
  echo "❌ 設定預設失敗（HTTP $DEF）"; exit 1
fi

echo ""
echo "🎉 完成！TADA 會員版 Rich Menu 已上線。"
echo "   打開 LINE 官方帳號聊天室，底部就會看到選單（可能需重開聊天室）。"
echo "   richMenuId = $RICH_MENU_ID"

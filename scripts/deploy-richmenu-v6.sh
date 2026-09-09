#!/usr/bin/env bash
# 部署 LINE Rich Menu v6：訪客/會員三格雙選單
# 訪客（全體預設）：最新消息｜我要入會｜會務相關
# 會員（逐一綁定）：最新消息｜會員證｜會務相關
# 會員名單＝tada_members 中已綁 LINE（line_user_id 非空、未隱藏）者
# 用法：bash scripts/deploy-richmenu-v6.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="sb_publishable_08XiE2fH7iY_nlr_K4NQ4w_kJZPkjnj"
IDS=$(curl -s "https://ldjugtfxtxnpvkqvjxew.supabase.co/rest/v1/tada_members?hidden=eq.false&line_user_id=not.is.null&select=line_user_id" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
PAYLOAD=$(python3 - "$DIR" "$IDS" <<'PYEOF'
import base64, json, sys
d = sys.argv[1]
ids = sorted({x["line_user_id"] for x in json.loads(sys.argv[2]) if x.get("line_user_id")})
def pack(name):
    return {"richmenu": json.load(open(f"{d}/assets/richmenu/{name}.json")),
            "image_b64": base64.b64encode(open(f"{d}/assets/richmenu/{name}.png", "rb").read()).decode()}
print(json.dumps({"pw_hash": "0db45166855d1d262b3bb4399a2c0526c16359f9d3663ca8b96e5bc73c61fde0",
                  "mode": "pair", "guest": pack("guest3"), "member": pack("member3"),
                  "member_user_ids": ids}))
PYEOF
)
echo "$PAYLOAD" | curl -s -X POST "https://ldjugtfxtxnpvkqvjxew.supabase.co/functions/v1/richmenu-deploy" \
  -H "Content-Type: application/json" --data-binary @-
echo

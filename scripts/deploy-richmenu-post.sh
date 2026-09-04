#!/usr/bin/env bash
# 一鍵把 LINE Rich Menu 換成「會後六格」版（member-post.json + member-post.png）
# 用法：bash scripts/deploy-richmenu-post.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD=$(python3 - "$DIR" <<'PYEOF'
import base64, json, sys
d = sys.argv[1]
menu = json.load(open(f"{d}/assets/richmenu/member-post.json"))
img = base64.b64encode(open(f"{d}/assets/richmenu/member-post.png", "rb").read()).decode()
print(json.dumps({"pw_hash": "0db45166855d1d262b3bb4399a2c0526c16359f9d3663ca8b96e5bc73c61fde0",
                  "richmenu": menu, "image_b64": img}))
PYEOF
)
echo "$PAYLOAD" | curl -s -X POST "https://ldjugtfxtxnpvkqvjxew.supabase.co/functions/v1/richmenu-deploy" \
  -H "Content-Type: application/json" --data-binary @-
echo

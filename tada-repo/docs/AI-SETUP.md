# AI 助理部署說明

協會平台（`platform/`）的 AI 助理透過 Anthropic API 運作。本文件說明如何安全部署。

## ⚠️ 安全前提

**絕對不要把 API Key 寫進前端 HTML/JS。** 前端原始碼任何人都能檢視，Key 一旦曝露會被盜用並產生費用。

目前 `platform/index.html` 中的 API 呼叫是示意用途，正式上線前務必改為透過後端代理。

## 推薦做法：Serverless Function 代理

### Vercel Function 範例

1. 在 repo 建立 `api/chat.js`：

```javascript
export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).end();

  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': process.env.ANTHROPIC_API_KEY,   // 存在環境變數，不進原始碼
      'anthropic-version': '2023-06-01'
    },
    body: JSON.stringify(req.body)
  });

  const data = await response.json();
  res.status(200).json(data);
}
```

2. 在 Vercel 專案設定 → Environment Variables 加入 `ANTHROPIC_API_KEY`

3. 把 `platform/index.html` 中的 fetch 目標，從直接打 `api.anthropic.com` 改為打自己的 `/api/chat`

### Cloudflare Worker 範例

同理，建立 Worker 接收前端請求，於 Worker 環境變數存 Key，代理轉發至 Anthropic API。

## 階段性過渡建議

依先前規劃，平台初期掛在自有網域、之後轉移給協會獨立管理：

- **初期**：使用自有 API Key，透過上述代理方式部署
- **轉移時**：協會申請自己的 Anthropic 帳號與 Key，僅需更換環境變數，前端無需改動

## 模型設定

平台預設使用 `claude-sonnet-4-6`（對話品質與成本的平衡選擇）。如需調整，修改代理 Function 或前端送出的 `model` 參數即可。

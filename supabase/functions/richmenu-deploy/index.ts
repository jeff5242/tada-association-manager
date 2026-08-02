// TADA Rich Menu 部署 —— 用 LINE_CHANNEL_ACCESS_TOKEN（secret）在伺服器端註冊 Rich Menu
// 前端只傳「管理密碼 SHA-256」＋選單 JSON＋圖片 base64；LINE token 永不外洩到瀏覽器。
// 步驟：建立 richmenu → 上傳背景圖 → 設為全體預設 → 清除舊選單。
//
// 部署：SUPABASE_ACCESS_TOKEN=sbp_... supabase functions deploy richmenu-deploy --use-api --no-verify-jwt --project-ref ldjugtfxtxnpvkqvjxew

import { serve } from "https://deno.land/std@0.203.0/http/server.ts";

const TOKEN = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN")!;
const ADMIN_HASH = "0db45166855d1d262b3bb4399a2c0526c16359f9d3663ca8b96e5bc73c61fde0";
const API = "https://api.line.me/v2/bot";
const API_DATA = "https://api-data.line.me/v2/bot";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const auth = () => ({ Authorization: `Bearer ${TOKEN}` });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { pw_hash, richmenu, image_b64 } = await req.json();
    if (pw_hash !== ADMIN_HASH) return json({ error: "unauthorized" }, 403);
    if (!richmenu || !image_b64) return json({ error: "missing_payload" }, 400);

    // 現有選單（稍後清除）
    const listRes = await fetch(`${API}/richmenu/list`, { headers: auth() });
    const oldIds: string[] = ((await listRes.json()).richmenus || []).map((m: { richMenuId: string }) => m.richMenuId);

    // 1. 建立
    const createRes = await fetch(`${API}/richmenu`, {
      method: "POST", headers: { ...auth(), "Content-Type": "application/json" }, body: JSON.stringify(richmenu),
    });
    const created = await createRes.json();
    if (!created.richMenuId) return json({ error: "create_failed", detail: created }, 500);
    const id = created.richMenuId;

    // 2. 上傳背景圖（base64 → bytes）
    const bytes = Uint8Array.from(atob(image_b64), (c) => c.charCodeAt(0));
    const upRes = await fetch(`${API_DATA}/richmenu/${id}/content`, {
      method: "POST", headers: { ...auth(), "Content-Type": "image/png" }, body: bytes,
    });
    if (upRes.status !== 200) return json({ error: "upload_failed", status: upRes.status, detail: await upRes.text() }, 500);

    // 3. 設為全體預設
    const defRes = await fetch(`${API}/user/all/richmenu/${id}`, { method: "POST", headers: { ...auth(), "Content-Length": "0" } });
    if (defRes.status !== 200) return json({ error: "setdefault_failed", status: defRes.status, detail: await defRes.text() }, 500);

    // 4. 清除舊選單
    const deleted: string[] = [];
    for (const oid of oldIds) {
      if (oid === id) continue;
      const d = await fetch(`${API}/richmenu/${oid}`, { method: "DELETE", headers: auth() });
      if (d.status === 200) deleted.push(oid);
    }

    return json({ ok: true, richMenuId: id, deleted });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

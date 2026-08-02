// TADA 文件區 —— 私有文件清單 / 簽章下載連結
// 以「服務金鑰（service_role）」在伺服器端存取私有 bucket 與 manifest，
// 前端（後臺）只傳「管理密碼的 SHA-256」驗證，服務金鑰永遠不外洩到瀏覽器。
//
// 部署：SUPABASE_ACCESS_TOKEN=sbp_... supabase functions deploy docs --use-api --no-verify-jwt --project-ref ldjugtfxtxnpvkqvjxew

import { serve } from "https://deno.land/std@0.203.0/http/server.ts";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "tada-docs";
// 後臺密碼 tada2026 的 SHA-256（與 tada-admin.html 相同）
const ADMIN_HASH = "0db45166855d1d262b3bb4399a2c0526c16359f9d3663ca8b96e5bc73c61fde0";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
function svcHeaders() {
  return { apikey: SRK, Authorization: `Bearer ${SRK}` };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { action, pw_hash, path } = await req.json();
    if (pw_hash !== ADMIN_HASH) return json({ error: "unauthorized" }, 403);

    if (action === "list") {
      const r = await fetch(`${SB_URL}/rest/v1/tada_docs?order=sort,title&select=id,category,title,path,ext,size`, { headers: svcHeaders() });
      if (!r.ok) return json({ error: "list_failed", detail: await r.text() }, 500);
      return json({ docs: await r.json() });
    }

    if (action === "url") {
      if (!path) return json({ error: "no_path" }, 400);
      const signRes = await fetch(`${SB_URL}/storage/v1/object/sign/${BUCKET}/${encodeURI(path)}`, {
        method: "POST",
        headers: { ...svcHeaders(), "Content-Type": "application/json" },
        body: JSON.stringify({ expiresIn: 120 }),
      });
      const d = await signRes.json();
      if (!d.signedURL) return json({ error: "sign_failed", detail: d }, 500);
      return json({ url: `${SB_URL}/storage/v1${d.signedURL}` });
    }

    return json({ error: "bad_action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

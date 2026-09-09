// TADA Rich Menu 部署 —— 用 LINE_CHANNEL_ACCESS_TOKEN（secret）在伺服器端註冊 Rich Menu
// 前端只傳「管理密碼 SHA-256」＋選單 JSON＋圖片 base64；LINE token 永不外洩到瀏覽器。
//
// 模式一（legacy，欄位 richmenu+image_b64）：建立單一選單 → 設全體預設 → 清除舊選單
// 模式二（mode:"pair"）：訪客/會員雙選單 —— 建立兩個選單 → 訪客設全體預設 →
//   會員選單逐一綁定 member_user_ids（bulk link，每批 ≤500）→ 清除舊選單
// 模式三（mode:"link"）：只補綁會員（richmenu_id + member_user_ids），新會員綁卡後補跑用
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

async function createMenu(richmenu: unknown, image_b64: string): Promise<{ id?: string; error?: unknown }> {
  const createRes = await fetch(`${API}/richmenu`, {
    method: "POST", headers: { ...auth(), "Content-Type": "application/json" }, body: JSON.stringify(richmenu),
  });
  const created = await createRes.json();
  if (!created.richMenuId) return { error: created };
  const bytes = Uint8Array.from(atob(image_b64), (c) => c.charCodeAt(0));
  const upRes = await fetch(`${API_DATA}/richmenu/${created.richMenuId}/content`, {
    method: "POST", headers: { ...auth(), "Content-Type": "image/png" }, body: bytes,
  });
  if (upRes.status !== 200) return { error: { upload: upRes.status, detail: await upRes.text() } };
  return { id: created.richMenuId };
}

async function bulkLink(richMenuId: string, userIds: string[]): Promise<number> {
  let linked = 0;
  for (let i = 0; i < userIds.length; i += 500) {
    const batch = userIds.slice(i, i + 500);
    const r = await fetch(`${API}/richmenu/bulk/link`, {
      method: "POST", headers: { ...auth(), "Content-Type": "application/json" },
      body: JSON.stringify({ richMenuId, userIds: batch }),
    });
    if (r.status === 202 || r.status === 200) linked += batch.length;
  }
  return linked;
}

async function listMenuIds(): Promise<string[]> {
  const listRes = await fetch(`${API}/richmenu/list`, { headers: auth() });
  return ((await listRes.json()).richmenus || []).map((m: { richMenuId: string }) => m.richMenuId);
}

async function deleteMenus(ids: string[], keep: string[]): Promise<string[]> {
  const deleted: string[] = [];
  for (const oid of ids) {
    if (keep.includes(oid)) continue;
    const d = await fetch(`${API}/richmenu/${oid}`, { method: "DELETE", headers: auth() });
    if (d.status === 200) deleted.push(oid);
  }
  return deleted;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json();

    // ── 模式四：selflink —— 綁卡頁自助補綁會員版選單（不需管理密碼）──
    // 安全性：server 端先驗證該 LINE ID 確實存在於會員名冊（line_user_id 已綁定），
    // 冒用只能幫「本來就是會員的人」綁上會員選單，無利可圖。
    if (body.mode === "selflink") {
      const uid = String(body.user_id || "");
      if (!/^U[0-9a-f]{32}$/.test(uid)) return json({ error: "bad_user_id" }, 400);
      const SB = Deno.env.get("SUPABASE_URL")!;
      const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
      const chk = await fetch(`${SB}/rest/v1/tada_members?line_user_id=eq.${uid}&hidden=eq.false&select=member_no&limit=1`,
        { headers: { apikey: ANON, Authorization: `Bearer ${ANON}` } });
      const rows = await chk.json();
      if (!Array.isArray(rows) || !rows.length) return json({ error: "not_member" }, 403);
      const menus = (await (await fetch(`${API}/richmenu/list`, { headers: auth() })).json()).richmenus || [];
      const target = menus.find((m: { name?: string }) => (m.name || "").includes("會員三格"));
      if (!target) return json({ error: "member_menu_not_found" }, 500);
      const lk = await fetch(`${API}/user/${uid}/richmenu/${target.richMenuId}`,
        { method: "POST", headers: { ...auth(), "Content-Length": "0" } });
      return json({ ok: lk.status === 200, status: lk.status, richMenuId: target.richMenuId });
    }

    // 以下模式皆需管理密碼
    if (body.pw_hash !== ADMIN_HASH) return json({ error: "unauthorized" }, 403);

    // ── 模式三：只補綁會員 ──
    if (body.mode === "link") {
      if (!body.richmenu_id || !Array.isArray(body.member_user_ids)) return json({ error: "missing_payload" }, 400);
      const linked = await bulkLink(body.richmenu_id, body.member_user_ids);
      return json({ ok: true, linked });
    }

    // ── 模式二：訪客/會員雙選單 ──
    if (body.mode === "pair") {
      const { guest, member, member_user_ids } = body;
      if (!guest?.richmenu || !guest?.image_b64 || !member?.richmenu || !member?.image_b64) {
        return json({ error: "missing_payload" }, 400);
      }
      const oldIds = await listMenuIds();
      const g = await createMenu(guest.richmenu, guest.image_b64);
      if (!g.id) return json({ error: "guest_create_failed", detail: g.error }, 500);
      const m = await createMenu(member.richmenu, member.image_b64);
      if (!m.id) return json({ error: "member_create_failed", detail: m.error }, 500);
      // 訪客版設為全體預設（沒被個別綁定的人看到這個）
      const defRes = await fetch(`${API}/user/all/richmenu/${g.id}`, { method: "POST", headers: { ...auth(), "Content-Length": "0" } });
      if (defRes.status !== 200) return json({ error: "setdefault_failed", detail: await defRes.text() }, 500);
      // 會員逐一綁定會員版
      const linked = await bulkLink(m.id, member_user_ids || []);
      const deleted = await deleteMenus(oldIds, [g.id, m.id]);
      return json({ ok: true, guestMenuId: g.id, memberMenuId: m.id, linked, deleted });
    }

    // ── 模式一：legacy 單選單 ──
    const { richmenu, image_b64 } = body;
    if (!richmenu || !image_b64) return json({ error: "missing_payload" }, 400);
    const oldIds = await listMenuIds();
    const c = await createMenu(richmenu, image_b64);
    if (!c.id) return json({ error: "create_failed", detail: c.error }, 500);
    const defRes = await fetch(`${API}/user/all/richmenu/${c.id}`, { method: "POST", headers: { ...auth(), "Content-Length": "0" } });
    if (defRes.status !== 200) return json({ error: "setdefault_failed", status: defRes.status, detail: await defRes.text() }, 500);
    const deleted = await deleteMenus(oldIds, [c.id]);
    return json({ ok: true, richMenuId: c.id, deleted });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

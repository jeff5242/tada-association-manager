// 紙本選票判讀 — Claude Vision 雙重判讀 + 程式端廢票規則
//
// 設計原則：AI 只負責「看見什麼」（每格有無筆跡），
//           廢票判定由程式執行 —— 可稽核、可追溯，不讓模型把辨識與判定混在一起推理。

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const MODEL = 'claude-sonnet-5';

const PROMPT = `這是一張台灣某協會的紙本選舉選票照片。

請執行以下步驟：
1. 讀取右上角「票號」，格式為 11 位數字（例 20260904001）。若模糊不清，ballot_no 填 null。
2. 判斷這是「理事」票還是「監事」票（票面標題有寫）。
3. 由上而下，逐一檢視每位候選人左方的方形空格。
4. 對每一格判斷狀態，只能是以下四種之一：
   - "marked"：格內有明確的 ○、✓、× 或其他人為筆跡
   - "empty"：格內全白，無任何筆跡
   - "unclear"：有淡痕、污漬、或無法確定
   - "erased"：有塗改、劃掉、或重複塗寫的痕跡
5. 候選人名單下方有「另行填寫」區，每列是一個空格加一條橫線，供選民自行書寫姓名。
   逐列回報：空格狀態（同上四種），以及橫線上的手寫姓名（辨識不出或空白則填 null）。

【重要】
- 不要推測選民意圖，看到什麼就回報什麼。
- 不要判斷這張票是否有效或廢票，那不是你的工作。
- 印刷的方框線本身不算筆跡；「另行填寫」區的橫線也是印刷的，不算筆跡。
- 自填姓名請逐字照抄你看到的字，不要猜測、不要對照候選人名單自動更正。看不清的字用「〇」代替。
- 若整張圖看不清楚、歪斜嚴重或有裁切，如實填 image_quality。

只輸出 JSON，不要任何說明文字或 markdown 標記：
{
  "ballot_no": "20260904001",
  "ballot_type": "director",
  "marks": [
    {"no": 1, "name": "陳肇浩", "state": "marked"},
    {"no": 2, "name": "唐迎華", "state": "empty"}
  ],
  "write_ins": [
    {"slot": 1, "state": "marked", "name": "王大明"},
    {"slot": 2, "state": "empty", "name": null}
  ],
  "image_quality": "good",
  "notes": ""
}`;

type Mark = { no: number; name?: string; state: string };
type WriteIn = { slot: number; state: string; name: string | null };
type Read = {
  ballot_no: string | null;
  ballot_type: string | null;
  marks: Mark[];
  write_ins: WriteIn[];
  image_quality: string;
  notes: string;
};

async function readOnce(apiKey: string, imageBase64: string, mediaType: string, temperature: number): Promise<Read | null> {
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 2048,
      temperature,
      messages: [{
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: mediaType, data: imageBase64 } },
          { type: 'text', text: PROMPT },
        ],
      }],
    }),
  });
  const data = await res.json();
  if (data.error) throw new Error(data.error.message ?? 'AI 服務錯誤');

  const text: string = data.content?.[0]?.text ?? '';
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return null;
  try {
    const raw = JSON.parse(m[0]);
    const marks: Mark[] = Array.isArray(raw.marks)
      ? raw.marks
          .filter((x: Mark) => Number.isFinite(Number(x?.no)))
          .map((x: Mark) => ({
            no: Number(x.no),
            name: typeof x.name === 'string' ? x.name : undefined,
            state: ['marked', 'empty', 'unclear', 'erased'].includes(x?.state) ? x.state : 'unclear',
          }))
          .sort((a: Mark, b: Mark) => a.no - b.no)
      : [];
    const writeIns: WriteIn[] = Array.isArray(raw.write_ins)
      ? raw.write_ins
          .filter((x: WriteIn) => Number.isFinite(Number(x?.slot)))
          .map((x: WriteIn) => ({
            slot: Number(x.slot),
            state: ['marked', 'empty', 'unclear', 'erased'].includes(x?.state) ? x.state : 'unclear',
            name: typeof x.name === 'string' && x.name.trim() ? x.name.trim().slice(0, 20) : null,
          }))
          .sort((a: WriteIn, b: WriteIn) => a.slot - b.slot)
      : [];
    const no = typeof raw.ballot_no === 'string' ? raw.ballot_no.replace(/\D/g, '') : '';
    return {
      ballot_no: /^\d{11}$/.test(no) ? no : null,
      ballot_type: raw.ballot_type === 'supervisor' ? 'supervisor' : (raw.ballot_type === 'director' ? 'director' : null),
      marks,
      write_ins: writeIns,
      image_quality: ['good', 'blurry', 'skewed', 'partial'].includes(raw.image_quality) ? raw.image_quality : 'good',
      notes: typeof raw.notes === 'string' ? raw.notes.slice(0, 300) : '',
    };
  } catch {
    return null;
  }
}

// 兩次判讀是否完全一致（票號、票種、每格狀態都要相同）
function sameRead(a: Read, b: Read): boolean {
  if (a.ballot_no !== b.ballot_no) return false;
  if (a.ballot_type !== b.ballot_type) return false;
  if (a.marks.length !== b.marks.length) return false;
  if (!a.marks.every((m, i) => m.no === b.marks[i].no && m.state === b.marks[i].state)) return false;
  if (a.write_ins.length !== b.write_ins.length) return false;
  // 自填欄：狀態必須一致；姓名兩次不同不算「不一致」（本來就要人工認定），但會記錄下來
  return a.write_ins.every((w, i) => w.slot === b.write_ins[i].slot && w.state === b.write_ins[i].state);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: '請求格式錯誤' }, 400); }

  const imageBase64 = body.imageBase64 as string;
  const mediaType   = (body.mediaType as string) ?? 'image/jpeg';
  // 每票圈選上限（限制連記法）：理事 6、監事 1。與「應選席次」是不同概念，廢票依此判定。
  const maxMarks = Number(body.maxMarks ?? body.seats);

  if (!imageBase64) return json({ error: '缺少圖片資料' }, 400);
  if (!Number.isFinite(maxMarks) || maxMarks < 1) return json({ error: '缺少圈選上限' }, 400);

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) return json({ error: '判讀服務未設定 API Key' }, 500);

  // ── 雙重判讀：兩次獨立呼叫，temperature 略有差異以取得獨立觀察 ──
  let r1: Read | null, r2: Read | null;
  try {
    [r1, r2] = await Promise.all([
      readOnce(apiKey, imageBase64, mediaType, 0),
      readOnce(apiKey, imageBase64, mediaType, 0.4),
    ]);
  } catch (e) {
    return json({ error: 'AI 服務錯誤：' + (e instanceof Error ? e.message : String(e)) }, 502);
  }
  if (!r1 || !r2) return json({ error: '判讀結果無法解析，請重拍或改用掃描器' }, 502);

  const agree = sameRead(r1, r2);

  // ══════════════════════════════════════════════════════════════
  // 廢票規則 —— 由程式判定，不交給模型
  // ══════════════════════════════════════════════════════════════
  const marked   = r1.marks.filter(m => m.state === 'marked');
  const unclear  = r1.marks.filter(m => m.state === 'unclear' || m.state === 'erased');

  // 自填欄
  const wMarked  = r1.write_ins.filter(w => w.state === 'marked');
  const wUnclear = r1.write_ins.filter(w => w.state === 'unclear' || w.state === 'erased');
  // 兩次判讀的自填姓名若不同，一併列為需人工確認
  const nameConflict = r1.write_ins.some((w, i) =>
    w.state === 'marked' && (r2.write_ins[i]?.name ?? null) !== (w.name ?? null));

  const totalMarked = marked.length + wMarked.length;

  let verdict: 'valid' | 'invalid_blank' | 'invalid_over' | 'manual';
  let reason = '';

  if (!agree)                          { verdict = 'manual'; reason = '兩次判讀結果不一致'; }
  else if (r1.image_quality !== 'good'){ verdict = 'manual'; reason = `影像品質不佳（${r1.image_quality}）`; }
  else if (unclear.length + wUnclear.length > 0)
                                       { verdict = 'manual'; reason = `有 ${unclear.length + wUnclear.length} 格無法確定或有塗改`; }
  else if (!r1.ballot_no)              { verdict = 'manual'; reason = '票號無法辨識'; }
  else if (totalMarked === 0)          { verdict = 'invalid_blank'; reason = '空白票'; }
  else if (totalMarked > maxMarks)     { verdict = 'invalid_over';  reason = `圈選 ${totalMarked} 人，超過每票上限 ${maxMarks} 人`; }
  // 手寫姓名必須由人確認對應到哪位會員，不可由 AI 逕行認定
  else if (wMarked.length > 0)         { verdict = 'manual';
                                         reason = `有 ${wMarked.length} 筆自行填寫（${wMarked.map(w => w.name || '姓名未辨識').join('、')}）需人工認定`
                                                + (nameConflict ? '；兩次判讀姓名不同' : ''); }
  else                                 { verdict = 'valid'; }

  return json({
    ok: true,
    ballot_no: r1.ballot_no,
    ballot_type: r1.ballot_type,
    image_quality: r1.image_quality,
    agree,
    marked_count: totalMarked,
    marked_nos: marked.map(m => m.no),
    write_ins: r1.write_ins,
    write_ins_marked: wMarked.map(w => ({ slot: w.slot, name: w.name, name2: r2.write_ins.find(x => x.slot === w.slot)?.name ?? null })),
    unclear_nos: unclear.map(m => m.no),
    verdict,
    reason,
    max_marks: maxMarks,
    read1: r1,
    read2: r2,
  });
});

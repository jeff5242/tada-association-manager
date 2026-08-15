/**
 * 產生「補發團體代表選票」的 SQL。
 *
 * 現況：每個團體會員在 tada_v_members 只有一列，rep 欄位指定了其中一位代表。
 * 規則（2026-08-15 確認）：**每位代表各領一張票**，所以其餘代表要補列。
 *
 * 產生的 SQL 分兩段：
 *   1. UPDATE：把既有那列的 member_no 加上代表序號（base → base-N），
 *      讓所有代表的編號規則一致，才對得上 member_verify_by_tax 回傳的 base-N。
 *   2. INSERT：補上其餘代表。is_checked_in 一律 false。
 *
 * **只產生 SQL，不直接寫資料庫。** 這是選票，要由人看過再執行。
 *
 * 用法：node scripts/generate-rep-ballots.mjs [--election <id>]
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const COMMON = fileURLToPath(new URL('../assets/liff-common.js', import.meta.url))
const OUT = '/tmp/tada-rep-ballots.sql'

const js = readFileSync(COMMON, 'utf8')
const SB_URL = js.match(/window\.TADA_SB_URL\s*=\s*['"]([^'"]+)/)?.[1]
const SB_KEY = js.match(/window\.TADA_SB_KEY\s*=\s*['"]([^'"]+)/)?.[1]
const H = { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` }

const get = async (path) => {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { headers: H })
  if (!r.ok) throw new Error(`${path} → HTTP ${r.status}`)

  return r.json()
}

const norm = (s) => String(s ?? '').replace(/\s+/g, '').trim()
const q = (s) => `'${String(s ?? '').replace(/'/g, "''")}'`

const args = process.argv.slice(2)
const forced = args[args.indexOf('--election') + 1]

const elections = await get('tada_v_election?select=id,title,status&order=created_at.desc')
const election = forced
  ? elections.find((e) => e.id === forced)
  : elections.find((e) => ['checkin', 'open'].includes(e.status)) ?? elections[0]
console.log(`場次：${election.title}（${election.status}）\n`)

const members = await get(
  'tada_members?select=member_no,member_type,name,company,reps,status&member_type=eq.group',
)
const ballots = await get(
  `tada_v_members?election_id=eq.${election.id}&select=member_no,name,member_type,rep,is_checked_in`,
)

const active = members.filter((m) => !/退會|退出|停權|註銷/.test(String(m.status ?? '')))

const updates = []
const inserts = []
const warnings = []

for (const m of active) {
  const base = norm(m.member_no)
  const reps = Array.isArray(m.reps) ? m.reps.filter((r) => norm(r?.name)) : []
  if (!reps.length) continue

  // 這個團體現有的票（base 或 base-N 都算）
  const mine = ballots.filter((b) => norm(b.member_no) === base || norm(b.member_no).startsWith(`${base}-`))
  if (!mine.length) {
    warnings.push(`${base} ${m.company ?? m.name}：選舉名冊完全沒有這個團體的票，未處理`)
    continue
  }

  for (const [i, rep] of reps.entries()) {
    const idx = i + 1
    const repName = norm(rep.name)
    const already = mine.find((b) => norm(b.rep) === repName)

    if (already) {
      const want = `${base}-${idx}`
      if (norm(already.member_no) !== want) {
        updates.push({ from: already.member_no, to: want, rep: rep.name,
                       company: m.company ?? m.name, checked: already.is_checked_in })
      }
      continue
    }
    inserts.push({ member_no: `${base}-${idx}`, name: m.company ?? m.name, rep: rep.name })
  }

  // 名冊上找不到對應代表的既有票 → 人工確認，絕不自動刪
  for (const b of mine) {
    if (!reps.some((r) => norm(r.name) === norm(b.rep))) {
      warnings.push(`${b.member_no} 的 rep「${b.rep}」不在主名冊的代表清單中，請人工確認（未更動）`)
    }
  }
}

console.log(`既有票要改編號  ${updates.length} 筆`)
console.log(`要補發的代表票  ${inserts.length} 筆`)
console.log(`需人工確認      ${warnings.length} 筆`)
if (warnings.length) { console.log(''); warnings.forEach((w) => console.log('  ⚠', w)) }

const sql = `-- 補發團體代表選票
-- 場次：${election.title}
-- 產生時間由執行者自行記錄；本檔由 scripts/generate-rep-ballots.mjs 產出
--
-- 規則：每位團體代表各領一張票。
-- 第一段把既有票的編號補上代表序號，第二段補上其餘代表。
-- 執行位置：Supabase SQL Editor。**請先看過再 RUN。**

BEGIN;

-- ① 既有票加上代表序號，讓編號規則與 member_verify_by_tax 回傳的 base-N 一致
${updates.length ? updates.map((u) =>
`UPDATE tada_v_members SET member_no = ${q(u.to)}
 WHERE election_id = ${q(election.id)} AND member_no = ${q(u.from)};   -- ${u.company} ${u.rep}${u.checked ? ' ⚠已報到' : ''}`
).join('\n') : '-- （沒有需要改的）'}

-- ② 補發其餘代表的票
${inserts.length ? inserts.map((r) =>
`INSERT INTO tada_v_members (election_id, member_no, name, member_type, rep, is_checked_in)
 SELECT ${q(election.id)}, ${q(r.member_no)}, ${q(r.name)}, 'group', ${q(r.rep)}, FALSE
 WHERE NOT EXISTS (SELECT 1 FROM tada_v_members
                    WHERE election_id = ${q(election.id)} AND member_no = ${q(r.member_no)});`
).join('\n') : '-- （沒有需要補的）'}

-- 執行後應有的票數
SELECT COUNT(*) AS 總票數,
       COUNT(*) FILTER (WHERE member_type = 'group') AS 團體票
  FROM tada_v_members WHERE election_id = ${q(election.id)};

COMMIT;
`
writeFileSync(OUT, sql, 'utf8')
console.log(`\nSQL 已寫入 ${OUT}`)
console.log(`執行後票數：${ballots.length} → ${ballots.length + inserts.length}`)

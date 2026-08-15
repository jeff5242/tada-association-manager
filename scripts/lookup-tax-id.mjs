/**
 * 用 g0v 公司登記 API 幫會員名冊補統一編號。
 *   https://company.g0v.ronny.tw/
 *
 * 預設是**只查不寫**：產出對照表讓人先看過。統編要拿來做身分驗證，
 * 寫錯一筆等於那位會員報不了到，甚至比對到別人——不該全自動。
 *
 * 分類：
 *   exact   公司名稱正規化後完全相符，且只對到一家 → 可以直接寫回
 *   review  對到多家、或名稱不完全相符           → 需要人工確認
 *   none    查無                                  → 多半是農會、產銷班等不在登記資料庫的組織
 *
 * 用法：
 *   node scripts/lookup-tax-id.mjs              # 只查，產出 /tmp/tada-taxid.csv
 *   node scripts/lookup-tax-id.mjs --apply      # 把 exact 的寫回 tada_members.tax_id
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const COMMON = fileURLToPath(new URL('../assets/liff-common.js', import.meta.url))
const OUT = '/tmp/tada-taxid.csv'
const API = 'https://company.g0v.ronny.tw/api/search'
/** 這是志工維護的免費服務，別打太快 */
const DELAY_MS = 350

const js = readFileSync(COMMON, 'utf8')
const SB_URL = js.match(/window\.TADA_SB_URL\s*=\s*['"]([^'"]+)/)?.[1]
const SB_KEY = js.match(/window\.TADA_SB_KEY\s*=\s*['"]([^'"]+)/)?.[1]
if (!SB_URL || !SB_KEY) throw new Error('assets/liff-common.js 裡找不到 Supabase 設定')
const sbHeaders = { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/**
 * 名稱正規化。
 * 名冊裡寫「祥圃實業(股)公司」，登記資料是「祥圃實業股份有限公司」——
 * 不展開這些縮寫就會全部比不上。
 */
function normalize(raw) {
  return String(raw ?? '')
    .replace(/[！-～]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0)) // 全形轉半形
    .replace(/\s+/g, '')
    .replace(/[（(]股[)）]公司/g, '股份有限公司')
    .replace(/[（(]有[)）]公司/g, '有限公司')
    .replace(/[（(]股[)）]/g, '股份有限公司')
    .replace(/台/g, '臺')          // 臺灣／台灣 兩種寫法都有
    .trim()
}

const digits = (s) => String(s ?? '').replace(/\D/g, '')

async function searchCompany(name) {
  const url = `${API}?q=${encodeURIComponent(name)}`
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(20000) })
      if (res.status === 429) { await sleep(2000 * (attempt + 1)); continue }
      if (!res.ok) return { error: `HTTP ${res.status}` }

      return { items: (await res.json()).data ?? [] }
    } catch (error) {
      if (attempt === 2) return { error: error.message }
      await sleep(1000 * (attempt + 1))
    }
  }

  return { error: '重試耗盡' }
}

/** 登記資料裡公司叫「公司名稱」、商號叫「商業名稱」 */
const entryName = (it) => it['公司名稱'] ?? it['商業名稱'] ?? ''

/** 比對用：把台／臺也統一，避免同一家因為用字不同而比不上 */
const cmpKey = (s) => normalize(s).replace(/臺/g, '台')

/**
 * 產生要送去查的候選字串。
 *
 * 名冊的 company 欄位不是乾淨的公司名——後面常接職稱
 * （「統一超商股份有限公司食材採購經理」「葳蕓企業有限公司 經理」），
 * 也有「(股)公司」這種縮寫。直接把原始字串丟去查會大量落空。
 */
function queryCandidates(raw) {
  const norm = normalize(raw)                    // (股)公司 → 股份有限公司、去空白
  const out = [norm, norm.replace(/臺/g, '台')]

  // 截到公司型態關鍵字為止，丟掉後面的職稱／附註
  const m = norm.match(/^(.*?(?:股份有限公司|有限公司|公司|商行|企業社|工作室|農場|牧場))/)
  if (m) out.push(m[1], m[1].replace(/臺/g, '台'))

  // 去掉括號附註：「青松農場(天下第一菇)」→「青松農場」
  const noParen = norm.replace(/[（(][^）)]*[）)]/g, '')
  if (noParen && noParen !== norm) out.push(noParen, noParen.replace(/臺/g, '台'))

  // 去掉公司型態後綴，只留核心關鍵字（找不到完整名稱時的退路，之後用人名收斂）
  const bare = norm.replace(/(股份有限公司|有限公司|股份公司|企業有限公司|公司|商行|企業社|工作室|農場|牧場|合作社|農會)$/, '')
  if (bare && bare.length >= 2 && bare !== norm) out.push(bare, bare.replace(/臺/g, '台'))

  out.push(String(raw).trim())                   // 最後才試原始字串

  return [...new Set(out.filter((x) => x && x.length >= 2))]
}

/** 會員姓名是否出現在該公司的代表人／董監事／經理人名單（多筆時用來收斂） */
function personMatch(it, memberName) {
  const n = String(memberName ?? '').replace(/\s+/g, '')
  if (n.length < 2) return false
  const names = [it['代表人姓名'], it['公司名稱'], it['商業名稱']]
  for (const key of ['董監事名單', '經理人名單']) {
    const arr = it[key]
    if (Array.isArray(arr)) for (const d of arr) names.push(d?.['姓名'] ?? d?.['姓名 '] ?? '')
  }
  return names.some((f) => String(f ?? '').replace(/\s+/g, '').includes(n))
}

async function main() {
  const apply = process.argv.includes('--apply')

  const res = await fetch(
    `${SB_URL}/rest/v1/tada_members?select=id,member_no,member_type,name,company,tax_id,status&order=member_no.asc`,
    { headers: sbHeaders },
  )
  if (!res.ok) throw new Error(`讀取名冊失敗 HTTP ${res.status}`)
  const all = await res.json()

  const active = all.filter((m) => !/退會|退出|停權|註銷/.test(String(m.status ?? '')))
  const targets = active.filter((m) => String(m.company ?? '').trim())

  console.log(`名冊 ${all.length} 筆，在籍 ${active.length} 筆，其中有公司名稱 ${targets.length} 筆`)
  console.log(`已有 8 碼統編：${active.filter((m) => digits(m.tax_id).length === 8).length} 筆`)
  console.log(`\n開始查詢（每筆間隔 ${DELAY_MS}ms）…\n`)

  const rows = []
  let exact = 0, review = 0, none = 0, failed = 0

  for (const [i, m] of targets.entries()) {
    const company = String(m.company).trim()
    const candidates = queryCandidates(company)

    // 逐個候選字串試，累積候選公司（依統編去重）；一有乾淨的單一完全相符就停
    const pool = new Map()
    let usedQuery = '', error = null, cleanExact = null
    for (const q of candidates) {
      const r = await searchCompany(q)
      await sleep(DELAY_MS)
      if (r.error) { error = r.error; break }

      const found = (r.items ?? []).filter((it) => digits(it['統一編號']).length === 8)
      for (const it of found) if (!pool.has(it['統一編號'])) pool.set(it['統一編號'], it)
      const exactly = found.filter((it) => candidates.some((c) => cmpKey(entryName(it)) === cmpKey(c)))
      if (exactly.length === 1) { cleanExact = exactly[0]; usedQuery = q; break }
      if (pool.size > 40) break            // 關鍵字撈太多 → 停手，改用人名收斂
    }

    if (error) {
      failed += 1
      rows.push({ ...m, company, verdict: 'error', tax: '', matched: '', note: error })
      process.stdout.write('!')
      continue
    }

    const items = [...pool.values()]
    const exactHits = items.filter((it) => candidates.some((c) => cmpKey(entryName(it)) === cmpKey(c)))
    const nameHits = items.filter((it) => personMatch(it, m.name))

    if (cleanExact || exactHits.length === 1) {
      const hit = cleanExact || exactHits[0]
      exact += 1
      rows.push({ ...m, company, verdict: 'exact', tax: hit['統一編號'],
                  matched: entryName(hit), note: usedQuery && usedQuery !== normalize(company) ? `查詢字串：${usedQuery}` : '' })
      process.stdout.write('.')
    } else if (nameHits.length === 1) {
      exact += 1                            // 人名對到唯一一家 → 視為可寫回
      rows.push({ ...m, company, verdict: 'name', tax: nameHits[0]['統一編號'],
                  matched: entryName(nameHits[0]), note: `姓名比對代表人/董監事：${m.name}` })
      process.stdout.write('n')
    } else if (items.length) {
      review += 1
      rows.push({ ...m, company, verdict: 'review', tax: items[0]['統一編號'],
                  matched: entryName(items[0]),
                  note: `共 ${items.length} 筆候選；${items.slice(0, 4).map((h) => `${h['統一編號']} ${entryName(h)}`).join(' ｜ ')}` })
      process.stdout.write('?')
    } else {
      none += 1
      rows.push({ ...m, company, verdict: 'none', tax: '', matched: '', note: '查無登記資料' })
      process.stdout.write('x')
    }

    if ((i + 1) % 60 === 0) process.stdout.write(` ${i + 1}/${targets.length}\n`)
  }

  console.log(`\n\n──────── 結果 ────────`)
  console.log(`完全相符 exact   ${exact}\t可直接寫回`)
  console.log(`需人工確認 review ${review}\t對到多家或名稱不一致`)
  console.log(`查無 none        ${none}\t農會、產銷班等不在登記資料庫`)
  console.log(`查詢失敗 error   ${failed}`)

  const esc = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`
  writeFileSync(OUT, '﻿' + [
    '判定,會員編號,類型,姓名,名冊上的公司,查到的名稱,統一編號,原有統編,備註',
    ...rows.map((r) => [r.verdict, r.member_no, r.member_type, r.name, r.company,
                        r.matched, r.tax, r.tax_id ?? '', r.note].map(esc).join(',')),
  ].join('\n'), 'utf8')
  console.log(`\n對照表已寫入 ${OUT}（含公司與姓名，勿放進 repo）`)

  if (!apply) {
    console.log(`\n目前是唯讀模式。確認過 exact 那批之後，加 --apply 才會寫回資料庫。`)

    return
  }

  // ── 寫回：只寫 exact，且只覆蓋原本沒有 8 碼統編的 ──
  const writable = rows.filter(
    (r) => (r.verdict === 'exact' || r.verdict === 'name') && digits(r.tax_id).length !== 8,
  )
  console.log(`\n開始寫回 ${writable.length} 筆（exact＋人名比對，原本已有正確統編的不動）…`)

  let ok = 0, bad = 0
  for (const r of writable) {
    const put = await fetch(`${SB_URL}/rest/v1/tada_members?id=eq.${r.id}`, {
      method: 'PATCH',
      headers: { ...sbHeaders, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({ tax_id: r.tax }),
    })
    if (put.ok) { ok += 1; process.stdout.write('.') } else { bad += 1; process.stdout.write('!') }
    await sleep(60)
  }
  console.log(`\n寫回完成：成功 ${ok}、失敗 ${bad}`)
}

main().catch((error) => {
  console.error('\n執行失敗：', error.message)
  process.exit(1)
})

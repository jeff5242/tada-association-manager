/**
 * 比對「主名冊 tada_members」與「選舉名冊 tada_v_members」。
 *
 * 要回答的問題：**團體會員的每一位代表，在選舉名冊裡都有自己的一列嗎？**
 * 沒有的話，那位代表活動當天會領不到票。
 *
 * 隱私：
 *   本腳本會讀到真實會員資料。終端機只印統計與遮蔽後的姓名（王○○），
 *   完整明細寫到 repo 之外的 /tmp/tada-roster-diff.csv，不會進版控。
 *
 * 用法：
 *   node scripts/compare-election-roster.mjs
 *   node scripts/compare-election-roster.mjs --election <election_id>
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const COMMON = fileURLToPath(new URL('../assets/liff-common.js', import.meta.url))
const OUT = '/tmp/tada-roster-diff.csv'

function readConfig() {
  const js = readFileSync(COMMON, 'utf8')
  const url = js.match(/window\.TADA_SB_URL\s*=\s*['"]([^'"]+)/)?.[1]
  const key = js.match(/window\.TADA_SB_KEY\s*=\s*['"]([^'"]+)/)?.[1]
  if (!url || !key) throw new Error('assets/liff-common.js 裡找不到 Supabase 設定')

  return { url, key }
}

const { url: SB_URL, key: SB_KEY } = readConfig()
const headers = { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` }

async function getAll(path) {
  const rows = []
  const PAGE = 1000
  for (let from = 0; ; from += PAGE) {
    const res = await fetch(`${SB_URL}/rest/v1/${path}`, {
      headers: { ...headers, Range: `${from}-${from + PAGE - 1}` },
    })
    if (!res.ok) throw new Error(`${path} → HTTP ${res.status}`)
    const page = await res.json()
    rows.push(...page)
    if (page.length < PAGE) return rows
  }
}

/** 王小明 → 王○○；用於終端機輸出，完整姓名只寫檔案 */
function mask(name) {
  const s = String(name ?? '').trim()
  if (s.length <= 1) return s || '(無名)'

  return s[0] + '○'.repeat(s.length - 1)
}

const digits = (s) => String(s ?? '').replace(/\D/g, '')

async function main() {
  const args = process.argv.slice(2)
  const forced = args[args.indexOf('--election') + 1]

  // 場次：優先用指定的，否則取目前開放報到／投票的那一場
  const elections = await getAll('tada_v_election?select=id,title,status&order=created_at.desc')
  const election = forced
    ? elections.find((e) => e.id === forced)
    : elections.find((e) => ['checkin', 'open'].includes(e.status)) ?? elections[0]
  if (!election) throw new Error('找不到任何選舉場次')
  console.log(`場次：${election.title}（${election.status}）\n`)

  const members = await getAll(
    'tada_members?select=member_no,member_type,name,company,tax_id,reps,status,mobile,phone_office,contact_phone&order=member_no.asc',
  )
  const ballots = await getAll(
    `tada_v_members?election_id=eq.${election.id}&select=member_no,name,member_type&order=member_no.asc`,
  )

  console.log(`主名冊 tada_members      ${members.length} 筆（其中退會等非在籍 ${members.length - members.filter(m=>!/退會|退出|停權|註銷/.test(String(m.status??''))).length} 筆已排除）`)
  console.log(`選舉名冊 tada_v_members  ${ballots.length} 筆`)

  // 退會／停權者本來就不該有選票，排除後剩下的才是真的缺漏
  const isActive = (m) => !/退會|退出|停權|註銷/.test(String(m.status ?? ''))
  const active = members.filter(isActive)
  const resigned = members.length - active.length

  const groups = active.filter((m) => m.member_type === 'group')
  const repTotal = groups.reduce((n, m) => n + (Array.isArray(m.reps) ? m.reps.length : 0), 0)
  const personal = active.filter((m) => m.member_type !== 'group')

  console.log(`\n主名冊組成：個人 ${personal.length}　團體 ${groups.length}（代表共 ${repTotal} 位）`)
  console.log(`若「每位代表各一票」，選舉名冊應有 ${personal.length} + ${repTotal} = ${personal.length + repTotal} 筆`)
  console.log(`若「每個團體一票」，  應有 ${personal.length} + ${groups.length} = ${personal.length + groups.length} 筆`)
  console.log(`實際                  ${ballots.length} 筆`)

  // ── 選舉名冊的編號怎麼對應主名冊 ───────────────────────────────
  const byNo = new Map(members.map((m) => [String(m.member_no ?? '').trim(), m]))
  const ballotNos = new Set(ballots.map((b) => String(b.member_no ?? '').trim()))

  const matchedDirect = ballots.filter((b) => byNo.has(String(b.member_no).trim()))
  const suffixed = ballots.filter((b) => /-\d+$/.test(String(b.member_no)))
  const orphan = ballots.filter(
    (b) => !byNo.has(String(b.member_no).trim()) && !/-\d+$/.test(String(b.member_no)),
  )

  console.log(`\n選舉名冊編號比對：`)
  console.log(`  直接對到主名冊編號    ${matchedDirect.length}`)
  console.log(`  帶「-N」代表編號      ${suffixed.length}`)
  console.log(`  對不到主名冊          ${orphan.length}`)

  // ── 每位代表有沒有票 ──────────────────────────────────────────
  const missing = []
  for (const g of groups) {
    const reps = Array.isArray(g.reps) ? g.reps : []
    const base = String(g.member_no ?? '').trim()
    reps.forEach((rep, i) => {
      const suffix = `${base}-${i + 1}`
      // 代表可能以「編號-N」、也可能以自己的姓名出現在選舉名冊
      const hasSuffixRow = ballotNos.has(suffix)
      const hasNameRow = ballots.some(
        (b) => String(b.name ?? '').trim() && String(b.name).trim() === String(rep?.name ?? '').trim(),
      )
      if (!hasSuffixRow && !hasNameRow) {
        missing.push({
          member_no: base,
          company: g.company ?? '',
          rep_index: i + 1,
          rep_name: rep?.name ?? '',
          rep_tel: rep?.tel ?? '',
          expected_no: suffix,
        })
      }
    })
  }

  // ── 個人會員有沒有票 ──────────────────────────────────────────
  const personalMissing = personal.filter((m) => {
    const no = String(m.member_no ?? '').trim()
    return no && !ballotNos.has(no)
  })

  console.log(`\n──────── 結論 ────────`)
  console.log(`團體代表領不到票  ${missing.length} 位`)
  console.log(`個人會員領不到票  ${personalMissing.length} 位`)

  if (missing.length) {
    console.log(`\n領不到票的代表（前 10 位，姓名已遮蔽）：`)
    for (const r of missing.slice(0, 10)) {
      console.log(`  ${r.member_no}  ${r.company}  第 ${r.rep_index} 位代表  ${mask(r.rep_name)}  手機 ${digits(r.rep_tel) ? '有' : '缺'}`)
    }
  }
  if (personalMissing.length) {
    console.log(`\n領不到票的個人會員（前 10 位）：`)
    for (const m of personalMissing.slice(0, 10)) {
      console.log(`  ${m.member_no}  ${mask(m.name)}  狀態 ${m.status ?? '—'}`)
    }
  }

  // ── 手機資料完整度（統編＋手機驗證會用到）──────────────────────
  const repNoTel = groups.flatMap((g) =>
    (Array.isArray(g.reps) ? g.reps : []).filter((r) => !digits(r?.tel)),
  ).length
  const personalNoPhone = personal.filter(
    (m) => !digits(m.mobile) && !digits(m.phone_office) && !digits(m.contact_phone),
  ).length
  const noTaxId = active.filter((m) => digits(m.tax_id).length !== 8).length

  console.log(`\n──────── 統編＋手機驗證的資料完整度 ────────`)
  console.log(`統編非 8 碼或空白    ${noTaxId} 筆　→ 這些人無法用統編報到`)
  console.log(`個人會員無任何電話    ${personalNoPhone} 筆`)
  console.log(`團體代表無手機        ${repNoTel} 位`)

  // ── 完整明細寫到 repo 之外 ────────────────────────────────────
  const csv = [
    '類型,會員編號,公司,代表序,姓名,手機,應有的選舉編號',
    ...missing.map((r) =>
      ['團體代表缺票', r.member_no, r.company, r.rep_index, r.rep_name, r.rep_tel, r.expected_no]
        .map((v) => `"${String(v ?? '').replace(/"/g, '""')}"`).join(','),
    ),
    ...personalMissing.map((m) =>
      ['個人會員缺票', m.member_no, m.company ?? '', '', m.name, m.mobile ?? '', m.member_no]
        .map((v) => `"${String(v ?? '').replace(/"/g, '""')}"`).join(','),
    ),
  ].join('\n')
  writeFileSync(OUT, '﻿' + csv, 'utf8')   // BOM：Excel 開啟才不會亂碼

  console.log(`\n完整明細（含姓名與手機）已寫入 ${OUT}`)
  console.log(`⚠ 該檔含個資，請勿放進 repo 或傳到公開場所。`)
}

main().catch((error) => {
  console.error('比對失敗：', error.message)
  process.exit(1)
})

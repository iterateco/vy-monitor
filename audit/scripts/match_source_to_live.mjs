// Ground-truth source==live matcher by SELECTOR SET.
// 1) Extract every 4-byte selector from the live runtime bytecode dispatcher (PUSH4 ... EQ pattern).
// 2) For each candidate solcInputs source for <Name>, parse external/public function signatures,
//    compute selectors, and report: how many candidate selectors are present in live, and how many
//    live selectors are NOT explained by the candidate (after accounting for inherited OZ selectors).
// usage: node match_source_to_live.mjs <ContractName> <mainPathSuffix>
import fs from 'node:fs'
import path from 'node:path'
import { keccak256, toBytes } from 'viem'
import { safeRpc, SLOTS, addrFromSlot } from './rpc.mjs'

const VAL = '/Users/sergiosolano/Valinity'
const DEPLOY = path.join(VAL, 'deployments/eth_mainnet')
const SI = path.join(DEPLOY, 'solcInputs')
const name = process.argv[2]
const suffix = process.argv[3] || ('treasury/' + name + '.sol')

const art = JSON.parse(fs.readFileSync(path.join(DEPLOY, name + '.json'), 'utf8'))
const proxy = art.address
const implSlot = await safeRpc('eth_getStorageAt', [proxy, SLOTS.impl, 'latest'])
const impl = addrFromSlot(implSlot)
const codeAddr = (impl && impl !== '0x0000000000000000000000000000000000000000') ? impl : proxy
const live = (await safeRpc('eth_getCode', [codeAddr, 'latest'])).toLowerCase().slice(2)

// Extract selectors: match "63" + 8 hex (PUSH4) followed shortly by "14" (EQ). Capture all PUSH4 imms,
// then keep those that the dispatcher compares. Simplest robust heuristic: all PUSH4 immediates.
const liveSelectors = new Set()
for (let i = 0; i + 10 <= live.length; i += 2) {
  if (live.slice(i, i + 2) === '63') {
    const imm = live.slice(i + 2, i + 10)
    if (/^[0-9a-f]{8}$/.test(imm)) liveSelectors.add(imm)
  }
}

// Standard inherited selectors (OZ AccessControl + UUPS + ERC165) — present in most proxies, not in app source.
const INHERITED = ['supportsInterface(bytes4)','hasRole(bytes32,address)','getRoleAdmin(bytes32)','grantRole(bytes32,address)','revokeRole(bytes32,address)','renounceRole(bytes32,address)','DEFAULT_ADMIN_ROLE()','proxiableUUID()','upgradeToAndCall(address,bytes)','UPGRADE_INTERFACE_VERSION()']
  .map(s => keccak256(toBytes(s)).slice(2, 10))

// Parse external/public function signatures from a source string (best-effort: handles multi-line params).
function sigsFromSource(src) {
  const out = []
  const re = /function\s+([A-Za-z_]\w*)\s*\(([\s\S]*?)\)\s*(external|public)/g
  let m
  while ((m = re.exec(src)) !== null) {
    const fname = m[1]
    const params = m[2]
    // extract the type of each param (first token of each comma-split, stripping mappings/structs is hard;
    // we take the leading type word and array suffix). Skip if empty.
    const types = params.trim() === '' ? [] : params.split(',').map(p => {
      const t = p.trim().split(/\s+/)[0]
      return t
    })
    out.push({ fname, sig: fname + '(' + types.join(',') + ')' })
  }
  return out
}

const candidates = []
for (const f of fs.readdirSync(SI)) {
  if (!f.endsWith('.json')) continue
  let si; try { si = JSON.parse(fs.readFileSync(path.join(SI, f), 'utf8')) } catch { continue }
  const key = Object.keys(si.sources || {}).find(k => k.endsWith(suffix))
  if (!key) continue
  const src = si.sources[key].content
  const sigs = sigsFromSource(src)
  let present = 0, absent = []
  for (const s of sigs) {
    const sel = keccak256(toBytes(s.sig)).slice(2, 10)
    // leading-zero-safe: selectors with leading 00 byte(s) are PUSHed with a shorter opcode,
    // so the PUSH4-immediate set (liveSelectors) won't contain the zero-padded form. Match the
    // stripped form against any live selector's stripped form too.
    const strip = (x) => x.replace(/^(00)+/, '') || x
    const ss = strip(sel)
    if (liveSelectors.has(sel) || [...liveSelectors].some(ls => strip(ls) === ss)) present++; else absent.push(s.sig)
  }
  candidates.push({ hash: f.replace('.json', ''), lines: src.split('\n').length, funcs: sigs.length, present, absentCount: absent.length, absent: absent.slice(0, 8) })
}

candidates.sort((a, b) => a.absentCount - b.absentCount || b.present - a.present)
console.log('live runtime selectors found:', liveSelectors.size, '| codeAddr:', codeAddr)
console.log('candidate sources (sorted best-match first; absent = source fn NOT in live → drift):')
for (const c of candidates) {
  console.log(`  ${c.hash.slice(0,12)}…  lines=${c.lines} srcFns=${c.funcs} present=${c.present} absentFromLive=${c.absentCount}` + (c.absent.length ? '  e.g. ' + c.absent.join(', ') : ''))
}
const best = candidates[0]
console.log('\nBEST:', best ? (best.hash + '  (' + best.absentCount + ' source fns absent from live)') : 'none')
console.log(best && best.absentCount === 0 ? 'A local source FULLY matches live ✅ — extract from this hash.' : 'NO local source fully matches live ❌ — need Etherscan/Sourcify for exact live source.')

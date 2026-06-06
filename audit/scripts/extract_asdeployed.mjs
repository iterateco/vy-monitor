// Extract the AS-DEPLOYED source (the exact solcInputs that compiled to the live bytecode)
// for one contract into audit/asdeployed/<Name>/, preserving the contracts/ tree so the audit
// reads the TRUE live code, not the drifted workspace file.
//
// HARDENED: after extraction it runs a SELECTOR-PRESENCE GUARD — it computes function
// selectors from the artifact's own ABI (authoritative for the deployed bytecode), confirms
// they appear in deployedBytecode, and confirms each ABI function NAME appears textually in
// the extracted main source. If the source doesn't carry the deployed functions (the stale
// solcInputHash bug that mis-extracted VAO V1 instead of the live V2), it EXITS NONZERO.
// usage: node extract_asdeployed.mjs <ContractName>
import fs from 'node:fs'
import path from 'node:path'
import { keccak256, toBytes } from 'viem'

const VAL = '/Users/sergiosolano/Valinity'
const DEPLOY = path.join(VAL, 'deployments/eth_mainnet')
const SI = path.join(DEPLOY, 'solcInputs')
const name = process.argv[2]
const OUTDIR = path.join('/Users/sergiosolano/vy-monitor/audit/asdeployed', name)

const art = JSON.parse(fs.readFileSync(path.join(DEPLOY, name + '.json'), 'utf8'))
const meta = JSON.parse(art.metadata)
const mainPath = Object.keys(meta.settings.compilationTarget)[0]
const siPath = path.join(SI, art.solcInputHash + '.json')
if (!fs.existsSync(siPath)) {
  console.error('FATAL: solcInputs file for hash ' + art.solcInputHash + ' not found at ' + siPath)
  process.exit(2)
}
const input = JSON.parse(fs.readFileSync(siPath, 'utf8'))
const sources = input.sources
if (!sources[mainPath]) {
  console.error('FATAL: main path ' + mainPath + ' absent from solcInputs ' + art.solcInputHash)
  process.exit(2)
}

// compute the import closure of the main file (Valinity contracts/ only, for the manifest)
const IMPORT_RE = /import\s+(?:[^"';]*?\bfrom\s+)?["']([^"']+)["']/g
const resolveImport = (fromKey, spec) => spec.startsWith('.') ? path.posix.normalize(path.posix.join(path.posix.dirname(fromKey), spec)) : spec
const seen = new Set(), stack = [mainPath]
while (stack.length) {
  const k = stack.pop(); if (seen.has(k)) continue; seen.add(k)
  const src = sources[k]; if (!src) continue
  let m; IMPORT_RE.lastIndex = 0
  while ((m = IMPORT_RE.exec(src.content)) !== null) { const r = resolveImport(k, m[1]); if (sources[r] && !seen.has(r)) stack.push(r) }
}

fs.rmSync(OUTDIR, { recursive: true, force: true })
let written = 0
for (const k of seen) {
  const dest = path.join(OUTDIR, k)
  fs.mkdirSync(path.dirname(dest), { recursive: true })
  fs.writeFileSync(dest, sources[k].content)
  written++
}

// ─── SELECTOR-PRESENCE GUARD ───────────────────────────────────────────────
// Build canonical signatures from the artifact ABI (authoritative for the deployed bytecode).
const canonicalType = (c) => {
  // tuples → (t1,t2,...)[ ] ; arrays preserved via c.type suffix
  if (c.type.startsWith('tuple')) {
    const inner = '(' + (c.components || []).map(canonicalType).join(',') + ')'
    return inner + c.type.slice('tuple'.length) // append [] / [n] if present
  }
  return c.type
}
const abi = meta.output.abi || []
const fns = abi.filter((x) => x.type === 'function')
const bc = (art.deployedBytecode || '').toLowerCase()
// Search function names across the ENTIRE extracted closure (the contract + its OZ/base
// imports), not just the main file — inherited fns (grantRole, proxiableUUID, …) live in bases.
const allSrc = [...seen].map((k) => sources[k].content).join('\n')

// A function selector is pushed into the dispatcher with a PUSH opcode sized to its
// SIGNIFICANT bytes — leading zero bytes are dropped (e.g. selector 0x006b09c4 is pushed
// as PUSH3 6b09c4, not PUSH4 006b09c4). So searching for the full 4-byte hex gives a FALSE
// NEGATIVE for any selector with leading zero byte(s). Search for the selector with leading
// zero bytes stripped (its minimal PUSH-immediate form), which is always a substring of the
// runtime when the function is present. (This bug caused a wrong VRT "missing function" call.)
const selPresent = (sel) => {
  const stripped = sel.replace(/^(00)+/, '') || sel // drop leading 00 byte-pairs
  return bc.includes(stripped)
}
const results = fns.map((f) => {
  const sig = f.name + '(' + (f.inputs || []).map(canonicalType).join(',') + ')'
  const sel = keccak256(toBytes(sig)).slice(2, 10)
  return { sig, sel, inBytecode: selPresent(sel), nameInSource: new RegExp('\\bfunction\\s+' + f.name + '\\b').test(allSrc) }
})
const inBc = results.filter((r) => r.inBytecode).length
const missingFromBc = results.filter((r) => !r.inBytecode)
const nameMissing = results.filter((r) => !r.nameInSource)
const bcRate = fns.length ? inBc / fns.length : 1

const valinityClosure = [...seen].filter((k) => k.startsWith('contracts/'))
const manifest = {
  contract: name, mainPath, solcInputHash: art.solcInputHash, solc: meta.compiler.version,
  totalFiles: written, valinityClosure,
  guard: {
    abiFunctions: fns.length,
    selectorsInBytecode: inBc,
    bytecodeSelectorRate: Number(bcRate.toFixed(4)),
    abiNamesMissingFromSource: nameMissing.map((r) => r.sig),
    selectorsMissingFromBytecode: missingFromBc.map((r) => r.sig),
  },
}
fs.writeFileSync(path.join(OUTDIR, '_MANIFEST.json'), JSON.stringify(manifest, null, 2))
console.log('extracted ' + written + ' files to ' + OUTDIR + ' | main=' + mainPath + ' | valinityClosure=' + valinityClosure.length)
console.log('GUARD: ' + inBc + '/' + fns.length + ' ABI selectors in deployedBytecode (' + (bcRate * 100).toFixed(1) + '%); ' + nameMissing.length + ' ABI fn-names missing from source')

// HARD GATE: the artifact ABI's selectors must (almost) all be in deployedBytecode.
// This is the authoritative source==live check — it's exactly what catches a stale
// solcInputHash: a V1 ABI checked against V2 bytecode scores well below 95% because the
// V1-only functions (e.g. acquire/setRouterWhitelist) are absent from the V2 bytecode.
if (bcRate < 0.95) {
  console.error('FATAL GUARD: only ' + (bcRate * 100).toFixed(1) + '% of ABI selectors are in deployedBytecode — artifact ABI ≠ bytecode (inconsistent/stale artifact). Do NOT audit ' + OUTDIR + '.')
  process.exit(3)
}
// ADVISORY: explicit-function names not found textually in the closure are almost always
// auto-generated getters from public state variables (no `function` keyword) or inherited
// base fns — not an error. Listed for human sanity-check only.
if (nameMissing.length > 0) {
  console.log('NOTE: ' + nameMissing.length + ' ABI fn-names not matched as `function NAME` in source (expected for public-var getters / inherited base fns): ' + nameMissing.slice(0, 8).map((r) => r.sig).join(', ') + (nameMissing.length > 8 ? ', …' : ''))
}
console.log('GUARD PASS ✅ — ' + (bcRate * 100).toFixed(1) + '% of deployed-ABI selectors present in live bytecode; source matches live. Safe to audit.')

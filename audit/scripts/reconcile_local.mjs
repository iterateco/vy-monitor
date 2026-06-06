#!/usr/bin/env node
// Step A — Local reconciliation (no RPC key).
// Compares the AS-DEPLOYED source (deployments/eth_mainnet/solcInputs/<hash>.json — the exact
// solc standard-json that produced the live bytecode) against the CURRENT workspace source.
//
// Key refinement: drift is measured ONLY over each contract's TRUE import closure (the Valinity
// `contracts/...` files actually reachable from the main file via imports), NOT the whole project
// bundle in the solc input. OZ/npm deps are version-pinned and excluded.
//
// Match classes (on main file): EXACT | COSMETIC | DRIFT | NO-WORKSPACE | NO-DEPLOYED-SRC
// audit-ready-local = main EXACT/COSMETIC AND every closure member EXACT/COSMETIC vs workspace.

import fs from 'node:fs'
import path from 'node:path'

const VAL = '/Users/sergiosolano/Valinity'
const DEPLOY = path.join(VAL, 'deployments/eth_mainnet')
const SI = path.join(DEPLOY, 'solcInputs')
const MANIFEST = path.join(VAL, '.openzeppelin/mainnet.json')
const OUT_JSON = '/Users/sergiosolano/vy-monitor/audit/reconciliation.json'
const OUT_MD = '/Users/sergiosolano/vy-monitor/audit/reconciliation.md'
const SUMMARY = '/Users/sergiosolano/vy-monitor/audit/_recon_summary.txt'

const normalize = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '').replace(/\s+/g, '')
const lineDiff = (deployed, ws) => {
  const A = deployed.split('\n').map((x) => x.trim()).filter(Boolean)
  const B = ws.split('\n').map((x) => x.trim()).filter(Boolean)
  const m = new Map()
  for (const l of B) m.set(l, (m.get(l) || 0) + 1)
  let onlyDeployed = 0
  for (const l of A) { const c = m.get(l) || 0; if (c === 0) onlyDeployed++; else m.set(l, c - 1) }
  let onlyWs = 0
  for (const c of m.values()) onlyWs += c
  return { onlyInDeployed: onlyDeployed, onlyInWorkspace: onlyWs }
}

// Resolve an import path against the importer's dir, normalizing ./ and ../
const resolveImport = (fromKey, spec) => {
  if (spec.startsWith('@') || (!spec.startsWith('.') )) return spec // absolute / remapped (e.g. @openzeppelin, contracts/..)
  const baseDir = path.posix.dirname(fromKey)
  return path.posix.normalize(path.posix.join(baseDir, spec))
}
const IMPORT_RE = /import\s+(?:[^"';]*?\bfrom\s+)?["']([^"']+)["']/g
const importsOf = (content) => {
  const out = []
  let m
  while ((m = IMPORT_RE.exec(content)) !== null) out.push(m[1])
  return out
}
// Reachable Valinity-owned (contracts/...) closure of `mainKey` within solc `sources`
const closureOf = (mainKey, sources) => {
  const seen = new Set()
  const stack = [mainKey]
  while (stack.length) {
    const k = stack.pop()
    if (seen.has(k)) continue
    seen.add(k)
    const src = sources[k]
    if (!src) continue
    for (const spec of importsOf(src.content)) {
      const r = resolveImport(k, spec)
      if (sources[r] && !seen.has(r)) stack.push(r)
    }
  }
  return [...seen].filter((k) => k.startsWith('contracts/')) // Valinity-owned only
}

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'))
const proxySet = new Set((manifest.proxies || []).map((p) => (p.address || '').toLowerCase()))
const inputCache = new Map()
const loadInput = (hash) => {
  if (!hash) return null
  if (inputCache.has(hash)) return inputCache.get(hash)
  const p = path.join(SI, hash + '.json')
  const v = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : null
  inputCache.set(hash, v)
  return v
}

const SKIP = new Set(['Admin.json'])
const artifacts = fs.readdirSync(DEPLOY).filter((f) => f.endsWith('.json') && !SKIP.has(f) && !f.endsWith('_ABI.json'))

const cmp = (deployedContent, wsPath) => {
  if (!fs.existsSync(wsPath)) return 'MISSING'
  const ws = fs.readFileSync(wsPath, 'utf8')
  if (ws === deployedContent) return 'EXACT'
  if (normalize(ws) === normalize(deployedContent)) return 'COSMETIC'
  return 'DRIFT'
}

const rows = []
for (const fname of artifacts) {
  let art
  try { art = JSON.parse(fs.readFileSync(path.join(DEPLOY, fname), 'utf8')) }
  catch (e) { rows.push({ artifact: fname.replace(/\.json$/, ''), status: 'PARSE-ERROR', error: String(e) }); continue }

  const address = art.address || null
  const isProxy = address ? proxySet.has(address.toLowerCase()) : false
  let mainPath = null, mainContract = null, solc = null
  if (art.metadata) {
    try { const m = JSON.parse(art.metadata); const ct = m.settings.compilationTarget; mainPath = Object.keys(ct)[0]; mainContract = ct[mainPath]; solc = m.compiler && m.compiler.version } catch {}
  }
  const input = loadInput(art.solcInputHash)
  const sources = (input && input.sources) || {}
  const asDeployedMain = mainPath && sources[mainPath] ? sources[mainPath].content : null

  let status = 'UNKNOWN', detail = {}
  let closure = [], closureDrift = [], closureMissing = []
  if (!art.solcInputHash || !input || !asDeployedMain) {
    status = 'NO-DEPLOYED-SRC'
    detail = { implPointer: art.implementation || null }
  } else {
    const wsMain = path.join(VAL, mainPath)
    status = cmp(asDeployedMain, wsMain)
    if (status === 'MISSING') status = 'NO-WORKSPACE'
    else if (status === 'DRIFT') detail = lineDiff(asDeployedMain, fs.readFileSync(wsMain, 'utf8'))
    // true import closure drift (exclude main)
    closure = closureOf(mainPath, sources).filter((k) => k !== mainPath)
    for (const k of closure) {
      const r = cmp(sources[k].content, path.join(VAL, k))
      if (r === 'MISSING') closureMissing.push(k)
      else if (r === 'DRIFT') closureDrift.push(k)
    }
  }

  rows.push({
    artifact: fname.replace(/\.json$/, ''), address, isProxy,
    mainPath, mainContract, solc, solcInputHash: art.solcInputHash || null,
    status, deployedBytecodeLen: (art.deployedBytecode || '').length, hasStorageLayout: !!art.storageLayout,
    closureSize: closure.length, closureDriftCount: closureDrift.length + closureMissing.length,
    closureDrift, closureMissing, ...detail,
  })
}

const order = { 'NO-DEPLOYED-SRC': 0, DRIFT: 1, 'NO-WORKSPACE': 2, 'PARSE-ERROR': 3, COSMETIC: 4, EXACT: 5, UNKNOWN: 6 }
rows.sort((a, b) => (order[a.status] ?? 9) - (order[b.status] ?? 9) || (b.closureDriftCount || 0) - (a.closureDriftCount || 0))

const ready = (r) => (r.status === 'EXACT' || r.status === 'COSMETIC') && (r.closureDriftCount || 0) === 0
fs.writeFileSync(OUT_JSON, JSON.stringify({
  generatedFrom: DEPLOY, manifestProxies: manifest.proxies?.length, manifestImpls: Object.keys(manifest.impls || {}).length,
  auditReadyLocal: rows.filter(ready).length, total: rows.length, rows,
}, null, 2))

const badge = (s) => ({ EXACT: '🟢 EXACT', COSMETIC: '🟡 COSMETIC', DRIFT: '🔴 DRIFT', 'NO-WORKSPACE': '⚠️ NO-WS', 'NO-DEPLOYED-SRC': '⚠️ NO-SRC', 'PARSE-ERROR': '❌ ERR' }[s] || s)
let md = `# Reconciliation Gate — Step A (local, no RPC)

Generated by \`audit/scripts/reconcile_local.mjs\`. Compares the **as-deployed source** (the exact solc standard-json in \`deployments/eth_mainnet/solcInputs/<hash>.json\` that produced the live bytecode) against the **current workspace source**. Drift is measured over each contract's **true import closure** (only Valinity \`contracts/...\` files actually reachable via imports; OZ/npm deps excluded).

- OZ manifest: **${manifest.proxies?.length} UUPS proxies**, **${Object.keys(manifest.impls || {}).length} implementation entries** (upgrade history).
- **Local audit-ready: ${rows.filter(ready).length}/${rows.length}** — main file + entire import closure EXACT/COSMETIC vs workspace. Step B (on-chain) then confirms live impl bytecode == artifact.
- ⚠️ Caveat: a hardhat-deploy artifact reflects the **last deploy it recorded**; if an upgrade was later done via the OZ plugin, the artifact (and this table) can lag the true on-chain impl. **Step B is required to certify "workspace == live".**

| Ready | Contract | Address | Type | Main file | Closure drift | solc |
|:--:|---|---|---|:--:|:--:|---|
`
for (const r of rows) {
  md += `| ${ready(r) ? '✅' : '❌'} | ${r.artifact} | \`${r.address || '—'}\` | ${r.isProxy ? 'UUPS' : 'standalone'} | ${badge(r.status)}${r.status === 'DRIFT' ? ` (+${r.onlyInWorkspace || 0}/−${r.onlyInDeployed || 0})` : ''} | ${r.closureDriftCount}/${r.closureSize} | ${(r.solc || '—').replace('+commit.', ' ')} |\n`
}
md += `\n## Legend
- 🟢 EXACT byte-identical · 🟡 COSMETIC normalized-equal (safe to audit local) · 🔴 DRIFT logic differs · ⚠️ NO-WS path moved/renamed · ⚠️ NO-SRC artifact has no recoverable source (proxy-pointer only → impl at \`implementation\` field / Etherscan).
- "Closure drift" = of the Valinity \`contracts/...\` files actually imported into this contract's bytecode, how many differ from workspace now (incl. moved/missing).

## How each bucket gets audited
- ✅ **Ready**: deep-audit from workspace source (post Step B bytecode confirm).
- 🔴 **DRIFT / ⚠️ NO-WS**: workspace has moved past the recorded deployment. Audit the **as-deployed source** recovered from \`solcInputs/<hash>.json\` (fully present locally) or Etherscan-verified source; the newer workspace version gets a separate pre-deploy review.
- ⚠️ **NO-SRC**: recover impl via Step B (impl slot) then pull source from the matching impl artifact / Etherscan.

## Next: Step B (on-chain, Alchemy, one-time)
Per UUPS proxy: read EIP-1967 impl slot (\`eth_getStorageAt 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc\`) + \`eth_getCode(impl)\`; mask metadata trailer + immutables; confirm live runtime == artifact \`deployedBytecode\`. Only **✅ ready + Step B-confirmed** rows are cleared for local-only deep audit.
`
fs.writeFileSync(OUT_MD, md)

const counts = {}
for (const r of rows) counts[r.status] = (counts[r.status] || 0) + 1
const summary = [
  'Reconciliation complete (import-closure aware).',
  'Main-file status counts: ' + JSON.stringify(counts),
  'Audit-ready local (main+closure clean): ' + rows.filter(ready).length + '/' + rows.length,
  '',
  'READY:',
  ...rows.filter(ready).map((r) => `  ${r.status}  ${r.artifact}  (${r.address})  closure ${r.closureDriftCount}/${r.closureSize}`),
  '',
  'NOT READY:',
  ...rows.filter((r) => !ready(r)).map((r) => `  ${r.status}  ${r.artifact}  main=${r.mainPath || '(none)'}  closureDrift=${r.closureDriftCount}/${r.closureSize}` + (r.closureDrift?.length ? `  drifted=[${r.closureDrift.join(', ')}]` : '') + (r.closureMissing?.length ? `  missing=[${r.closureMissing.join(', ')}]` : '')),
]
fs.writeFileSync(SUMMARY, summary.join('\n') + '\n')
console.log('done')

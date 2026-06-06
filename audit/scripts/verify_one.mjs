// Closed-circuit verification for a single contract:
//  Leg 1: workspace main source  == as-deployed main source (solcInputs)   [byte/sha256]
//  Leg 2: workspace import-closure == as-deployed closure                    [each file sha256]
//  Leg 3: artifact deployedBytecode == live runtime bytecode (metadata-masked) [on-chain]
// Pass contract name as argv[2]. Read-only RPC.
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { safeRpc, SLOTS, addrFromSlot, rpcHostMasked } from './rpc.mjs'

const VAL = '/Users/sergiosolano/Valinity'
const DEPLOY = path.join(VAL, 'deployments/eth_mainnet')
const SI = path.join(DEPLOY, 'solcInputs')
const name = process.argv[2]
if (!name) throw new Error('usage: node verify_one.mjs <ContractName>')

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex')
const stripMeta = (hex) => {
  if (!hex || hex === '0x') return ''
  let h = (hex.startsWith('0x') ? hex.slice(2) : hex).toLowerCase()
  if (h.length < 8) return h
  const metaLen = parseInt(h.slice(-4), 16)
  const cut = (metaLen + 2) * 2
  return cut > 0 && cut < h.length ? h.slice(0, h.length - cut) : h
}
const IMPORT_RE = /import\s+(?:[^"';]*?\bfrom\s+)?["']([^"']+)["']/g
const resolveImport = (fromKey, spec) => spec.startsWith('.') ? path.posix.normalize(path.posix.join(path.posix.dirname(fromKey), spec)) : spec
const closureOf = (mainKey, sources) => {
  const seen = new Set(), stack = [mainKey]
  while (stack.length) {
    const k = stack.pop(); if (seen.has(k)) continue; seen.add(k)
    const src = sources[k]; if (!src) continue
    let m; IMPORT_RE.lastIndex = 0
    while ((m = IMPORT_RE.exec(src.content)) !== null) { const r = resolveImport(k, m[1]); if (sources[r] && !seen.has(r)) stack.push(r) }
  }
  return [...seen].filter((k) => k.startsWith('contracts/'))
}

const art = JSON.parse(fs.readFileSync(path.join(DEPLOY, name + '.json'), 'utf8'))
const meta = JSON.parse(art.metadata)
const mainPath = Object.keys(meta.settings.compilationTarget)[0]
const input = JSON.parse(fs.readFileSync(path.join(SI, art.solcInputHash + '.json'), 'utf8'))
const sources = input.sources

const R = { name, address: art.address, solc: meta.compiler.version, mainPath, legs: {} }

// Leg 1: main source
const asDeployedMain = sources[mainPath].content
const wsMain = fs.readFileSync(path.join(VAL, mainPath), 'utf8')
R.legs.main = { match: wsMain === asDeployedMain, shaWorkspace: sha(wsMain).slice(0, 16), shaDeployed: sha(asDeployedMain).slice(0, 16), bytes: wsMain.length }

// Leg 2: closure
const closure = closureOf(mainPath, sources).filter((k) => k !== mainPath)
R.legs.closure = { files: [], allMatch: true }
for (const k of closure) {
  const wsP = path.join(VAL, k)
  const exists = fs.existsSync(wsP)
  const ok = exists && fs.readFileSync(wsP, 'utf8') === sources[k].content
  if (!ok) R.legs.closure.allMatch = false
  R.legs.closure.files.push({ file: k, match: ok, exists })
}

// Leg 3: bytecode (resolve impl if proxy)
const implWordA = await safeRpc('eth_getStorageAt', [art.address, SLOTS.impl, 'latest'])
const implWordB = await safeRpc('eth_getStorageAt', [art.address, SLOTS.impl, 'latest'])
if (implWordA !== implWordB) throw new Error('unstable impl slot')
const liveImpl = addrFromSlot(implWordA)
const codeAddr = liveImpl && liveImpl !== '0x0000000000000000000000000000000000000000' ? liveImpl : art.address
const liveRaw = await safeRpc('eth_getCode', [codeAddr, 'latest'])
const live = stripMeta(liveRaw)
const artBc = stripMeta(art.deployedBytecode || '')
// GUARD: empty/zero live code is never a pass (caught the VYT false-positive: transient RPC -> 0 bytes)
const liveEmpty = !liveRaw || liveRaw === '0x' || live.length === 0
let byteDiff = -1
if (!liveEmpty && live.length === artBc.length) { byteDiff = 0; for (let i = 0; i < live.length; i += 2) if (live.slice(i, i + 2) !== artBc.slice(i, i + 2)) byteDiff++ }
R.legs.bytecode = { liveImpl: codeAddr === art.address ? '(non-proxy, code at address)' : liveImpl, liveEmpty, exact: !liveEmpty && live === artBc, byteDiffOutsideMeta: byteDiff, liveBytes: live.length / 2, artifactBytes: artBc.length / 2, rpcHost: rpcHostMasked() }

// NOTE: matching the ARTIFACT bytecode only proves artifact==live, NOT source==live (artifacts can be
// source/bytecode-inconsistent — see VAL-002). A true source match also needs selector_gate.mjs (or a
// solc recompile of the source) to confirm the repo source's functions are the live ones.
R.verdict = liveEmpty
  ? 'INDETERMINATE — live code came back empty (RPC issue); re-run'
  : (R.legs.main.match && R.legs.closure.allMatch && (R.legs.bytecode.exact || R.legs.bytecode.byteDiffOutsideMeta === 0) && R.legs.bytecode.liveBytes > 0)
  ? 'ARTIFACT-MATCH (live==artifact bytecode, source==artifact source) — confirm source==live via selector_gate'
  : (R.legs.main.match && R.legs.closure.allMatch && R.legs.bytecode.byteDiffOutsideMeta > 0)
  ? 'SOURCE==ARTIFACT; live differs by ' + R.legs.bytecode.byteDiffOutsideMeta + ' bytes (immutables?) — confirm via selector_gate'
  : 'NOT FULLY MATCHED — see legs'

fs.writeFileSync('/Users/sergiosolano/vy-monitor/audit/_verify_' + name + '.json', JSON.stringify(R, null, 2))
console.log(R.verdict)

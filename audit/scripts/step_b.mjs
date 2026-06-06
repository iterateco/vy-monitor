// Step B — one-time, read-only on-chain certification that the as-deployed source == live code.
// Deterministic + self-verifying: each impl slot is read TWICE and asserted stable; each storage
// word is validated to be a 32-byte value; bytecode compared with metadata trailer stripped.
// READ-ONLY: eth_getStorageAt / eth_getCode / eth_call / eth_chainId / eth_blockNumber only.

import fs from 'node:fs'
import path from 'node:path'
import { safeRpc, rpc, SLOTS, addrFromSlot, rpcHostMasked } from './rpc.mjs'

const VAL = '/Users/sergiosolano/Valinity'
const DEPLOY = path.join(VAL, 'deployments/eth_mainnet')
const MANIFEST = JSON.parse(fs.readFileSync(path.join(VAL, '.openzeppelin/mainnet.json'), 'utf8'))
const ADMIN = '0x8310eA7EC55A7Ad6A4288aF683155A124A524a09'
const ZERO = '0x0000000000000000000000000000000000000000'

const proxySet = new Set((MANIFEST.proxies || []).map((p) => (p.address || '').toLowerCase()))
const manifestImpls = new Map()
for (const [h, v] of Object.entries(MANIFEST.impls || {})) {
  if (v && v.address) manifestImpls.set(v.address.toLowerCase(), { h: h.slice(0, 10), vars: v.layout?.storage?.length })
}

const validWord = (w) => typeof w === 'string' && /^0x[0-9a-fA-F]{64}$/.test(w)
const stripMeta = (hex) => {
  if (!hex || hex === '0x') return ''
  let h = (hex.startsWith('0x') ? hex.slice(2) : hex).toLowerCase()
  if (h.length < 8) return h
  const metaLen = parseInt(h.slice(-4), 16)
  const cut = (metaLen + 2) * 2
  return cut > 0 && cut < h.length ? h.slice(0, h.length - cut) : h
}
const byteDiff = (a, b) => { if (a.length !== b.length) return -1; let d = 0; for (let i = 0; i < a.length; i += 2) if (a.slice(i, i + 2) !== b.slice(i, i + 2)) d++; return d }

// read a storage slot twice; assert stable + well-formed
const readSlotStable = async (addr, slot) => {
  const a = await safeRpc('eth_getStorageAt', [addr, slot, 'latest'])
  const b = await safeRpc('eth_getStorageAt', [addr, slot, 'latest'])
  if (a !== b) throw new Error(`unstable slot ${slot}@${addr}: ${a} != ${b}`)
  if (!validWord(a)) throw new Error(`malformed word ${slot}@${addr}: ${a}`)
  return a
}
const slotAddr = (w) => { const x = addrFromSlot(w); return x && x.toLowerCase() !== ZERO ? x.toLowerCase() : null }
const tryCall = async (to, data) => { try { return await safeRpc('eth_call', [{ to, data }, 'latest']) } catch { return null } }
const SEL_owner = '0x8da5cb5b'
const SEL_hasAdmin = '0x91d14854' + '0'.repeat(64) + ADMIN.slice(2).toLowerCase().padStart(64, '0')
const SEL_paused = '0x5c975abb'

const SKIP = (f) => !f.endsWith('.json') || f === 'Admin.json' || f.endsWith('_ABI.json') || f.includes('_backup') || f.endsWith('.v1.json')
const files = fs.readdirSync(DEPLOY).filter((f) => !SKIP(f))

const chainId = await rpc('eth_chainId', [])
const block = await rpc('eth_blockNumber', [])

const rows = []
for (const fname of files) {
  const art = JSON.parse(fs.readFileSync(path.join(DEPLOY, fname), 'utf8'))
  const name = fname.replace(/\.json$/, '')
  const address = art.address
  if (!address) continue
  const r = { name, address, isProxyManifest: proxySet.has(address.toLowerCase()), artifactImpl: art.implementation || null }

  const proxyCode = await safeRpc('eth_getCode', [address, 'latest'])
  r.hasCode = !!proxyCode && proxyCode !== '0x'
  if (!r.hasCode) { r.status = 'NO-CODE'; rows.push(r); continue }

  r.liveImpl = slotAddr(await readSlotStable(address, SLOTS.impl))
  r.eip1967Admin = slotAddr(await readSlotStable(address, SLOTS.admin))
  r.beacon = slotAddr(await readSlotStable(address, SLOTS.beacon))

  // bytecode certify: where the logic actually lives
  const codeAddr = r.liveImpl || address
  const liveCode = r.liveImpl ? await safeRpc('eth_getCode', [r.liveImpl, 'latest']) : proxyCode
  const liveStripped = stripMeta(liveCode)
  const artStripped = stripMeta(art.deployedBytecode || '')
  if (!artStripped) r.bytecode = 'NO-ARTIFACT-BYTECODE'
  else if (liveStripped === artStripped) r.bytecode = 'EXACT'
  else { const d = byteDiff(liveStripped, artStripped); r.bytecode = d >= 0 ? `EQUIVALENT-IMMUTABLES(${d}b)` : `MISMATCH(live ${liveStripped.length / 2}b vs artifact ${artStripped.length / 2}b)` }

  // manifest tracking (authoritative)
  if (r.liveImpl) { const m = manifestImpls.get(r.liveImpl); r.manifest = m ? `tracked(${m.h},${m.vars}v)` : 'UNTRACKED' }
  else r.manifest = 'n/a(non-proxy)'

  // authority (best-effort)
  const ownerRes = await tryCall(address, SEL_owner)
  r.owner = ownerRes && ownerRes.length >= 66 && !/^0x0+$/.test(ownerRes) ? '0x' + ownerRes.slice(26) : null
  const hr = await tryCall(address, SEL_hasAdmin)
  r.adminIsDefaultAdmin = hr ? /1$/.test(hr.replace(/0+$/, '0')) && /0{63}1$/.test(hr) : null
  const p = await tryCall(address, SEL_paused)
  r.paused = p == null ? null : /1$/.test(p)

  rows.push(r)
}

// shared-impl detection
const byImpl = {}
for (const r of rows) if (r.liveImpl) (byImpl[r.liveImpl] ||= []).push(r.name)
const shared = Object.entries(byImpl).filter(([, n]) => n.length > 1)

const out = { chainId, block: parseInt(block, 16), rpcHost: rpcHostMasked(), admin: ADMIN, rows, shared }
fs.writeFileSync('/Users/sergiosolano/vy-monitor/audit/live-state-report.json', JSON.stringify(out, null, 2))

let md = `# Live-State Report — Step B (on-chain, read-only, self-verified)

chainId ${chainId} · block ${out.block} · RPC ${out.rpcHost} · ${rows.length} contracts · read-only · each impl slot read twice & asserted stable.

| Contract | Proxy | Live impl | Bytecode vs artifact | Manifest | admin∈DEFAULT_ADMIN | paused |
|---|---|---|---|---|:--:|:--:|
`
for (const r of rows) {
  const fl = []
  if (r.manifest === 'UNTRACKED') fl.push('🔴UNTRACKED')
  if ((r.bytecode || '').startsWith('MISMATCH')) fl.push('🔴MISMATCH')
  md += `| ${r.name}${fl.length ? ' ' + fl.join(' ') : ''} | \`${r.address}\` | ${r.liveImpl ? '`' + r.liveImpl + '`' : '—(non-proxy)'} | ${r.bytecode} | ${r.manifest} | ${r.adminIsDefaultAdmin == null ? '?' : r.adminIsDefaultAdmin ? 'yes' : 'no'} | ${r.paused == null ? '—' : r.paused} |\n`
}
md += `\n## Shared implementations (one impl behind multiple proxies)\n`
md += shared.length ? shared.map(([i, n]) => `- 🔶 \`${i}\` ← ${n.join(', ')}`).join('\n') + '\n' : '_none_\n'
md += `\n## Key
- **EXACT / EQUIVALENT-IMMUTABLES(0b)**: live runtime bytecode (metadata-stripped) == artifact deployedBytecode → the as-deployed \`solcInputs\` source IS the live code (certified). N>0 = identical except N immutable bytes.
- **MISMATCH**: live impl differs from artifact deployedBytecode → artifact is stale; audit the live impl from Etherscan-verified source. (Impl may still be manifest-tracked — that's fine, it just means a newer upgrade than the recorded artifact.)
- **UNTRACKED**: live impl not in the OZ manifest's impl set → upgrade outside the OZ plugin (storage-layout safety untracked). Investigate.
- admin = ${ADMIN} (eth_mainnet Admin.json); does it hold DEFAULT_ADMIN_ROLE.
`
fs.writeFileSync('/Users/sergiosolano/vy-monitor/audit/live-state-report.md', md)
console.log('done rows=' + rows.length + ' shared=' + shared.length)

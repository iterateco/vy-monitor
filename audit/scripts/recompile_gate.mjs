// DEFINITIVE source==live gate. Recompile the artifact's exact solcInputs standard-json with the
// pinned solc-js (0.8.27, from Valinity/node_modules), then compare the produced deployedBytecode
// to the LIVE runtime, masking the CBOR metadata trailer AND the compiler-reported immutable ranges.
// This bypasses the (sometimes unreliable) artifact.deployedBytecode entirely.
//
// usage: node recompile_gate.mjs <ContractName> <proxyOrAddress>
import { createRequire } from 'node:module'
import { createPublicClient, http } from 'viem'
import { mainnet } from 'viem/chains'
import fs from 'node:fs'
import path from 'node:path'
import { resolveRpcUrl } from './rpc.mjs'

const require = createRequire('/Users/sergiosolano/Valinity/')
const solc = require('solc')
const VAL = '/Users/sergiosolano/Valinity'
const DEPLOY = path.join(VAL, 'deployments/eth_mainnet')
const SI = path.join(DEPLOY, 'solcInputs')
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
const name = process.argv[2]
const addr = process.argv[3]
const client = createPublicClient({ chain: mainnet, transport: http(resolveRpcUrl()) })

const stripMeta = (h) => { h = (h.startsWith('0x') ? h.slice(2) : h).toLowerCase(); if (h.length < 8) return h; const n = parseInt(h.slice(-4), 16); const cut = (n + 2) * 2; return cut > 0 && cut < h.length ? h.slice(0, h.length - cut) : h }
const maskImmutables = (hex, refs) => {
  if (!refs) return hex
  const buf = Buffer.from(hex, 'hex')
  for (const k of Object.keys(refs)) for (const { start, length } of refs[k]) if (start + length <= buf.length) buf.fill(0, start, start + length)
  return buf.toString('hex')
}

const art = JSON.parse(fs.readFileSync(path.join(DEPLOY, name + '.json'), 'utf8'))
const meta = JSON.parse(art.metadata)
const mainPath = Object.keys(meta.settings.compilationTarget)[0]
const contractName = meta.settings.compilationTarget[mainPath]
const input = JSON.parse(fs.readFileSync(path.join(SI, art.solcInputHash + '.json'), 'utf8'))
input.settings = input.settings || {}
input.settings.outputSelection = { '*': { '*': ['evm.deployedBytecode.object', 'evm.deployedBytecode.immutableReferences'] } }

const compiled = JSON.parse(solc.compile(JSON.stringify(input)))
const errs = (compiled.errors || []).filter((e) => e.severity === 'error')
const out = { name, addr, mainPath, contractName, solc: solc.version(), compileErrors: errs.map((e) => (e.formattedMessage || e.message || '').slice(0, 200)) }
if (errs.length) { fs.writeFileSync('/Users/sergiosolano/vy-monitor/audit/_recompile_' + name + '.json', JSON.stringify(out, null, 2)); console.log('COMPILE-ERROR ' + errs.length); process.exit(0) }

const cc = compiled.contracts[mainPath][contractName]
const compiledDbc = (cc.evm.deployedBytecode.object || '').toLowerCase()
const immRefs = cc.evm.deployedBytecode.immutableReferences || {}

let codeAddr = addr
const w = await client.request({ method: 'eth_getStorageAt', params: [addr, IMPL_SLOT, 'latest'] })
const impl = w && w !== '0x' + '0'.repeat(64) ? '0x' + w.slice(26) : null
if (impl) codeAddr = impl
const liveRaw = (await client.request({ method: 'eth_getCode', params: [codeAddr, 'latest'] })).slice(2).toLowerCase()

const c = stripMeta(compiledDbc)
const l = stripMeta(liveRaw)
const cM = maskImmutables(c, immRefs)
const lM = l.length === c.length ? maskImmutables(l, immRefs) : l

out.liveImpl = impl
out.compiledBytes = c.length / 2
out.liveBytes = l.length / 2
out.immutableSlots = Object.values(immRefs).flat().map((r) => r.start + ':' + r.length)
out.sameLength = c.length === l.length
out.compiled_eq_live_maskedImmutables = cM === lM
// residual non-immutable diff after masking (should be 0)
let residual = 0
if (cM.length === lM.length) for (let i = 0; i < cM.length; i += 2) if (cM.slice(i, i + 2) !== lM.slice(i, i + 2)) residual++
out.residualDiffBytesAfterMask = cM.length === lM.length ? residual : -1
out.verdict = out.compiled_eq_live_maskedImmutables
  ? 'SOURCE==LIVE ✅ — recompiled workspace source matches live runtime (metadata+immutables masked)'
  : (out.sameLength ? 'MISMATCH — same length but ' + residual + ' non-immutable bytes differ' : 'MISMATCH — different length (compiled ' + out.compiledBytes + ' vs live ' + out.liveBytes + ')')
fs.writeFileSync('/Users/sergiosolano/vy-monitor/audit/_recompile_' + name + '.json', JSON.stringify(out, null, 2))
console.log(out.verdict)

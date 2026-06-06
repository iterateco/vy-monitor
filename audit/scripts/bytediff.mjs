// Definitive source==live check: compare artifact deployedBytecode to live runtime bytecode.
// Masks the CBOR metadata trailer and reports exact diff clusters; flags whether the only
// diffs are 20-byte immutables equal to the resolved code (impl) address.
// usage: node bytediff.mjs <ContractName> [implAddressOverride]
import fs from 'node:fs'
import path from 'node:path'
import { safeRpc as rpc, SLOTS, addrFromSlot } from './rpc.mjs'

const VAL = '/Users/sergiosolano/Valinity'
const DEPLOY = path.join(VAL, 'deployments/eth_mainnet')
const name = process.argv[2]
const override = process.argv[3]

const art = JSON.parse(fs.readFileSync(path.join(DEPLOY, name + '.json'), 'utf8'))
const proxyAddr = art.address
if (!proxyAddr) throw new Error('artifact has no .address')

// Resolve the address whose runtime code we compare against. If the artifact address is a
// UUPS/1967 proxy, follow the impl slot; else the artifact address itself holds the code.
let codeAddr = proxyAddr
if (override) {
  codeAddr = override
} else {
  const implSlot = await rpc('eth_getStorageAt', [proxyAddr, SLOTS.impl, 'latest'])
  const implFromSlot = addrFromSlot(implSlot)
  if (implFromSlot && implFromSlot !== '0x0000000000000000000000000000000000000000') {
    codeAddr = implFromSlot
  }
}
console.log('proxy/artifact addr:', proxyAddr, '| code addr:', codeAddr)

const liveCode = await rpc('eth_getCode', [codeAddr, 'latest'])
if (!liveCode || liveCode === '0x') throw new Error('INDETERMINATE: live code empty at ' + codeAddr)
const artCode = art.deployedBytecode

// strip CBOR metadata trailer (last 2 bytes = big-endian length of the trailer) from both
function stripMeta(hex) {
  const b = Buffer.from(hex.slice(2), 'hex')
  if (b.length < 2) return hex
  const mlen = b[b.length - 2] * 256 + b[b.length - 1]
  if (mlen + 2 <= b.length) return '0x' + b.slice(0, b.length - 2 - mlen).toString('hex')
  return hex
}

const aBuf = Buffer.from(stripMeta(artCode).slice(2), 'hex')
const lBuf = Buffer.from(stripMeta(liveCode).slice(2), 'hex')

// find diff clusters
const diffs = []
const maxLen = Math.max(aBuf.length, lBuf.length)
let inDiff = false, start = 0
for (let i = 0; i < maxLen; i++) {
  if (aBuf[i] !== lBuf[i]) {
    if (!inDiff) { inDiff = true; start = i }
  } else {
    if (inDiff) { inDiff = false; diffs.push([start, i - start]) }
  }
}
if (inDiff) diffs.push([start, maxLen - start])

console.log('artifact bytes (meta-stripped):', aBuf.length, '| live bytes:', lBuf.length)
console.log('diff clusters [offset,len]:', JSON.stringify(diffs), '| count:', diffs.length)

// Are all diffs exactly the 20-byte code(impl) address? (UUPS __self immutable etc.)
const implBytes = Buffer.from(codeAddr.slice(2).padStart(40, '0'), 'hex')
let allImmAddr = diffs.length > 0 && aBuf.length === lBuf.length
for (const [off, len] of diffs) {
  // live value at the cluster should equal the impl address (right-aligned in a 32-byte word
  // or as a bare 20-byte push). Compare the 20-byte live slice to the impl address.
  const liveChunk = lBuf.slice(off, off + len)
  const isAddr = len === 20 && Buffer.compare(liveChunk, implBytes) === 0
  if (!isAddr) { allImmAddr = false }
  console.log(`  cluster @${off} len ${len}: live=0x${liveChunk.toString('hex')} ${len === 20 ? (Buffer.compare(liveChunk, implBytes) === 0 ? '== implAddr ✅' : '!= implAddr') : '(not 20B)'}`)
}

const verdict = diffs.length === 0
  ? 'BYTE-EXACT (no diffs) ✅'
  : (allImmAddr ? 'MATCH: only diffs are impl-address immutables ✅' : 'DIFFERS: non-immutable diffs present ❌')
console.log('VERDICT:', verdict)
console.log(JSON.stringify({ name, proxyAddr, codeAddr, artBytes: aBuf.length, liveBytes: lBuf.length, diffClusters: diffs, allImmAddr, verdict }))

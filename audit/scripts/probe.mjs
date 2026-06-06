#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'

const VAL = '/Users/sergiosolano/Valinity'
const DEPLOY = path.join(VAL, 'deployments/eth_mainnet')
const out = []

// 1. One artifact's top-level shape
const f = path.join(DEPLOY, 'ValinityToken.json')
const art = JSON.parse(fs.readFileSync(f, 'utf8'))
out.push('=== ValinityToken.json top-level keys ===')
out.push(Object.keys(art).join(', '))
out.push('address: ' + art.address)
out.push('implementation: ' + (art.implementation ?? 'NONE'))
out.push('solcInputHash: ' + (art.solcInputHash ?? 'NONE'))
out.push('has .solcInput: ' + !!art.solcInput)
out.push('has .metadata: ' + !!art.metadata + ' (type ' + typeof art.metadata + ')')
out.push('deployedBytecode len: ' + (art.deployedBytecode || '').length)
if (art.metadata) {
  try {
    const m = JSON.parse(art.metadata)
    out.push('metadata.compilationTarget: ' + JSON.stringify(m.settings?.compilationTarget))
    out.push('metadata.compiler: ' + (m.compiler?.version))
    out.push('metadata.sources keys (count): ' + Object.keys(m.sources || {}).length)
    out.push('metadata.sources sample: ' + Object.keys(m.sources || {}).slice(0, 5).join(' | '))
  } catch (e) { out.push('metadata parse err: ' + e.message) }
}

// 2. solcInputs dir + a sample input's shape
const SI = path.join(DEPLOY, 'solcInputs')
if (fs.existsSync(SI)) {
  const files = fs.readdirSync(SI)
  out.push('\n=== solcInputs/ has ' + files.length + ' files ===')
  const sample = JSON.parse(fs.readFileSync(path.join(SI, files[0]), 'utf8'))
  out.push('sample input top keys: ' + Object.keys(sample).join(', '))
  out.push('sample input .sources count: ' + Object.keys(sample.sources || {}).length)
  out.push('sample input .sources first 3: ' + Object.keys(sample.sources || {}).slice(0, 3).join(' | '))
  const k0 = Object.keys(sample.sources || {})[0]
  out.push('source entry keys: ' + Object.keys(sample.sources[k0] || {}).join(', '))
}

// 3. Every artifact: address, solcInputHash, metadata compilationTarget
out.push('\n=== all artifacts: name | address | solcInputHash | compilationTarget ===')
for (const fn of fs.readdirSync(DEPLOY)) {
  if (!fn.endsWith('.json') || fn === 'Admin.json' || fn.endsWith('_ABI.json')) continue
  try {
    const a = JSON.parse(fs.readFileSync(path.join(DEPLOY, fn), 'utf8'))
    let ct = '?'
    try { ct = Object.keys(JSON.parse(a.metadata).settings.compilationTarget)[0] } catch {}
    out.push([fn.replace('.json', ''), a.address || '—', (a.solcInputHash || '—').slice(0, 10), ct].join('  |  '))
  } catch (e) { out.push(fn + '  PARSE-ERR ' + e.message) }
}

// 4. OZ manifest shape
const M = path.join(VAL, '.openzeppelin/mainnet.json')
const man = JSON.parse(fs.readFileSync(M, 'utf8'))
out.push('\n=== OZ mainnet.json ===')
out.push('top keys: ' + Object.keys(man).join(', '))
out.push('manifestVersion: ' + man.manifestVersion)
out.push('proxies: ' + (man.proxies || []).length)
for (const p of man.proxies || []) out.push('  proxy ' + p.address + '  kind=' + p.kind)
out.push('impls (count): ' + Object.keys(man.impls || {}).length)
const implEntries = Object.entries(man.impls || {})
for (const [h, v] of implEntries) {
  out.push('  impl ' + h.slice(0, 10) + '  addr=' + (v.address) + '  layout=' + (v.layout ? 'yes(' + (v.layout.storage?.length ?? '?') + ')' : 'no') + '  txHash=' + (v.txHash || '—'))
}

fs.writeFileSync('/tmp/probe_out.txt', out.join('\n'))
console.log('wrote /tmp/probe_out.txt (' + out.length + ' lines)')

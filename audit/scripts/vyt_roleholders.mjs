// Enumerate current role holders on VYT and VCO by replaying RoleGranted/RoleRevoked logs.
// Plain AccessControl isn't enumerable, so reconstruct from events. Read-only.
import { keccak256, toBytes } from 'viem'
import { safeRpc } from './rpc.mjs'

const VYT = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974'
const VCO = '0x14122c206E0d1b8B9d54DF9619F0C1a08fe1Ca92'
const GRANTED = keccak256(toBytes('RoleGranted(bytes32,address,address)'))
const REVOKED = keccak256(toBytes('RoleRevoked(bytes32,address,address)'))
const roles = {
  DEFAULT_ADMIN_ROLE: '0x' + '0'.repeat(64),
  ADMIN_ROLE: keccak256(toBytes('ADMIN_ROLE')),
  OFFICER_ROLE: keccak256(toBytes('OFFICER_ROLE')),
  PRIORITY_OFFICER_ROLE: keccak256(toBytes('PRIORITY_OFFICER_ROLE')),
}
const roleName = (h) => Object.entries(roles).find(([, v]) => v.toLowerCase() === h.toLowerCase())?.[0] || h
const topicAddr = (t) => '0x' + t.slice(26)

async function getAllLogs(addr) {
  const latest = parseInt(await safeRpc('eth_blockNumber', []), 16)
  // Try ever-larger single windows ending at latest; Alchemy caps response size not range.
  let logs = []
  let from = 20000000 // Valinity is a 2024+ deploy; start mid-2024
  const STEP = 500000
  for (let lo = from; lo <= latest; lo += STEP) {
    const hi = Math.min(lo + STEP - 1, latest)
    try {
      const part = await safeRpc('eth_getLogs', [{ address: addr, topics: [[GRANTED, REVOKED]], fromBlock: '0x' + lo.toString(16), toBlock: '0x' + hi.toString(16) }])
      logs = logs.concat(part)
    } catch (e) { /* skip window */ }
  }
  return logs
}

async function holders(addr, label) {
  const events = await getAllLogs(addr)
  const mem = {}
  for (const l of events) {
    const isGrant = l.topics[0].toLowerCase() === GRANTED.toLowerCase()
    const r = l.topics[1], acct = topicAddr(l.topics[2])
    mem[r] = mem[r] || new Set()
    if (isGrant) mem[r].add(acct); else mem[r].delete(acct)
  }
  const result = { label, addr, eventCount: events.length, roles: {} }
  for (const [r, set] of Object.entries(mem)) {
    if (set.size) result.roles[roleName(r)] = [...set]
  }
  return result
}

const vyt = await holders(VYT, 'VYT')
const vco = await holders(VCO, 'VCO')
import fs from 'node:fs'
fs.writeFileSync('/tmp/vyt_roles.json', JSON.stringify({ vyt, vco }, null, 2))
console.log(JSON.stringify({ vyt, vco }, null, 2))

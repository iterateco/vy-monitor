// VAO V2 live on-chain state (read-only). Confirms the V2 wiring (dax/vryo/vgo/execPaused/
// slippage), the fee sink, roles on VYT/VCO, and the admin. Never prints secrets.
import { keccak256, toBytes } from 'viem'
import { safeRpc } from './rpc.mjs'

const VAO = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01'
const VYT = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974'
const VCO = '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C' // VAO.vco() read earlier

const sel = (sig) => keccak256(toBytes(sig)).slice(0, 10)
async function addr(to, sig) { const r = await safeRpc('eth_call', [{ to, data: sel(sig) }, 'latest']); return r && r.length >= 66 ? '0x' + r.slice(26) : r }
async function uint(to, sig) { const r = await safeRpc('eth_call', [{ to, data: sel(sig) }, 'latest']); return r && r !== '0x' ? BigInt(r).toString() : 'revert' }
async function boolv(to, sig) { const r = await safeRpc('eth_call', [{ to, data: sel(sig) }, 'latest']); return r && r !== '0x' ? (BigInt(r) === 1n) : 'revert' }
async function hasRole(to, roleName, acct) {
  const role = roleName === 'DEFAULT_ADMIN_ROLE' ? '0x' + '0'.repeat(64) : keccak256(toBytes(roleName))
  const data = '0x91d14854' + role.slice(2) + acct.slice(2).padStart(64, '0').toLowerCase()
  const r = await safeRpc('eth_call', [{ to, data }, 'latest']); return r && r !== '0x' ? BigInt(r) === 1n : 'revert'
}

const o = {}
o.dax = await addr(VAO, 'dax()')
o.vryo = await addr(VAO, 'vryo()')
o.vgo = await addr(VAO, 'vgo()')
o.feeRecipient_BBO = await addr(VAO, 'feeRecipient()')
o.vrt = await addr(VAO, 'vrt()')
o.vco = await addr(VAO, 'vco()')
o.vyt = await addr(VAO, 'vyt()')
o.vyToken = await addr(VAO, 'vyToken()')
o.execPaused = await boolv(VAO, 'execPaused()')
o.swapSlippageBps = await uint(VAO, 'swapSlippageBps()')
o.priceDisparityFeeBps = await uint(VAO, 'priceDisparityFeeBps()')
o.ltvDisparityFeeBps = await uint(VAO, 'ltvDisparityFeeBps()')
o.priceDisparityCooldown = await uint(VAO, 'priceDisparityCooldown()')
o.ltvDisparityCooldown = await uint(VAO, 'ltvDisparityCooldown()')
o.lastPriceDisparityTrigger = await uint(VAO, 'lastPriceDisparityTrigger()')
o.lastLTVDisparityTrigger = await uint(VAO, 'lastLTVDisparityTrigger()')

const ADMIN = '0x8310ea7ec55a7ad6a4288af683155a124a524a09'
o.adminHasDEFAULT_ADMIN_onVAO = await hasRole(VAO, 'DEFAULT_ADMIN_ROLE', ADMIN)
o.adminHasADMIN_onVAO = await hasRole(VAO, 'ADMIN_ROLE', ADMIN)
o.vaoIsPRIORITY_OFFICER_onVYT = await hasRole(VYT, 'PRIORITY_OFFICER_ROLE', VAO)
o.vaoIsOFFICER_onVYT = await hasRole(VYT, 'OFFICER_ROLE', VAO)
o.vaoIsOFFICER_onVCO = await hasRole(VCO, 'OFFICER_ROLE', VAO)

import fs from 'node:fs'
fs.writeFileSync('/tmp/vao_v2_state.json', JSON.stringify(o, null, 2))
console.log(JSON.stringify(o, null, 2))

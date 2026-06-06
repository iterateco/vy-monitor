// Read VAO live on-chain state (read-only). Confirms config that becomes permanent at handoff
// and confirms VAO's role on VYT. Never prints secrets.
import { keccak256, toBytes, encodeFunctionData, decodeAbiParameters, parseAbiParameters } from 'viem'
import { safeRpc } from './rpc.mjs'

const VAO = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01'
const VYT = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974'

const sel = (sig) => keccak256(toBytes(sig)).slice(0, 10)
async function callAddr(to, sig) {
  const data = sel(sig)
  const r = await safeRpc('eth_call', [{ to, data }, 'latest'])
  return r && r.length >= 66 ? '0x' + r.slice(26) : r
}
async function callUint(to, sig) {
  const data = sel(sig)
  const r = await safeRpc('eth_call', [{ to, data }, 'latest'])
  return BigInt(r)
}
// role membership: hasRole(bytes32,address) selector + args
async function hasRole(to, roleHash, account) {
  const data = '0x91d14854' + roleHash.slice(2) + account.slice(2).padStart(64, '0')
  const r = await safeRpc('eth_call', [{ to, data }, 'latest'])
  return BigInt(r) === 1n
}
const role = (name) => name === 'DEFAULT_ADMIN_ROLE' ? '0x' + '0'.repeat(64) : keccak256(toBytes(name))

const out = {}
out.feeRecipient = await callAddr(VAO, 'feeRecipient()')
out.usdcAddress = await callAddr(VAO, 'usdcAddress()')
out.wethAddress = await callAddr(VAO, 'wethAddress()')
out.vco = await callAddr(VAO, 'vco()')
out.vrt = await callAddr(VAO, 'vrt()')
out.vyt = await callAddr(VAO, 'vyt()')
out.vyToken = await callAddr(VAO, 'vyToken()')
out.vyUsdcV2Pair = await callAddr(VAO, 'vyUsdcV2Pair()')
out.poolCapBps = (await callUint(VAO, 'poolCapBps()')).toString()
out.priceDisparityFeeBps = (await callUint(VAO, 'priceDisparityFeeBps()')).toString()
out.ltvDisparityFeeBps = (await callUint(VAO, 'ltvDisparityFeeBps()')).toString()
out.priceDisparityCooldown = (await callUint(VAO, 'priceDisparityCooldown()')).toString()
out.ltvDisparityCooldown = (await callUint(VAO, 'ltvDisparityCooldown()')).toString()

// VAO's own admin (the handoff variable). Known admin from VYT audit:
const ADMIN = '0x8310eA7E0e2bC6Eb6f2cC39698D3fbE7Be2D4a09'
out.adminHasDEFAULT_ADMIN = await hasRole(VAO, role('DEFAULT_ADMIN_ROLE'), ADMIN)
out.adminHasADMIN_ROLE = await hasRole(VAO, role('ADMIN_ROLE'), ADMIN)

// Does VAO hold PRIORITY_OFFICER_ROLE (and/or OFFICER_ROLE) on VYT?
out.vaoIsPRIORITY_OFFICER_onVYT = await hasRole(VYT, role('PRIORITY_OFFICER_ROLE'), VAO)
out.vaoIsOFFICER_onVYT = await hasRole(VYT, role('OFFICER_ROLE'), VAO)

// Is VAO the OFFICER on VCO (so it can call increaseAssetCap)?
out.vaoIsOFFICER_onVCO = await hasRole(out.vco, role('OFFICER_ROLE'), VAO)

console.log(JSON.stringify(out, null, 2))

// RPC resolver + minimal read-only JSON-RPC client. Resolves the Alchemy URL from the
// existing repo mechanism (env RPC_URL, else the fallback literal in verify-health.mjs)
// WITHOUT ever printing the secret.
import fs from 'node:fs'

// Resolve the mainnet RPC URL from the repo's existing "default profile" (Valinity/secrets.ts
// eth_mainnet.rpc_url — the Alchemy endpoint with the key), without ever printing the secret.
// Order: env override -> secrets.ts eth_mainnet -> keyless api.valinity.io proxy used by vy-monitor.
export function resolveRpcUrl() {
  if (process.env.RPC_URL) return process.env.RPC_URL
  if (process.env.ALCHEMY_MAINNET_URL) return process.env.ALCHEMY_MAINNET_URL
  // Parse the eth_mainnet block of secrets.ts and take its rpc_url literal.
  try {
    const s = fs.readFileSync('/Users/sergiosolano/Valinity/secrets.ts', 'utf8')
    const blk = s.slice(s.indexOf('eth_mainnet'))
    const m = blk.match(/rpc_url\s*:\s*["'`]([^"'`]+)["'`]/)
    if (m && /^https?:\/\//.test(m[1])) return m[1]
  } catch {}
  // Fallback: the keyless proxy the vy-monitor scripts already use.
  return 'https://api.valinity.io/rpc-proxy'
}

export function rpcHostMasked() {
  try { return new URL(resolveRpcUrl()).host } catch { return 'unknown' }
}

let _id = 1
export async function rpc(method, params, { url = resolveRpcUrl(), retries = 4 } = {}) {
  let lastErr
  for (let i = 0; i < retries; i++) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: _id++, method, params }),
      })
      const j = await res.json()
      if (j.error) throw new Error(method + ': ' + JSON.stringify(j.error).slice(0, 200))
      return j.result
    } catch (e) {
      lastErr = e
      await new Promise((r) => setTimeout(r, 250 * (i + 1)))
    }
  }
  throw lastErr
}

// READ-ONLY guard: only these methods are ever allowed.
export const SAFE = new Set(['eth_getStorageAt', 'eth_getCode', 'eth_call', 'eth_getBalance', 'eth_chainId', 'eth_blockNumber', 'eth_getLogs', 'eth_getTransactionByHash'])
export async function safeRpc(method, params, opts) {
  if (!SAFE.has(method)) throw new Error('BLOCKED non-read method: ' + method)
  return rpc(method, params, opts)
}

export const SLOTS = {
  impl: '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc', // EIP-1967 implementation
  admin: '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103', // EIP-1967 admin
  beacon: '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50', // EIP-1967 beacon
}
export const addrFromSlot = (word) => (word && word.length >= 66 ? '0x' + word.slice(26) : null)

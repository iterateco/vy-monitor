import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });

const VP = '0xF612C21161F400AbA27A0ef18b030350898b7628';
const portalAbi = [
  { inputs: [], name: 'totalClaimed', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'totalEntitlements', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [{ type: 'address' }], name: 'claims', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [{ type: 'address' }], name: 'entitlements', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
];
const fmt = (x, d = 18) => Number(formatUnits(x, d));

const [totalClaimed, totalEntitlements] = await Promise.all([
  client.readContract({ address: VP, abi: portalAbi, functionName: 'totalClaimed' }),
  client.readContract({ address: VP, abi: portalAbi, functionName: 'totalEntitlements' }),
]);

console.log('=== ValinityPortal (VP) claim state ===');
console.log(`Address          : ${VP}`);
console.log(`totalClaimed     : ${fmt(totalClaimed).toLocaleString(undefined,{maximumFractionDigits:6})} VY   (raw ${totalClaimed})`);
console.log(`totalEntitlements: ${fmt(totalEntitlements).toLocaleString(undefined,{maximumFractionDigits:6})} VY   (raw ${totalEntitlements})`);
const pct = totalEntitlements > 0n ? (fmt(totalClaimed) / fmt(totalEntitlements) * 100) : 0;
console.log(`Claimed / Entitled: ${pct.toFixed(2)}%`);
console.log(`Outstanding      : ${fmt(totalEntitlements - totalClaimed).toLocaleString(undefined,{maximumFractionDigits:6})} VY`);

// Per-claimer breakdown from EntitlementClaimed events
const claimedEv = parseAbiItem('event EntitlementClaimed(address indexed account, uint256 amount)');
const setEv = parseAbiItem('event EntitlementSet(address indexed account, uint256 previousAmount, uint256 newAmount)');
const [claims, sets] = await Promise.all([
  client.getLogs({ address: VP, event: claimedEv, fromBlock: 0n, toBlock: 'latest' }),
  client.getLogs({ address: VP, event: setEv, fromBlock: 0n, toBlock: 'latest' }),
]);

const byAcct = {};
for (const l of claims) {
  const a = l.args.account;
  byAcct[a] = (byAcct[a] || 0n) + l.args.amount;
}
console.log(`\n=== Claim events ===`);
console.log(`EntitlementClaimed events: ${claims.length}   unique claimers: ${Object.keys(byAcct).length}`);
console.log(`EntitlementSet events    : ${sets.length}   unique entitled accounts: ${new Set(sets.map(s=>s.args.account)).size}`);

const sorted = Object.entries(byAcct).sort((a,b)=> (b[1]>a[1]?1:-1));
console.log('\nPer-claimer (sum of claimed):');
for (const [a, v] of sorted) {
  console.log(`  ${a}  ${fmt(v).toLocaleString(undefined,{maximumFractionDigits:6})} VY`);
}

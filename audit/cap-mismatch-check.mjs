import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';

const RPC = 'https://api.valinity.io/rpc-proxy';
const client = createPublicClient({ chain: mainnet, transport: http(RPC) });

const A = {
  VY:  '0x597b29520098d6aaca3B2e0D1a380315c9240454',
  VYT: '0xe58E29c947013B4CBCdb67f90d659c3894BE2974',
  VRT: '0x06087789B7122fA92E7F9868B10A286Dd4e4C832',
  VCO: '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C',
  VRYO:'0xA95749f52031dA2c4baB7cf38323B69A9E3415d3',
};
const COLLATERAL = {
  WETH: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  WBTC: '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',
  PAXG: '0x45804880de22913dafe09f4980848ece6ecbaf78',
};

const erc20 = [
  { inputs: [], name: 'totalSupply', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [{ type: 'address' }], name: 'balanceOf', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
];
const vco = [{
  inputs: [{ name: 'asset', type: 'address' }], name: 'getAssetMetrics',
  outputs: [{ components: [
    { name: 'totalReserve', type: 'uint256' }, { name: 'collateralCap', type: 'uint256' },
    { name: 'ltvRatio', type: 'uint256' }, { name: 'ltvF', type: 'uint256' },
    { name: 'utilized', type: 'uint256' }, { name: 'available', type: 'uint256' },
  ], type: 'tuple' }], stateMutability: 'view', type: 'function',
}];
const vryo = [{ inputs: [], name: 'capVRYO_total', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' }];

const f = (x) => Number(formatUnits(x, 18)).toLocaleString('en-US', { maximumFractionDigits: 6 });

const block = await client.getBlockNumber();
const [totalSupply, vytBal, vrtBal, deployedVY] = await Promise.all([
  client.readContract({ address: A.VY, abi: erc20, functionName: 'totalSupply' }),
  client.readContract({ address: A.VY, abi: erc20, functionName: 'balanceOf', args: [A.VYT] }),
  client.readContract({ address: A.VY, abi: erc20, functionName: 'balanceOf', args: [A.VRT] }),
  client.readContract({ address: A.VRYO, abi: vryo, functionName: 'capVRYO_total' }),
]);

const circulating = totalSupply - vytBal - vrtBal;

let totalCaps = 0n;
const capRows = {};
const reverts = {};
for (const [sym, addr] of Object.entries(COLLATERAL)) {
  // Mirror the monitor: multicall allowFailure:true → revert means collateralCap treated as 0
  try {
    const m = await client.readContract({ address: A.VCO, abi: vco, functionName: 'getAssetMetrics', args: [addr] });
    capRows[sym] = m.collateralCap;
    totalCaps += m.collateralCap;
  } catch (e) {
    capRows[sym] = 0n;
    reverts[sym] = e.shortMessage?.split('\n').pop()?.trim() || e.cause?.reason || 'reverted';
  }
}

const mismatch = (totalCaps + deployedVY) - circulating;

console.log(`\n=== Cap-circulating check @ block ${block} ===\n`);
console.log(`VY totalSupply           : ${f(totalSupply)}`);
console.log(`  − VYT balance          : ${f(vytBal)}`);
console.log(`  − VRT balance          : ${f(vrtBal)}`);
console.log(`= Circulating supply     : ${f(circulating)}\n`);
for (const [sym, v] of Object.entries(capRows)) console.log(`  cap ${sym.padEnd(5)}           : ${f(v)}${reverts[sym] ? `   <-- REVERTED ("${reverts[sym]}") → counted as 0` : ''}`);
console.log(`Σ VCO collateral caps    : ${f(totalCaps)}`);
console.log(`VRYO capVRYO_total       : ${f(deployedVY)}`);
console.log(`= Total caps (VCO+VRYO)  : ${f(totalCaps + deployedVY)}\n`);
console.log(`MISMATCH  (caps − circ)  : ${f(mismatch)} VY`);
console.log(`MISMATCH (raw wei)       : ${mismatch.toString()}`);
console.log(`Direction                : ${mismatch > 0n ? 'caps EXCEED circulating (over-capped)' : mismatch < 0n ? 'caps BELOW circulating (under-capped)' : 'exact match'}`);

console.log(`\nRaw wei:`);
console.log({ totalSupply, vytBal, vrtBal, circulating, ...capRows, totalCaps, deployedVY, mismatch });

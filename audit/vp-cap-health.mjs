import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });

// Addresses (mainnet)
const VY   = '0x597b29520098d6aaca3B2e0D1a380315c9240454';
const VYT  = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974';
const VRT  = '0x06087789B7122fA92E7F9868B10A286Dd4e4C832';
const VCO  = '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C';
const VRYO = '0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const COLLATERAL = {
  WETH: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  WBTC: '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',
  PAXG: '0x45804880de22913dafe09f4980848ece6ecbaf78',
};

const erc20 = [{ inputs: [], name: 'totalSupply', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
               { inputs: [{ type: 'address' }], name: 'balanceOf', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' }];
const vcoAbi = [
  { inputs: [{ type: 'address' }], name: 'getAssetMetrics', outputs: [{ components: [
      { name: 'totalReserve', type: 'uint256' }, { name: 'collateralCap', type: 'uint256' },
      { name: 'ltvRatio', type: 'uint256' }, { name: 'ltvF', type: 'uint256' },
      { name: 'utilized', type: 'uint256' }, { name: 'available', type: 'uint256' } ], type: 'tuple' }], stateMutability: 'view', type: 'function' },
  { inputs: [{ type: 'address' }], name: 'getAssetCap', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
];
const vryoAbi = [{ inputs: [], name: 'capVRYO_total', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' }];
const f = (x) => Number(formatUnits(x, 18));
const c = (x) => f(x).toLocaleString(undefined, { maximumFractionDigits: 6 });

const [vyTotalSupply, vytBal, vrtBal, deployedVY] = await Promise.all([
  client.readContract({ address: VY, abi: erc20, functionName: 'totalSupply' }),
  client.readContract({ address: VY, abi: erc20, functionName: 'balanceOf', args: [VYT] }),
  client.readContract({ address: VY, abi: erc20, functionName: 'balanceOf', args: [VRT] }),
  client.readContract({ address: VRYO, abi: vryoAbi, functionName: 'capVRYO_total' }),
]);

const totalUncollateralized = vyTotalSupply - vytBal - vrtBal; // circulating VY

// Per-asset cap: prefer getAssetMetrics.collateralCap; fall back to getAssetCap if metrics revert (stale oracle)
let totalCaps = 0n;
console.log('=== VCO per-asset caps ===');
for (const [sym, addr] of Object.entries(COLLATERAL)) {
  let cap = 0n, src = '';
  try {
    const m = await client.readContract({ address: VCO, abi: vcoAbi, functionName: 'getAssetMetrics', args: [addr] });
    cap = m.collateralCap; src = 'getAssetMetrics';
  } catch {
    try { cap = await client.readContract({ address: VCO, abi: vcoAbi, functionName: 'getAssetCap', args: [addr] }); src = 'getAssetCap (metrics reverted)'; }
    catch { src = 'BOTH REVERTED'; }
  }
  totalCaps += cap;
  console.log(`  ${sym.padEnd(5)} cap = ${c(cap).padStart(16)} VY   [${src}]`);
}

console.log('\n=== Inputs ===');
console.log(`VY totalSupply        : ${c(vyTotalSupply)} VY`);
console.log(`  − VYT balance       : ${c(vytBal)} VY`);
console.log(`  − VRT balance       : ${c(vrtBal)} VY`);
console.log(`= circulating (uncol.): ${c(totalUncollateralized)} VY`);
console.log('');
console.log(`VCO caps (Σ assets)   : ${c(totalCaps)} VY`);
console.log(`VRYO caps (deployed)  : ${c(deployedVY)} VY`);
console.log(`Total Caps (VCO+VRYO) : ${c(totalCaps + deployedVY)} VY`);

const lag = (totalCaps + deployedVY) - totalUncollateralized;
console.log('\n=== Cap Health ===');
console.log(`lag = (totalCaps + totalDeployedVY) − circulating`);
console.log(`    = (${c(totalCaps)} + ${c(deployedVY)}) − ${c(totalUncollateralized)}`);
if (lag === 0n) {
  console.log(`\n✅ HEALTHY — Total Caps = Circulating Supply (lag = 0)`);
} else {
  const sign = lag > 0n ? '+' : '−';
  const abs = lag > 0n ? lag : -lag;
  const dir = lag > 0n ? 'caps EXCEED circulating (over-capped)' : 'caps are BELOW circulating (under-capped)';
  console.log(`\n🔴 OFF BY ${sign}${c(abs)} VY  (raw ${lag})`);
  console.log(`   → ${dir}`);
  const pct = Math.abs(f(lag) / f(totalUncollateralized) * 100);
  console.log(`   → ${pct.toFixed(6)}% of circulating supply`);
}

/**
 * Staking analysis: trace VY staked vs VY in pools.
 * 
 * Flow: Users → StakingRouter → DAX + VyUsdcPool
 * StakingRouter holds VDAX tokens (DAX shares) and UNI-LP tokens (pool shares)
 */

import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';

const VY_TOKEN       = '0x597b29520098d6aaca3B2e0D1a380315c9240454';
const STAKING_ROUTER = '0x664b3A81C963F07C1eb06516c560f9b2193698C7';
const DAX            = '0xD256C672616f7c5DEE3e42a8199f121EE08401B7';
const VDAX           = '0xD985C0EA5394f9A1acece695885cbD5210d5A1f9';
const VY_USDC_POOL   = '0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705';
const VYT            = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974';
const VRT            = '0x06087789B7122fA92E7F9868B10A286Dd4e4C832';
const DEPLOYER       = '0x8310eA7EC55A7Ad6A4288aF683155A124A524a09';
const MEV_BOT        = '0xA1B8d744B4c6498aBE473c320B46d581Cc9D33A4';
const BUYBACK        = '0x4B97D45d276084c1C5BDBd0aa29B417cE02bE2F6';
const ACQ_OFFICER    = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const USDC           = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';

const KNOWN = {
  [VY_TOKEN.toLowerCase()]: 'VY Token',
  [STAKING_ROUTER.toLowerCase()]: 'StakingRouter',
  [DAX.toLowerCase()]: 'DAX',
  [VDAX.toLowerCase()]: 'VDAX',
  [VY_USDC_POOL.toLowerCase()]: 'VyUsdcPool',
  [VYT.toLowerCase()]: 'VYT',
  [VRT.toLowerCase()]: 'VRT',
  [DEPLOYER.toLowerCase()]: 'Deployer',
  [MEV_BOT.toLowerCase()]: 'MEVBot',
  [BUYBACK.toLowerCase()]: 'Buyback',
  [ACQ_OFFICER.toLowerCase()]: 'AcqOfficer',
  '0x0000000000000000000000000000000000000000': 'ZERO',
};

const erc20Abi = [
  { inputs: [], name: 'totalSupply', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [{ name: 'account', type: 'address' }], name: 'balanceOf', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'decimals', outputs: [{ type: 'uint8' }], stateMutability: 'view', type: 'function' },
];

const vsrAbi = [
  { inputs: [], name: 'totalStakedVY', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'totalDaxCredits', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'totalUniCredits', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'daxIndex', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'uniIndex', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
];

const daxAbi = [
  { inputs: [], name: 'getNumPools', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'getTotalVYReserves', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [{ name: 'poolId', type: 'uint256' }], name: 'getPoolReserves', outputs: [{ name: 'asset', type: 'address' }, { name: 'reserveVY', type: 'uint256' }, { name: 'reserveAsset', type: 'uint256' }], stateMutability: 'view', type: 'function' },
];

const pairAbi = [
  { inputs: [], name: 'getReserves', outputs: [{ name: 'reserve0', type: 'uint112' }, { name: 'reserve1', type: 'uint112' }, { name: 'blockTimestampLast', type: 'uint32' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'token0', outputs: [{ type: 'address' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'totalSupply', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
];

const client = createPublicClient({
  chain: mainnet,
  transport: http('https://api.valinity.io/rpc-proxy'),
});

const fmt = (v, d = 18) => formatUnits(v, d);
const label = (addr) => KNOWN[addr.toLowerCase()] || addr;

async function main() {
  const latestBlock = await client.getBlockNumber();
  console.log(`Block: ${latestBlock}\n`);

  // ─── 1. Current state: StakingRouter, DAX, Pool ───
  const [
    totalStakedVY, totalDaxCredits, totalUniCredits, daxIndex, uniIndex,
    routerVDAXBalance, routerUniLPBalance,
    vdaxTotalSupply,
    vyInDax, vyInPool,
    daxTotalVYReserves, numPools,
    pairReserves, pairToken0, pairTotalSupply,
    usdcInPool,
  ] = await Promise.all([
    client.readContract({ address: STAKING_ROUTER, abi: vsrAbi, functionName: 'totalStakedVY' }),
    client.readContract({ address: STAKING_ROUTER, abi: vsrAbi, functionName: 'totalDaxCredits' }),
    client.readContract({ address: STAKING_ROUTER, abi: vsrAbi, functionName: 'totalUniCredits' }),
    client.readContract({ address: STAKING_ROUTER, abi: vsrAbi, functionName: 'daxIndex' }),
    client.readContract({ address: STAKING_ROUTER, abi: vsrAbi, functionName: 'uniIndex' }),
    client.readContract({ address: VDAX, abi: erc20Abi, functionName: 'balanceOf', args: [STAKING_ROUTER] }),
    client.readContract({ address: VY_USDC_POOL, abi: erc20Abi, functionName: 'balanceOf', args: [STAKING_ROUTER] }),
    client.readContract({ address: VDAX, abi: erc20Abi, functionName: 'totalSupply' }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [DAX] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [VY_USDC_POOL] }),
    client.readContract({ address: DAX, abi: daxAbi, functionName: 'getTotalVYReserves' }),
    client.readContract({ address: DAX, abi: daxAbi, functionName: 'getNumPools' }),
    client.readContract({ address: VY_USDC_POOL, abi: pairAbi, functionName: 'getReserves' }),
    client.readContract({ address: VY_USDC_POOL, abi: pairAbi, functionName: 'token0' }),
    client.readContract({ address: VY_USDC_POOL, abi: pairAbi, functionName: 'totalSupply' }),
    client.readContract({ address: USDC, abi: erc20Abi, functionName: 'balanceOf', args: [VY_USDC_POOL] }),
  ]);

  const vyIsToken0 = pairToken0.toLowerCase() === VY_TOKEN.toLowerCase();
  const vyReserveInPair = vyIsToken0 ? pairReserves[0] : pairReserves[1];
  const usdcReserveInPair = vyIsToken0 ? pairReserves[1] : pairReserves[0];

  // Router's share of total pool
  const routerShareOfPool = pairTotalSupply > 0n
    ? (routerUniLPBalance * 10000n) / pairTotalSupply
    : 0n;
  const routerVYInPool = pairTotalSupply > 0n
    ? (vyReserveInPair * routerUniLPBalance) / pairTotalSupply
    : 0n;
  const routerUSDCInPool = pairTotalSupply > 0n
    ? (usdcReserveInPair * routerUniLPBalance) / pairTotalSupply
    : 0n;

  // VDAX share of DAX
  const routerShareOfDAX = vdaxTotalSupply > 0n
    ? (routerVDAXBalance * 10000n) / vdaxTotalSupply
    : 0n;
  const routerVYInDAX = vdaxTotalSupply > 0n
    ? (vyInDax * routerVDAXBalance) / vdaxTotalSupply
    : 0n;

  // DAX pools
  console.log('=== DAX POOLS ===');
  for (let i = 0n; i < numPools; i++) {
    const pool = await client.readContract({ address: DAX, abi: daxAbi, functionName: 'getPoolReserves', args: [i] });
    const [asset, reserveVY, reserveAsset] = pool;
    // Get asset symbol + decimals
    const [symbol, decimals] = await Promise.all([
      client.readContract({ address: asset, abi: erc20Abi, functionName: 'symbol' }).catch(() => asset.slice(0, 10)),
      client.readContract({ address: asset, abi: erc20Abi, functionName: 'decimals' }).catch(() => 18),
    ]);
    console.log(`  Pool ${i}: ${symbol}`);
    console.log(`    VY Reserve:    ${fmt(reserveVY)} VY`);
    console.log(`    Asset Reserve: ${fmt(reserveAsset, decimals)} ${symbol}`);
  }

  console.log('\n=== STAKING ROUTER STATE ===');
  console.log(`  Total Staked VY:     ${fmt(totalStakedVY)} VY`);
  console.log(`  Total DAX Credits:   ${fmt(totalDaxCredits)}`);
  console.log(`  Total UNI Credits:   ${fmt(totalUniCredits)}`);
  console.log(`  DAX Index:           ${fmt(daxIndex)}`);
  console.log(`  UNI Index:           ${fmt(uniIndex)}`);

  console.log('\n=== ROUTER TOKEN HOLDINGS ===');
  console.log(`  VDAX Balance:        ${fmt(routerVDAXBalance)} VDAX`);
  console.log(`  VDAX Total Supply:   ${fmt(vdaxTotalSupply)} VDAX`);
  console.log(`  Router % of DAX:     ${Number(routerShareOfDAX) / 100}%`);
  console.log(`  UNI-LP Balance:      ${fmt(routerUniLPBalance)} LP`);
  console.log(`  UNI-LP Total Supply: ${fmt(pairTotalSupply)} LP`);
  console.log(`  Router % of Pool:    ${Number(routerShareOfPool) / 100}%`);

  console.log('\n=== VY IN POOLS ===');
  console.log(`  VY in DAX (total):       ${fmt(vyInDax)} VY`);
  console.log(`  VY in Pool (total):      ${fmt(vyInPool)} VY`);
  console.log(`  VY in both pools:        ${fmt(vyInDax + vyInPool)} VY`);
  console.log(`  Router's VY in DAX:      ${fmt(routerVYInDAX)} VY`);
  console.log(`  Router's VY in Pool:     ${fmt(routerVYInPool)} VY`);
  console.log(`  Router's total VY:       ${fmt(routerVYInDAX + routerVYInPool)} VY`);

  console.log('\n=== UNISWAP POOL DETAIL ===');
  console.log(`  VY Reserve:          ${fmt(vyReserveInPair)} VY`);
  console.log(`  USDC Reserve:        ${fmt(usdcReserveInPair, 6)} USDC`);
  console.log(`  Router's USDC share: ${fmt(routerUSDCInPool, 6)} USDC`);

  console.log('\n=== GAP ANALYSIS ===');
  const totalVYInPools = vyInDax + vyInPool;
  const gap = totalStakedVY - totalVYInPools;
  console.log(`  Total Staked:        ${fmt(totalStakedVY)} VY`);
  console.log(`  Total VY in Pools:   ${fmt(totalVYInPools)} VY`);
  console.log(`  Gap:                 ${fmt(gap)} VY`);
  console.log(`  Router's actual VY:  ${fmt(routerVYInDAX + routerVYInPool)} VY`);
  console.log(`  Gap from router's perspective: ${fmt(totalStakedVY - routerVYInDAX - routerVYInPool)} VY`);

  // ─── 2. Trace StakingRouter VY flows ───
  console.log('\n=== STAKING ROUTER VY FLOWS ===');
  const srIn = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: STAKING_ROUTER },
    fromBlock: 0n, toBlock: latestBlock,
  });
  const srOut = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: STAKING_ROUTER },
    fromBlock: 0n, toBlock: latestBlock,
  });

  let srTotalIn = 0n, srTotalOut = 0n;
  const srInBy = {}, srOutBy = {};
  for (const log of srIn) {
    const src = label(log.args.from);
    srInBy[src] = (srInBy[src] || 0n) + log.args.value;
    srTotalIn += log.args.value;
  }
  for (const log of srOut) {
    const dest = label(log.args.to);
    srOutBy[dest] = (srOutBy[dest] || 0n) + log.args.value;
    srTotalOut += log.args.value;
  }

  console.log('  Inflows:');
  for (const [src, amount] of Object.entries(srInBy)) {
    console.log(`    ← ${src}: ${fmt(amount)} VY`);
  }
  console.log(`  Total In: ${fmt(srTotalIn)} VY\n`);

  console.log('  Outflows:');
  for (const [dest, amount] of Object.entries(srOutBy)) {
    console.log(`    → ${dest}: ${fmt(amount)} VY`);
  }
  console.log(`  Total Out: ${fmt(srTotalOut)} VY`);
  console.log(`  Net VY held by Router: ${fmt(srTotalIn - srTotalOut)} VY`);

  // ─── 3. DAX VY flows ───
  console.log('\n=== DAX VY FLOWS ===');
  const daxIn = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: DAX },
    fromBlock: 0n, toBlock: latestBlock,
  });
  const daxOut = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: DAX },
    fromBlock: 0n, toBlock: latestBlock,
  });

  let daxTotalIn = 0n, daxTotalOut = 0n;
  const daxInBy = {}, daxOutBy = {};
  for (const log of daxIn) {
    const src = label(log.args.from);
    daxInBy[src] = (daxInBy[src] || 0n) + log.args.value;
    daxTotalIn += log.args.value;
  }
  for (const log of daxOut) {
    const dest = label(log.args.to);
    daxOutBy[dest] = (daxOutBy[dest] || 0n) + log.args.value;
    daxTotalOut += log.args.value;
  }

  console.log('  Inflows:');
  for (const [src, amount] of Object.entries(daxInBy)) {
    console.log(`    ← ${src}: ${fmt(amount)} VY`);
  }
  console.log(`  Total In: ${fmt(daxTotalIn)} VY\n`);

  console.log('  Outflows:');
  for (const [dest, amount] of Object.entries(daxOutBy)) {
    console.log(`    → ${dest}: ${fmt(amount)} VY`);
  }
  console.log(`  Total Out: ${fmt(daxTotalOut)} VY`);
  console.log(`  Net VY: ${fmt(daxTotalIn - daxTotalOut)} VY`);

  // ─── 4. VyUsdcPool VY flows ───
  console.log('\n=== VY/USDC POOL VY FLOWS ===');
  const poolIn = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: VY_USDC_POOL },
    fromBlock: 0n, toBlock: latestBlock,
  });
  const poolOut = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: VY_USDC_POOL },
    fromBlock: 0n, toBlock: latestBlock,
  });

  let poolTotalIn = 0n, poolTotalOut = 0n;
  const poolInBy = {}, poolOutBy = {};
  for (const log of poolIn) {
    const src = label(log.args.from);
    poolInBy[src] = (poolInBy[src] || 0n) + log.args.value;
    poolTotalIn += log.args.value;
  }
  for (const log of poolOut) {
    const dest = label(log.args.to);
    poolOutBy[dest] = (poolOutBy[dest] || 0n) + log.args.value;
    poolTotalOut += log.args.value;
  }

  console.log('  Inflows:');
  for (const [src, amount] of Object.entries(poolInBy)) {
    console.log(`    ← ${src}: ${fmt(amount)} VY`);
  }
  console.log(`  Total In: ${fmt(poolTotalIn)} VY\n`);

  console.log('  Outflows:');
  for (const [dest, amount] of Object.entries(poolOutBy)) {
    console.log(`    → ${dest}: ${fmt(amount)} VY`);
  }
  console.log(`  Total Out: ${fmt(poolTotalOut)} VY`);
  console.log(`  Net VY: ${fmt(poolTotalIn - poolTotalOut)} VY`);
}

main().catch(e => { console.error(e); process.exit(1); });

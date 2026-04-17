/**
 * Precise pool value analysis: check if VY × 2 = total value,
 * or if the other-side assets are worth something different.
 */

import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';

const VY_TOKEN       = '0x597b29520098d6aaca3B2e0D1a380315c9240454';
const STAKING_ROUTER = '0x664b3A81C963F07C1eb06516c560f9b2193698C7';
const DAX            = '0xD256C672616f7c5DEE3e42a8199f121EE08401B7';
const VDAX           = '0xD985C0EA5394f9A1acece695885cbD5210d5A1f9';
const VY_USDC_POOL   = '0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705';
const USDC           = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const BUYBACK        = '0xD2F0826af20EbDc833c8418E312F23f373F8500e';
const MEV_BOT        = '0xA1B8d744B4c6498aBE473c320B46d581Cc9D33A4';
const DEPLOYER       = '0x8310eA7EC55A7Ad6A4288aF683155A124A524a09';
const ACQ_OFFICER    = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01';

const erc20Abi = [
  { inputs: [], name: 'totalSupply', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [{ name: 'account', type: 'address' }], name: 'balanceOf', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'decimals', outputs: [{ type: 'uint8' }], stateMutability: 'view', type: 'function' },
  { inputs: [], name: 'symbol', outputs: [{ type: 'string' }], stateMutability: 'view', type: 'function' },
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

const vsrAbi = [
  { inputs: [], name: 'totalStakedVY', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
];

const client = createPublicClient({
  chain: mainnet,
  transport: http('https://api.valinity.io/rpc-proxy'),
});

const fmt = (v, d = 18) => formatUnits(v, d);

async function main() {
  const latestBlock = await client.getBlockNumber();
  console.log(`Block: ${latestBlock}\n`);

  // ─── Current pool state ───
  const [
    totalStakedVY,
    pairReserves, pairToken0, pairTotalSupply,
    routerLPBalance,
    numPools,
  ] = await Promise.all([
    client.readContract({ address: STAKING_ROUTER, abi: vsrAbi, functionName: 'totalStakedVY' }),
    client.readContract({ address: VY_USDC_POOL, abi: pairAbi, functionName: 'getReserves' }),
    client.readContract({ address: VY_USDC_POOL, abi: pairAbi, functionName: 'token0' }),
    client.readContract({ address: VY_USDC_POOL, abi: pairAbi, functionName: 'totalSupply' }),
    client.readContract({ address: VY_USDC_POOL, abi: erc20Abi, functionName: 'balanceOf', args: [STAKING_ROUTER] }),
    client.readContract({ address: DAX, abi: daxAbi, functionName: 'getNumPools' }),
  ]);

  const vyIsToken0 = pairToken0.toLowerCase() === VY_TOKEN.toLowerCase();
  const vyReservePair = vyIsToken0 ? pairReserves[0] : pairReserves[1];
  const usdcReservePair = vyIsToken0 ? pairReserves[1] : pairReserves[0];

  // VY price from Uniswap pool (USDC per VY)
  // USDC has 6 decimals, VY has 18 decimals
  const vyPriceUSDC = Number(usdcReservePair) / 1e6 / (Number(vyReservePair) / 1e18);

  // DAX pool info
  const daxPool = await client.readContract({ address: DAX, abi: daxAbi, functionName: 'getPoolReserves', args: [0n] });
  const [daxAsset, daxReserveVY, daxReserveAsset] = daxPool;
  const [daxAssetSymbol, daxAssetDecimals] = await Promise.all([
    client.readContract({ address: daxAsset, abi: erc20Abi, functionName: 'symbol' }).catch(() => 'UNKNOWN'),
    client.readContract({ address: daxAsset, abi: erc20Abi, functionName: 'decimals' }).catch(() => 18),
  ]);

  // DAX implied price: VY per other-side asset
  const daxAssetPriceInVY = Number(daxReserveVY) / 1e18 / (Number(daxReserveAsset) / (10 ** daxAssetDecimals));
  const daxAssetValueInVY = (Number(daxReserveAsset) / (10 ** daxAssetDecimals)) * daxAssetPriceInVY;

  // Uniswap: value of USDC side in VY terms
  const usdcValueInVY = vyPriceUSDC > 0 ? (Number(usdcReservePair) / 1e6) / vyPriceUSDC : 0;

  // Router's share
  const routerPctPool = Number(routerLPBalance) / Number(pairTotalSupply);
  const vdaxBalance = await client.readContract({ address: VDAX, abi: erc20Abi, functionName: 'balanceOf', args: [STAKING_ROUTER] });
  const vdaxTotalSupply = await client.readContract({ address: VDAX, abi: erc20Abi, functionName: 'totalSupply' });
  const routerPctDAX = Number(vdaxBalance) / Number(vdaxTotalSupply);

  console.log('=== POOL RESERVES ===');
  console.log('');
  console.log('  Uniswap VY/USDC Pool:');
  console.log(`    VY Reserve:        ${fmt(vyReservePair)} VY`);
  console.log(`    USDC Reserve:      ${fmt(usdcReservePair, 6)} USDC`);
  console.log(`    VY Price (pool):   $${vyPriceUSDC.toFixed(6)}`);
  console.log(`    USDC side in VY:   ${usdcValueInVY.toFixed(6)} VY`);
  console.log(`    Router owns:       ${(routerPctPool * 100).toFixed(2)}% of LP`);
  console.log('');
  console.log(`  DAX Pool (VY/${daxAssetSymbol}):`);
  console.log(`    VY Reserve:        ${fmt(daxReserveVY)} VY`);
  console.log(`    ${daxAssetSymbol} Reserve:     ${fmt(daxReserveAsset, daxAssetDecimals)} ${daxAssetSymbol}`);
  console.log(`    ${daxAssetSymbol} price in VY: ${daxAssetPriceInVY.toFixed(6)} VY`);
  console.log(`    ${daxAssetSymbol} side in VY:  ${daxAssetValueInVY.toFixed(6)} VY`);
  console.log(`    Router owns:       ${(routerPctDAX * 100).toFixed(2)}% of VDAX`);

  console.log('');
  console.log('=== VALUE ACCOUNTING (in VY terms) ===');
  console.log('');

  const totalVYSide = Number(daxReserveVY) / 1e18 + Number(vyReservePair) / 1e18;
  const totalOtherSideInVY = daxAssetValueInVY + usdcValueInVY;
  const totalPoolValueInVY = totalVYSide + totalOtherSideInVY;

  const routerVYinDAX = (Number(daxReserveVY) / 1e18) * routerPctDAX;
  const routerAssetInDAX = daxAssetValueInVY * routerPctDAX;
  const routerVYinPool = (Number(vyReservePair) / 1e18) * routerPctPool;
  const routerUSDCinPool = usdcValueInVY * routerPctPool;
  const routerTotalValue = routerVYinDAX + routerAssetInDAX + routerVYinPool + routerUSDCinPool;

  console.log(`  VY side (both pools):          ${totalVYSide.toFixed(6)} VY`);
  console.log(`  Other side (both pools in VY):  ${totalOtherSideInVY.toFixed(6)} VY`);
  console.log(`  Total pool value:              ${totalPoolValueInVY.toFixed(6)} VY`);
  console.log('');
  console.log(`  Router's VY in DAX:            ${routerVYinDAX.toFixed(6)} VY`);
  console.log(`  Router's ${daxAssetSymbol} in DAX (in VY):  ${routerAssetInDAX.toFixed(6)} VY`);
  console.log(`  Router's VY in Pool:           ${routerVYinPool.toFixed(6)} VY`);
  console.log(`  Router's USDC in Pool (in VY): ${routerUSDCinPool.toFixed(6)} VY`);
  console.log(`  Router's total value:          ${routerTotalValue.toFixed(6)} VY`);

  console.log('');
  console.log('=== FINAL COMPARISON ===');
  console.log('');
  console.log(`  Total Staked by users:         ${fmt(totalStakedVY)} VY`);
  console.log(`  Router's total pool value:     ${routerTotalValue.toFixed(6)} VY`);
  console.log(`  Difference (missing):          ${(Number(totalStakedVY) / 1e18 - routerTotalValue).toFixed(6)} VY`);
  console.log('');

  // ─── Now trace: where did VY leave the pools to? ───
  console.log('=== BUYBACK VY FLOWS ===');
  const buybackIn = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: BUYBACK },
    fromBlock: 0n, toBlock: latestBlock,
  });
  const buybackOut = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: BUYBACK },
    fromBlock: 0n, toBlock: latestBlock,
  });
  
  const bbInBy = {}, bbOutBy = {};
  let bbTotalIn = 0n, bbTotalOut = 0n;

  const KNOWN = {
    [VY_USDC_POOL.toLowerCase()]: 'VyUsdcPool',
    [DAX.toLowerCase()]: 'DAX',
    [STAKING_ROUTER.toLowerCase()]: 'StakingRouter',
    [MEV_BOT.toLowerCase()]: 'MEVBot',
    [DEPLOYER.toLowerCase()]: 'Deployer',
    [ACQ_OFFICER.toLowerCase()]: 'AcqOfficer',
    [BUYBACK.toLowerCase()]: 'Buyback',
    '0x0000000000000000000000000000000000000000': 'ZERO(burn)',
  };
  const label = (a) => KNOWN[a.toLowerCase()] || a;

  for (const l of buybackIn) {
    const s = label(l.args.from);
    bbInBy[s] = (bbInBy[s] || 0n) + l.args.value;
    bbTotalIn += l.args.value;
  }
  for (const l of buybackOut) {
    const d = label(l.args.to);
    bbOutBy[d] = (bbOutBy[d] || 0n) + l.args.value;
    bbTotalOut += l.args.value;
  }

  console.log('  Inflows:');
  for (const [s, a] of Object.entries(bbInBy)) console.log(`    ← ${s}: ${fmt(a)} VY`);
  console.log(`  Total In: ${fmt(bbTotalIn)} VY`);
  console.log('  Outflows:');
  for (const [d, a] of Object.entries(bbOutBy)) console.log(`    → ${d}: ${fmt(a)} VY`);
  console.log(`  Total Out: ${fmt(bbTotalOut)} VY`);
  console.log(`  Net held: ${fmt(bbTotalIn - bbTotalOut)} VY`);

  // Check buyback's current VY balance
  const buybackBalance = await client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [BUYBACK] });
  console.log(`  Current balance: ${fmt(buybackBalance)} VY`);

  // ─── What did Buyback do with the USDC it used to buy VY? ───
  console.log('\n=== BUYBACK USDC FLOWS ===');
  const bbUsdcIn = await client.getLogs({
    address: USDC,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: BUYBACK },
    fromBlock: 0n, toBlock: latestBlock,
  });
  const bbUsdcOut = await client.getLogs({
    address: USDC,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: BUYBACK },
    fromBlock: 0n, toBlock: latestBlock,
  });

  let bbUsdcTotalIn = 0n, bbUsdcTotalOut = 0n;
  for (const l of bbUsdcIn) {
    console.log(`  ← ${label(l.args.from)}: +${fmt(l.args.value, 6)} USDC (block ${l.blockNumber})`);
    bbUsdcTotalIn += l.args.value;
  }
  for (const l of bbUsdcOut) {
    console.log(`  → ${label(l.args.to)}: -${fmt(l.args.value, 6)} USDC (block ${l.blockNumber})`);
    bbUsdcTotalOut += l.args.value;
  }
  console.log(`  USDC In: ${fmt(bbUsdcTotalIn, 6)} | Out: ${fmt(bbUsdcTotalOut, 6)} | Net: ${fmt(bbUsdcTotalIn - bbUsdcTotalOut, 6)}`);
}

main().catch(e => { console.error(e); process.exit(1); });

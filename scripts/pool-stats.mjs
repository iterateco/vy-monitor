// Quick analysis script: WETH/WBTC Uniswap V3 pool holdings, cumulative yield, and APY
import { createPublicClient, http, parseAbiItem, encodeAbiParameters, keccak256 } from '../node_modules/viem/_esm/index.js';
import { mainnet } from '../node_modules/viem/_esm/chains/index.js';

const RPC = 'https://ethereum.publicnode.com';
const client = createPublicClient({ chain: mainnet, transport: http(RPC) });

const VRYO = '0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const VLM  = '0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0';
const VLM_OLD = '0xfd2D528afAA5e7D58811ae859080E5e974Aa7392';
const NPM  = '0xC36442b4a4522E871399CD717aBDD847Ab11FE88';
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const WBTC = '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599';

const VRYO_ABI = [
  { name: 'PAIR_WETH_WBTC', inputs: [], outputs: [{ type: 'bytes32' }], stateMutability: 'view', type: 'function' },
];
const VLM_ABI = [
  { name: 'pairConfig', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'uint16' }, { type: 'uint16' }, { type: 'address' }, { type: 'uint32' }, { type: 'uint32' }, { type: 'uint16' }, { type: 'uint16' }, { type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'address' }, { type: 'bool' }, { type: 'uint16' }], stateMutability: 'view', type: 'function' },
  { name: 'activeTokenId', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { name: 'lastRefreshAt', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'uint64' }], stateMutability: 'view', type: 'function' },
  { name: 'lastRebalanceAt', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'uint64' }], stateMutability: 'view', type: 'function' },
];
const NPM_ABI = [
  { name: 'positions', inputs: [{ type: 'uint256' }], outputs: [{ type: 'uint96' }, { type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'int24' }, { type: 'uint128' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint128' }, { type: 'uint128' }], stateMutability: 'view', type: 'function' },
];
const POOL_ABI = [
  { name: 'slot0', inputs: [], outputs: [{ type: 'uint160' }, { type: 'int24' }, { type: 'uint16' }, { type: 'uint16' }, { type: 'uint16' }, { type: 'uint8' }, { type: 'bool' }], stateMutability: 'view', type: 'function' },
  { name: 'feeGrowthGlobal0X128', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { name: 'feeGrowthGlobal1X128', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { name: 'ticks', inputs: [{ type: 'int24', name: 'tick' }], outputs: [{ type: 'uint128', name: 'liquidityGross' }, { type: 'int128', name: 'liquidityNet' }, { type: 'uint256', name: 'feeGrowthOutside0X128' }, { type: 'uint256', name: 'feeGrowthOutside1X128' }, { type: 'int56', name: 'tickCumulativeOutside' }, { type: 'uint160', name: 'secondsPerLiquidityOutsideX128' }, { type: 'uint32', name: 'secondsOutside' }, { type: 'bool', name: 'initialized' }], stateMutability: 'view', type: 'function' },
];

// Uniswap V3 math
const Q96 = 2n ** 96n;
const Q128 = 2n ** 128n;
const Q256 = 2n ** 256n;
const TICK_BASE = 1.0001;

// Modular subtraction for uint256 fee growth values (they intentionally overflow)
function subMod256(a, b) { return ((a - b) % Q256 + Q256) % Q256; }

function tickToSqrtPriceX96(tick) {
  const price = Math.pow(TICK_BASE, tick);
  const sqrtPrice = Math.sqrt(price);
  return BigInt(Math.floor(sqrtPrice * Number(Q96)));
}

function getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity) {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  let amount0 = 0n, amount1 = 0n;
  if (sqrtP <= sqrtA) {
    amount0 = (liquidity * Q96 * (sqrtB - sqrtA)) / (sqrtA * sqrtB);
  } else if (sqrtP < sqrtB) {
    amount0 = (liquidity * Q96 * (sqrtB - sqrtP)) / (sqrtP * sqrtB);
    amount1 = (liquidity * (sqrtP - sqrtA)) / Q96;
  } else {
    amount1 = (liquidity * (sqrtB - sqrtA)) / Q96;
  }
  return { amount0, amount1 };
}

// Paginated getLogs: scans in 50k block chunks
async function getLogsPaginated(params, startBlock, endBlock) {
  const CHUNK = 49999n;
  const logs = [];
  for (let from = startBlock; from <= endBlock; from += CHUNK + 1n) {
    const to = from + CHUNK > endBlock ? endBlock : from + CHUNK;
    const chunk = await client.getLogs({ ...params, fromBlock: from, toBlock: to });
    logs.push(...chunk);
    process.stdout.write('.');
  }
  return logs;
}

async function main() {
  console.log('Querying blockchain...\n');

  // Get current block
  const currentBlock = await client.getBlockNumber();
  console.log('Current block:', currentBlock.toString());

  // 1. Get pair key
  const pairKey = await client.readContract({ address: VRYO, abi: VRYO_ABI, functionName: 'PAIR_WETH_WBTC' });
  console.log('WETH/WBTC pair key:', pairKey);

  // 2. VLM config + state
  const [cfg, tokenId, lastRefresh, lastRebalance] = await Promise.all([
    client.readContract({ address: VLM, abi: VLM_ABI, functionName: 'pairConfig', args: [pairKey] }),
    client.readContract({ address: VLM, abi: VLM_ABI, functionName: 'activeTokenId', args: [pairKey] }),
    client.readContract({ address: VLM, abi: VLM_ABI, functionName: 'lastRefreshAt', args: [pairKey] }),
    client.readContract({ address: VLM, abi: VLM_ABI, functionName: 'lastRebalanceAt', args: [pairKey] }),
  ]);
  const poolAddr = cfg[0];
  console.log('Pool address:', poolAddr);
  console.log('Active tokenId:', tokenId.toString());
  console.log('Last refresh:', new Date(Number(lastRefresh) * 1000).toISOString());
  console.log('Last rebalance:', new Date(Number(lastRebalance) * 1000).toISOString());

  // 3. Pool slot0 + position data
  const [slot0, position] = await Promise.all([
    client.readContract({ address: poolAddr, abi: POOL_ABI, functionName: 'slot0' }),
    tokenId > 0n ? client.readContract({ address: NPM, abi: NPM_ABI, functionName: 'positions', args: [tokenId] }) : null,
  ]);
  const sqrtP = slot0[0];
  const currentTick = slot0[1];

  if (!position) { console.log('No active position'); return; }
  const tickLower = position[5];
  const tickUpper = position[6];
  const liquidity = position[7];
  const feeGrowthInside0Last = position[8]; // last snapshotted fee growth inside
  const feeGrowthInside1Last = position[9];
  const tokensOwed0Snapshot = position[10]; // already-snapshotted fees (from last collect/decrease)
  const tokensOwed1Snapshot = position[11];

  const sqrtA = tickToSqrtPriceX96(tickLower);
  const sqrtB = tickToSqrtPriceX96(tickUpper);
  const { amount0: principal0, amount1: principal1 } = getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);

  // Compute LIVE accruing fees using pool fee growth data (proper Uniswap V3 math)
  const [feeGrowthGlobal0, feeGrowthGlobal1, tickLowerData, tickUpperData] = await Promise.all([
    client.readContract({ address: poolAddr, abi: POOL_ABI, functionName: 'feeGrowthGlobal0X128' }),
    client.readContract({ address: poolAddr, abi: POOL_ABI, functionName: 'feeGrowthGlobal1X128' }),
    client.readContract({ address: poolAddr, abi: POOL_ABI, functionName: 'ticks', args: [tickLower] }),
    client.readContract({ address: poolAddr, abi: POOL_ABI, functionName: 'ticks', args: [tickUpper] }),
  ]);
  const fgo0Lower = tickLowerData[2], fgo1Lower = tickLowerData[3];
  const fgo0Upper = tickUpperData[2], fgo1Upper = tickUpperData[3];

  // Fee growth below lower tick
  const fgBelow0 = currentTick >= tickLower ? fgo0Lower : subMod256(feeGrowthGlobal0, fgo0Lower);
  const fgBelow1 = currentTick >= tickLower ? fgo1Lower : subMod256(feeGrowthGlobal1, fgo1Lower);
  // Fee growth above upper tick
  const fgAbove0 = currentTick < tickUpper ? fgo0Upper : subMod256(feeGrowthGlobal0, fgo0Upper);
  const fgAbove1 = currentTick < tickUpper ? fgo1Upper : subMod256(feeGrowthGlobal1, fgo1Upper);
  // Fee growth inside range
  const fgInside0 = subMod256(subMod256(feeGrowthGlobal0, fgBelow0), fgAbove0);
  const fgInside1 = subMod256(subMod256(feeGrowthGlobal1, fgBelow1), fgAbove1);
  // Live fees = (fgInside - last snapshot) * liquidity / 2^128 + already-snapshotted
  const liveFees0 = subMod256(fgInside0, feeGrowthInside0Last) * liquidity / Q128 + tokensOwed0Snapshot;
  const liveFees1 = subMod256(fgInside1, feeGrowthInside1Last) * liquidity / Q128 + tokensOwed1Snapshot;

  // WBTC is token0 in the pool (lower address), WETH is token1
  const token0InCfg = cfg[5].toLowerCase();
  const wethIsToken0 = token0InCfg === WETH.toLowerCase();
  const wethAmt = wethIsToken0 ? principal0 : principal1;
  const wbtcAmt = wethIsToken0 ? principal1 : principal0;
  const wethOwed = wethIsToken0 ? liveFees0 : liveFees1;
  const wbtcOwed = wethIsToken0 ? liveFees1 : liveFees0;

  console.log('\n=== CURRENT HOLDINGS ===');
  console.log('Token0 in cfg:', wethIsToken0 ? 'WETH' : 'WBTC');
  console.log('WETH in position:', (Number(wethAmt) / 1e18).toFixed(6), 'WETH');
  console.log('WBTC in position:', (Number(wbtcAmt) / 1e8).toFixed(8), 'WBTC');
  console.log('Live unclaimed WETH fees:', (Number(wethOwed) / 1e18).toFixed(8), 'WETH  (fee growth math)');
  console.log('Live unclaimed WBTC fees:', (Number(wbtcOwed) / 1e8).toFixed(10), 'WBTC  (fee growth math)');
  console.log('Current tick:', currentTick, '| Range:', tickLower, '-', tickUpper);
  console.log('In range:', currentTick >= tickLower && currentTick <= tickUpper);

  // 4. Scan PositionMinted/PositionRebalanced events from both VLM addresses
  // Use pairKey as topic2 filter to limit scope
  console.log('\nScanning PositionMinted events from VLMs...');
  const positionMintedEvent = parseAbiItem('event PositionMinted(bytes32 indexed pairKey, uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1)');
  const positionRebalancedEvent = parseAbiItem('event PositionRebalanced(bytes32 indexed pairKey, uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity)');

  const START_BLOCK = 20_000_000n; // ~July 2024

  const tokenIdToPairKey = new Map();
  const wethWbtcTokenIds = new Set();
  let firstBlock = Number(currentBlock);

  for (const addr of [VLM, VLM_OLD]) {
    console.log('\nScanning PositionMinted from', addr.slice(0,10), '...');
    const logs = await getLogsPaginated(
      { address: addr, event: positionMintedEvent, args: { pairKey } },
      START_BLOCK, currentBlock
    );
    for (const log of logs) {
      const tid = log.args.tokenId;
      const pk = log.args.pairKey;
      if (tid !== undefined && pk !== undefined && pk.toLowerCase() === pairKey.toLowerCase()) {
        tokenIdToPairKey.set(tid, pk);
        wethWbtcTokenIds.add(tid);
        if (Number(log.blockNumber) < firstBlock) firstBlock = Number(log.blockNumber);
      }
    }

    console.log('\nScanning PositionRebalanced from', addr.slice(0,10), '...');
    const reLogs = await getLogsPaginated(
      { address: addr, event: positionRebalancedEvent, args: { pairKey } },
      START_BLOCK, currentBlock
    );
    for (const log of reLogs) {
      const { pairKey: pk, oldTokenId, newTokenId } = log.args;
      if (!pk || pk.toLowerCase() !== pairKey.toLowerCase()) continue;
      if (oldTokenId !== undefined) { wethWbtcTokenIds.add(oldTokenId); tokenIdToPairKey.set(oldTokenId, pk); }
      if (newTokenId !== undefined) { wethWbtcTokenIds.add(newTokenId); tokenIdToPairKey.set(newTokenId, pk); }
      if (Number(log.blockNumber) < firstBlock) firstBlock = Number(log.blockNumber);
    }
  }

  console.log('\nWETH/WBTC tokenIds:', [...wethWbtcTokenIds].map(t => t.toString()).join(', '));

  // Get timestamp of first position
  let firstTimestamp = null;
  if (firstBlock < Number(currentBlock)) {
    const block = await client.getBlock({ blockNumber: BigInt(firstBlock) });
    firstTimestamp = Number(block.timestamp);
    console.log('First position opened:', new Date(firstTimestamp * 1000).toISOString(), '(block', firstBlock, ')');
  }

  // 5. Scan Collect + DecreaseLiquidity events per tokenId (indexed, so very targeted)
  const collectEvent = parseAbiItem('event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1)');
  const decreaseEvent = parseAbiItem('event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)');

  const feesPerTokenId = new Map();

  for (const tid of wethWbtcTokenIds) {
    console.log('\nScanning fees for tokenId', tid.toString(), '...');
    const [cLogs, dLogs] = await Promise.all([
      getLogsPaginated({ address: NPM, event: collectEvent, args: { tokenId: tid } }, START_BLOCK, currentBlock),
      getLogsPaginated({ address: NPM, event: decreaseEvent, args: { tokenId: tid } }, START_BLOCK, currentBlock),
    ]);
    const f = { collect0: 0n, collect1: 0n, dec0: 0n, dec1: 0n };
    for (const log of cLogs) { f.collect0 += log.args.amount0 ?? 0n; f.collect1 += log.args.amount1 ?? 0n; }
    for (const log of dLogs) { f.dec0 += log.args.amount0 ?? 0n; f.dec1 += log.args.amount1 ?? 0n; }
    feesPerTokenId.set(tid, f);
    console.log(' collect0:', f.collect0.toString(), 'collect1:', f.collect1.toString(), 'dec0:', f.dec0.toString(), 'dec1:', f.dec1.toString());
  }

  // 6. Sum cumulative fees (Collect - DecreaseLiquidity = pure yield fees)
  let cumFees_weth = 0n;
  let cumFees_wbtc = 0n;
  for (const [, fees] of feesPerTokenId) {
    // token0 in pool is WBTC (lower address), token1 is WETH
    // wethIsToken0 is false here (WBTC < WETH address)
    const add_weth = wethIsToken0 ? fees.collect0 - fees.dec0 : fees.collect1 - fees.dec1;
    const add_wbtc = wethIsToken0 ? fees.collect1 - fees.dec1 : fees.collect0 - fees.dec0;
    cumFees_weth += add_weth;
    cumFees_wbtc += add_wbtc;
  }
  // Add live unclaimed fees
  cumFees_weth += wethOwed;
  cumFees_wbtc += wbtcOwed;

  console.log('\n=== CUMULATIVE YIELD (FEES EARNED) ===');
  console.log('Total WETH fees:', (Number(cumFees_weth) / 1e18).toFixed(6), 'WETH');
  console.log('Total WBTC fees:', (Number(cumFees_wbtc) / 1e8).toFixed(8), 'WBTC');

  // 7. Get USD prices
  let wethUsd = 0, wbtcUsd = 0;
  try {
    const resp = await fetch('https://api.coingecko.com/api/v3/simple/price?ids=ethereum,wrapped-bitcoin&vs_currencies=usd');
    const data = await resp.json();
    wethUsd = data.ethereum?.usd ?? 0;
    wbtcUsd = data['wrapped-bitcoin']?.usd ?? 0;
    console.log('\nWETH price: $' + wethUsd.toFixed(2));
    console.log('WBTC price: $' + wbtcUsd.toFixed(2));
  } catch (e) {
    console.log('Could not fetch prices:', e.message);
  }

  if (wethUsd > 0 && wbtcUsd > 0 && firstTimestamp) {
    const principalUsd = (Number(wethAmt) / 1e18) * wethUsd + (Number(wbtcAmt) / 1e8) * wbtcUsd;
    const feesUsd = (Number(cumFees_weth) / 1e18) * wethUsd + (Number(cumFees_wbtc) / 1e8) * wbtcUsd;
    const now = Math.floor(Date.now() / 1000);
    const elapsedSecs = now - firstTimestamp;
    const elapsedDays = elapsedSecs / 86400;
    const elapsedYears = elapsedSecs / (86400 * 365.25);

    console.log('\n=== YIELD ANALYSIS ===');
    console.log('First position opened:', new Date(firstTimestamp * 1000).toISOString().split('T')[0]);
    console.log('Time elapsed:         ', elapsedDays.toFixed(1), 'days');
    console.log('Current principal:     $' + principalUsd.toFixed(2),
      '(' + (Number(wethAmt)/1e18).toFixed(4) + ' WETH + ' + (Number(wbtcAmt)/1e8).toFixed(6) + ' WBTC)');
    console.log('Cumulative fees:       $' + feesUsd.toFixed(2),
      '(' + (Number(cumFees_weth)/1e18).toFixed(6) + ' WETH + ' + (Number(cumFees_wbtc)/1e8).toFixed(8) + ' WBTC)');

    const yieldPct = feesUsd / principalUsd * 100;
    const apy = ((1 + feesUsd / principalUsd) ** (1 / elapsedYears) - 1) * 100;
    console.log('\nYield %:   ' + yieldPct.toFixed(4) + '%  (fees / current principal in USD)');
    console.log('APY:       ' + apy.toFixed(4) + '%  (annualized)');
  }
}

main().catch(e => { console.error('\n', e.shortMessage ?? e.message ?? e); process.exit(1); });

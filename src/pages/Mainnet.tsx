import flatten from 'lodash/flatten';
import omit from 'lodash/omit';
import startCase from 'lodash/startCase';
import { useEffect, useState, type JSX } from 'react';
import { createPublicClient, http, parseAbiItem, type Address } from 'viem';
import { mainnet } from 'viem/chains';
import { Value, BandIndicator } from '../components/core';
import { CONTRACT_ACRONYMS, MAINNET_RPC_URL, MAINNET_API_URL } from '../config';
import { Amount, USD, VY, VDAX, UNI_LP } from '../models';
import type { Currency } from '../models';
import networks from '../networks';


/**
 * Assets soportados como colateral (LoanOfficer, CapOfficer, AcquisitionOfficer).
 * USDC NO es colateral — llamar getAssetView(USDC) causa UnsupportedAsset().
 */
const COLLATERAL_SYMBOLS = new Set(['WETH', 'WBTC', 'PAXG']);

const client = createPublicClient({
  chain: mainnet,
  transport: http(MAINNET_RPC_URL),
});

const fetchData = async () => {
  const networkName = 'mainnet';
  const { abis, addresses, assets: assetAddresses } = networks[networkName];
  const assetEntries = Object.entries(assetAddresses) as [string, Address][];

  const getContractConfig = <T extends keyof typeof abis>(name: T, address?: Address) => {
    return {
      abi: abis[name],
      address: address ?? (addresses as Record<string, Address>)[name as string]
    }
  }

  const vyTokenConfig = getContractConfig('ValinityToken');
  const vaoConfig = getContractConfig('ValinityAcquisitionOfficer');
  const vcoConfig = getContractConfig('ValinityCapOfficer');
  const vloConfig = getContractConfig('ValinityLoanOfficer');
  const daxConfig = getContractConfig('ValinityDAX');
  const vsrConfig = getContractConfig('ValinityStakingRouter');
  const vryoConfig = getContractConfig('ValinityReserveYieldOfficer');
  const vlmConfig = getContractConfig('ValinityLiquidityManager');
  const npmConfig = getContractConfig('NonfungiblePositionManager', (addresses as Record<string, Address>)['UniswapV3NonfungiblePositionManager']);

  const effectiveFloorResult = await client.readContract({
    ...vcoConfig,
    functionName: 'effectiveFloor',
  }).catch(() => 0n);
  const effectiveFloor = effectiveFloorResult as bigint;

  const assets = await Promise.all(assetEntries.map(async ([assetKey, assetAddr]) => {
    const tokenConfig = getContractConfig('ERC20', assetAddr);
    const isCollateral = COLLATERAL_SYMBOLS.has(assetKey);

    // Base calls: decimals + symbol (always)
    const baseContracts = [
      { ...tokenConfig, functionName: 'decimals' },
      { ...tokenConfig, functionName: 'symbol' },
    ];

    // Collateral-only calls: spotPrice, assetView, assetMetrics
    const collateralContracts = isCollateral ? [
      { ...vaoConfig, functionName: 'getAssetTwapPrice', args: [assetAddr] },
      { ...vloConfig, functionName: 'getAssetView', args: [assetAddr] },
      { ...vcoConfig, functionName: 'getAssetMetrics', args: [assetAddr] },
      { ...vcoConfig, functionName: 'getAssetCollateralized', args: [assetAddr] },
    ] : [];

    const results = await client.multicall({
      contracts: [...baseContracts, ...collateralContracts],
      allowFailure: true
    });

    const errors: string[] = [];
    const warnings: string[] = [];
    const get = <T,>(idx: number, label: string, fallback: T): T => {
      const r = results[idx];
      if (r.status === 'success') return r.result as T;
      // For collateral: spot price / LTVF reverts are warnings (pool not configured), not errors
      const msg = `${label}: ${(r.error as Error).message ?? 'reverted'}`;
      if (label === 'getAssetTwapPrice' || label === 'getAssetMetrics') {
        warnings.push(msg);
      } else {
        errors.push(msg);
      }
      return fallback;
    };

    const decimals = get(0, 'decimals', 18);
    const symbol = get(1, 'symbol', assetAddr.slice(0, 10));
    const currency = { symbol, decimals };

    if (!isCollateral) {
      // Stablecoin: no LoanOfficer/CapOfficer/VAO calls
      return {
        symbol,
        currency,
        address: assetAddr,
        isCollateral: false,
        errors,
        warnings,
        spotPrice: new Amount(USD, 0n),
        LTV: 0n,
        LTVF: new Amount(USD, 0n),
        reserveBalance: new Amount(currency, 0n),
        reserveBalanceUSD: new Amount(USD, 0n),
        totalLoaned: new Amount(currency, 0n),
        totalLoanedUSD: new Amount(USD, 0n),
        cap: new Amount(VY, 0n),
        capFloor: new Amount(VY, 0n),
        collateralized: new Amount(VY, 0n),
        notCollateral: true
      }
    }

    // Collateral asset — parse remaining results (indices 2..5)
    const spotPrice = get(2, 'getAssetTwapPrice', 0n);
    const assetView = results[3].status === 'success'
      ? results[3].result as unknown as { ltv: bigint; reserveBalance: bigint; totalLoaned: bigint }
      : (() => { errors.push(`getAssetView: ${(results[3].error as Error).message ?? 'reverted'}`); return { ltv: 0n, reserveBalance: 0n, totalLoaned: 0n }; })();
    const { reserveBalance, totalLoaned } = assetView;
    const defaultMetrics = { totalReserve: 0n, collateralCap: 0n, ltvRatio: 0n, ltvF: 0n, utilized: 0n, available: 0n };
    const metrics = results[4].status === 'success'
      ? results[4].result as unknown as typeof defaultMetrics
      : (() => { warnings.push(`getAssetMetrics: ${(results[4].error as Error).message ?? 'reverted'}`); return defaultMetrics; })();
    const { ltvRatio: ltv, ltvF: ltvf, collateralCap: cap, utilized } = metrics;
    const collateralized = get(5, 'getAssetCollateralized', utilized);

    const scaleFactor = BigInt(10) ** BigInt(18 - decimals);

    return {
      symbol,
      currency,
      address: assetAddr,
      isCollateral: true,
      errors,
      warnings,
      spotPrice: new Amount(USD, spotPrice),
      LTV: ltv,
      LTVF: new Amount(USD, ltvf),
      reserveBalance: new Amount(currency, reserveBalance),
      reserveBalanceUSD: new Amount(USD, spotPrice ? ((reserveBalance * scaleFactor) * spotPrice) / BigInt(1e18) : 0n),
      totalLoaned: new Amount(currency, totalLoaned),
      totalLoanedUSD: new Amount(USD, spotPrice ? ((totalLoaned * scaleFactor) * spotPrice) / BigInt(1e18) : 0n),
      cap: new Amount(VY, cap),
      capFloor: new Amount(VY, effectiveFloor),
      collateralized: new Amount(VY, collateralized)
    }
  }));

  const overviewErrors: string[] = [];
  const overviewWarnings: string[] = [];

  const pairAddress = (addresses as Record<string, Address>)['VyUsdcPool'];
  const vyTokenAddress = (addresses as Record<string, Address>)['ValinityToken'];
  const pairAbi = [
    { inputs: [], name: 'getReserves', outputs: [{ name: 'reserve0', type: 'uint112' }, { name: 'reserve1', type: 'uint112' }, { name: 'blockTimestampLast', type: 'uint32' }], stateMutability: 'view', type: 'function' },
    { inputs: [], name: 'token0', outputs: [{ name: '', type: 'address' }], stateMutability: 'view', type: 'function' },
  ] as const;
  const pairConfig = { abi: pairAbi, address: pairAddress };

  const [overviewResults, mtpResponse] = await Promise.all([
    client.multicall({
      contracts: [
        { ...vyTokenConfig, functionName: 'totalSupply' },
        { ...pairConfig, functionName: 'getReserves' },
        { ...pairConfig, functionName: 'token0' },
        { ...vyTokenConfig, functionName: 'accumulatedFees' },
      ],
      allowFailure: true
    }),
    fetch(`${MAINNET_API_URL}/market-data?count=1`).then(r => r.json()).catch(() => null),
  ]);

  const vyTotalSupply = overviewResults[0].status === 'success'
    ? overviewResults[0].result as bigint
    : (() => { overviewErrors.push(`totalSupply: ${(overviewResults[0].error as Error).message ?? 'reverted'}`); return 0n; })();
  const vyAccumulatedFees = overviewResults[3].status === 'success'
    ? overviewResults[3].result as bigint
    : (() => { overviewErrors.push(`accumulatedFees: ${(overviewResults[3].error as Error).message ?? 'reverted'}`); return 0n; })();
  const mtpPrice = mtpResponse?.data?.[0]?.market_trigger_price;
  const mtp = mtpPrice != null
    ? new Amount(USD, BigInt(Math.round(parseFloat(mtpPrice) * 1e18)))
    : (() => { overviewWarnings.push(`MTP: Could not fetch from API`); return 'Unavailable' as const; })();

  const USDC: Currency = { symbol: 'USDC', decimals: 6 };
  let vyReserve = 0n;
  let usdcReserve = 0n;
  if (overviewResults[1].status === 'success' && overviewResults[2].status === 'success') {
    const [reserve0, reserve1] = overviewResults[1].result as [bigint, bigint, number];
    const token0 = overviewResults[2].result as Address;
    const vyIsToken0 = token0.toLowerCase() === vyTokenAddress.toLowerCase();
    vyReserve = vyIsToken0 ? reserve0 : reserve1;
    usdcReserve = vyIsToken0 ? reserve1 : reserve0;
  } else {
    overviewWarnings.push(`getReserves: Pool pair not available`);
  }

  const tokenHolders = [
    'ValinityYieldTreasury',
    'ValinityReserveTreasury',
    'ValinityCapOfficer',
    'ValinityPortal',
    'Deployer'
  ] as const;

  const tokenHolderReads = tokenHolders.map(name => {
    return [
      {
        ...vyTokenConfig,
        functionName: 'balanceOf',
        args: [(addresses as Record<string, Address>)[name]]
      },
      ...assets.map(asset => ({
        abi: abis.ERC20,
        address: asset.address,
        functionName: 'balanceOf',
        args: [(addresses as Record<string, Address>)[name]]
      }))
    ]
  });

  const balancesRaw = await client.multicall({
    contracts: flatten(tokenHolderReads),
    allowFailure: true
  });

  const balanceMap = {} as { [K in typeof tokenHolders[number]]: Amount<bigint>[] }
  const balancesResultBatchLen = assets.length + 1;

  for (let i = 0; i < tokenHolders.length; i++) {
    const holder = tokenHolders[i];
    const batch = balancesRaw.slice(
      i * balancesResultBatchLen,
      balancesResultBatchLen + i * balancesResultBatchLen
    );
    balanceMap[holder] = batch.map((r, j) => {
      const currency = j === 0 ? VY : assets[j - 1].currency;
      if (r.status === 'success') return new Amount(currency, r.result as bigint);
      overviewErrors.push(`balanceOf(${holder}, ${currency.symbol}): reverted`);
      return new Amount(currency, 0n);
    })
  }

  const totalUncollateralized = (
    vyTotalSupply -
    balanceMap.ValinityYieldTreasury[0].value -
    balanceMap.ValinityReserveTreasury[0].value -
    balanceMap.ValinityCapOfficer[0].value
  );

  const totalCaps = assets
    .filter(a => a.isCollateral)
    .reduce((sum, a) => sum + (a.cap.value as bigint), 0n);
  // Cap-circulating health is recomputed below once totalDeployedVY is known (caps lowered
  // from VCO are expected to reappear as deployed VY in VRYO/VLM).

  let tvl = 0n;
  for (const asset of assets) {
    tvl += (asset.reserveBalanceUSD.value as bigint) + (asset.totalLoanedUSD.value as bigint);
  }

  // Check if any collateral asset has config warnings (pools not ready)
  const hasConfigWarnings = overviewWarnings.length > 0 ||
    assets.some(a => a.isCollateral && a.warnings && a.warnings.length > 0);

  // --- DAX ---
  const daxErrors: string[] = [];
  const daxBaseResults = await client.multicall({
    contracts: [
      { ...daxConfig, functionName: 'getNumPools' },
      { ...daxConfig, functionName: 'getTotalVYReserves' },
      { ...daxConfig, functionName: 'depositsPaused' },
      { ...daxConfig, functionName: 'withdrawalsPaused' },
      { ...daxConfig, functionName: 'swapsPaused' },
    ],
    allowFailure: true
  });

  const daxGet = <T,>(idx: number, label: string, fallback: T): T => {
    const r = daxBaseResults[idx];
    if (r.status === 'success') return r.result as T;
    daxErrors.push(`${label}: ${(r.error as Error).message ?? 'reverted'}`);
    return fallback;
  };

  const numPools = daxGet(0, 'getNumPools', 0n);
  const totalVYReserves = daxGet(1, 'getTotalVYReserves', 0n);
  const daxDepositsPaused = daxGet(2, 'depositsPaused', false);
  const daxWithdrawalsPaused = daxGet(3, 'withdrawalsPaused', false);
  const daxSwapsPaused = daxGet(4, 'swapsPaused', false);

  // Fetch each pool's reserves
  type DaxPool = { asset: Address; symbol: string; reserveVY: Amount<bigint>; reserveAsset: Amount<bigint> };
  const daxPools: DaxPool[] = [];
  if (numPools > 0n) {
    const poolContracts = [];
    for (let i = 0n; i < numPools; i++) {
      poolContracts.push({ ...daxConfig, functionName: 'getPoolReserves', args: [i] });
    }
    const poolResults = await client.multicall({ contracts: poolContracts, allowFailure: true });
    for (let i = 0; i < poolResults.length; i++) {
      const r = poolResults[i];
      if (r.status === 'success') {
        const [asset, reserveVY, reserveAsset] = r.result as unknown as [Address, bigint, bigint];
        // Find the asset symbol/decimals from our asset list
        const known = assets.find(a => a.address.toLowerCase() === asset.toLowerCase());
        let symbol = known?.symbol;
        let currency = known?.currency;
        if (!known) {
          const tokenInfo = await client.multicall({
            contracts: [
              { abi: abis.ERC20, address: asset, functionName: 'symbol' },
              { abi: abis.ERC20, address: asset, functionName: 'decimals' },
            ],
            allowFailure: true
          });
          symbol = tokenInfo[0].status === 'success' ? tokenInfo[0].result as string : asset.slice(0, 10);
          const decimals = tokenInfo[1].status === 'success' ? tokenInfo[1].result as number : 18;
          currency = { symbol, decimals };
        }
        daxPools.push({
          asset,
          symbol: symbol!,
          reserveVY: new Amount(VY, reserveVY),
          reserveAsset: new Amount(currency!, reserveAsset),
        });
      } else {
        daxErrors.push(`getPoolReserves(${i}): ${(r.error as Error).message ?? 'reverted'}`);
      }
    }
  }

  // --- Staking Router ---
  const vsrErrors: string[] = [];
  const vsrResults = await client.multicall({
    contracts: [
      { ...vsrConfig, functionName: 'totalStakedVY' },
      { ...vsrConfig, functionName: 'totalDaxCredits' },
      { ...vsrConfig, functionName: 'totalUniCredits' },
      { ...vsrConfig, functionName: 'daxIndex' },
      { ...vsrConfig, functionName: 'uniIndex' },
      { ...vsrConfig, functionName: 'depositsPaused' },
      { ...vsrConfig, functionName: 'withdrawalsPaused' },
    ],
    allowFailure: true
  });

  const vsrGet = <T,>(idx: number, label: string, fallback: T): T => {
    const r = vsrResults[idx];
    if (r.status === 'success') return r.result as T;
    vsrErrors.push(`${label}: ${(r.error as Error).message ?? 'reverted'}`);
    return fallback;
  };

  const totalStakedVY = vsrGet(0, 'totalStakedVY', 0n);
  const totalDaxCredits = vsrGet(1, 'totalDaxCredits', 0n);
  const totalUniCredits = vsrGet(2, 'totalUniCredits', 0n);
  const daxIndex = vsrGet(3, 'daxIndex', 0n);
  const uniIndex = vsrGet(4, 'uniIndex', 0n);
  const vsrDepositsPaused = vsrGet(5, 'depositsPaused', false);
  const vsrWithdrawalsPaused = vsrGet(6, 'withdrawalsPaused', false);

  // --- Router Token Holdings ---
  const routerAddress = (addresses as Record<string, Address>)['ValinityStakingRouter'];
  const vdaxAddress = (addresses as Record<string, Address>)['VDAX'];
  const daxAddress = (addresses as Record<string, Address>)['ValinityDAX'];
  const routerBalanceResults = await client.multicall({
    contracts: [
      { abi: abis.ERC20, address: vdaxAddress, functionName: 'balanceOf', args: [routerAddress] },
      { abi: abis.ERC20, address: pairAddress, functionName: 'balanceOf', args: [routerAddress] },
      { ...vyTokenConfig, functionName: 'balanceOf', args: [daxAddress] },
      { ...vyTokenConfig, functionName: 'balanceOf', args: [pairAddress] },
      { abi: abis.ERC20, address: vdaxAddress, functionName: 'totalSupply' },
      { abi: abis.ERC20, address: pairAddress, functionName: 'totalSupply' },
    ],
    allowFailure: true
  });
  const routerVDAX = routerBalanceResults[0].status === 'success' ? routerBalanceResults[0].result as bigint : (() => { vsrErrors.push('VDAX.balanceOf(router): reverted'); return 0n; })();
  const routerUniLP = routerBalanceResults[1].status === 'success' ? routerBalanceResults[1].result as bigint : (() => { vsrErrors.push('UNI-LP.balanceOf(router): reverted'); return 0n; })();
  const vyInDax = routerBalanceResults[2].status === 'success' ? routerBalanceResults[2].result as bigint : (() => { vsrErrors.push('VY.balanceOf(DAX): reverted'); return 0n; })();
  const vyInPair = routerBalanceResults[3].status === 'success' ? routerBalanceResults[3].result as bigint : (() => { vsrErrors.push('VY.balanceOf(pair): reverted'); return 0n; })();
  const vdaxTotalSupply = routerBalanceResults[4].status === 'success' ? routerBalanceResults[4].result as bigint : (() => { vsrErrors.push('VDAX.totalSupply: reverted'); return 0n; })();
  const uniLpTotalSupply = routerBalanceResults[5].status === 'success' ? routerBalanceResults[5].result as bigint : (() => { vsrErrors.push('UNI-LP.totalSupply: reverted'); return 0n; })();
  // Pro-rata share of VY in each pool that belongs to the staking router
  const routerVYInDax = vdaxTotalSupply > 0n ? (vyInDax * routerVDAX) / vdaxTotalSupply : 0n;
  const routerVYInPair = uniLpTotalSupply > 0n ? (vyInPair * routerUniLP) / uniLpTotalSupply : 0n;
  const vyInPools = routerVYInDax + routerVYInPair;

  // --- Buyback ---
  const buybackAddress = (addresses as Record<string, Address>)['ValinityBuybackOfficer'];
  const vytAddress = (addresses as Record<string, Address>)['ValinityYieldTreasury'];
  const [buybackBalanceResult, buybackToVytLogs] = await Promise.all([
    client.multicall({
      contracts: [
        { ...vyTokenConfig, functionName: 'balanceOf', args: [buybackAddress] },
      ],
      allowFailure: true
    }),
    client.getLogs({
      address: vyTokenConfig.address,
      event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
      args: { from: buybackAddress, to: vytAddress },
      fromBlock: 0n,
      toBlock: 'latest',
    }),
  ]);
  const buybackVyBalance = buybackBalanceResult[0].status === 'success'
    ? buybackBalanceResult[0].result as bigint
    : 0n;
  const totalVyBoughtBack = buybackToVytLogs.reduce(
    (sum, log) => sum + (log.args.value ?? 0n),
    0n
  );
  const collateralLTVFs = assets
    .filter(a => a.isCollateral && a.LTVF.value > 0n)
    .map(a => a.LTVF.value);
  const lowestLTVF = collateralLTVFs.length > 0
    ? collateralLTVFs.reduce((min, v) => v < min ? v : min)
    : 0n;
  const buybackBuyingPower = lowestLTVF > 0n
    ? (buybackVyBalance * lowestLTVF) / BigInt(1e18)
    : 0n;

  // --- Yield Optimization (VRYO + VLM) ---
  const yieldErrors: string[] = [];
  const yieldWarnings: string[] = [];

  const vryoBaseResults = await client.multicall({
    contracts: [
      { ...vryoConfig, functionName: 'PAIR_PAXG_USDC' },
      { ...vryoConfig, functionName: 'PAIR_WETH_WBTC' },
      { ...vryoConfig, functionName: 'capVRYO_total' },
      { ...vlmConfig, functionName: 'paused' },
    ],
    allowFailure: true
  });
  const yieldGet = <T,>(idx: number, label: string, fallback: T, list: string[]): T => {
    const r = vryoBaseResults[idx];
    if (r.status === 'success') return r.result as T;
    list.push(`${label}: ${(r.error as Error).message ?? 'reverted'}`);
    return fallback;
  };
  const pairPaxgUsdcKey = yieldGet(0, 'PAIR_PAXG_USDC', '0x0000000000000000000000000000000000000000000000000000000000000000' as `0x${string}`, yieldErrors);
  const pairWethWbtcKey = yieldGet(1, 'PAIR_WETH_WBTC', '0x0000000000000000000000000000000000000000000000000000000000000000' as `0x${string}`, yieldErrors);
  const totalDeployedVY = yieldGet(2, 'capVRYO_total', 0n, yieldErrors);
  const vlmPaused = yieldGet(3, 'paused', false, yieldErrors);

  type PairKey = typeof pairPaxgUsdcKey;
  const pairs: { name: string; key: PairKey }[] = [
    { name: 'PAXG/USDC', key: pairPaxgUsdcKey },
    { name: 'WETH/WBTC', key: pairWethWbtcKey },
  ].filter(p => p.key !== '0x0000000000000000000000000000000000000000000000000000000000000000');

  // Fetch VLM data (pairConfig, activeTokenId, lastRefreshAt, lastRebalanceAt) + VRYO pairPrincipal per pair
  const vlmContracts = pairs.flatMap(p => [
    { ...vlmConfig, functionName: 'pairConfig', args: [p.key] },
    { ...vlmConfig, functionName: 'activeTokenId', args: [p.key] },
    { ...vlmConfig, functionName: 'lastRefreshAt', args: [p.key] },
    { ...vlmConfig, functionName: 'lastRebalanceAt', args: [p.key] },
    { ...vryoConfig, functionName: 'pairPrincipal', args: [p.key] },
  ]);
  const vlmResults = vlmContracts.length > 0
    ? await client.multicall({ contracts: vlmContracts, allowFailure: true })
    : [];

  type PairConfigTuple = readonly [Address, number, number, number, Address, number, number, number, number, Address, bigint, bigint, Address, boolean, number];
  const pairData = pairs.map((p, i) => {
    const off = i * 5;
    const cfg = vlmResults[off]?.status === 'success'
      ? vlmResults[off].result as unknown as PairConfigTuple
      : null;
    if (!cfg) yieldWarnings.push(`pairConfig(${p.name}): not configured`);
    const tokenId = vlmResults[off + 1]?.status === 'success' ? vlmResults[off + 1].result as bigint : 0n;
    const lastRefresh = vlmResults[off + 2]?.status === 'success' ? vlmResults[off + 2].result as bigint : 0n;
    const lastRebalance = vlmResults[off + 3]?.status === 'success' ? vlmResults[off + 3].result as bigint : 0n;
    const principal = vlmResults[off + 4]?.status === 'success' ? vlmResults[off + 4].result as bigint : 0n;
    return { ...p, cfg, tokenId, lastRefresh, lastRebalance, principal };
  });

  // For each pair with a configured pool: read slot0 + active position
  const positionContracts = pairData.flatMap(pd => {
    if (!pd.cfg) return [];
    const poolAddr = pd.cfg[0];
    const c: { abi: typeof abis.UniswapV3Pool | typeof abis.NonfungiblePositionManager; address: Address; functionName: string; args?: readonly unknown[] }[] = [
      { abi: abis.UniswapV3Pool, address: poolAddr, functionName: 'slot0' },
    ];
    if (pd.tokenId > 0n) {
      c.push({ ...npmConfig, functionName: 'positions', args: [pd.tokenId] });
    }
    return c;
  });
  const positionResults = positionContracts.length > 0
    ? await client.multicall({ contracts: positionContracts, allowFailure: true })
    : [];

  type Slot0Tuple = readonly [bigint, number, number, number, number, number, boolean];
  type PositionTuple = readonly [bigint, Address, Address, Address, number, number, number, bigint, bigint, bigint, bigint, bigint];

  // Fees: scan NPM for VLM-owned tokenIds (Transfer to=VLM), then per tokenId sum Collect-DecreaseLiquidity events
  const vlmAddress = (addresses as Record<string, Address>)['ValinityLiquidityManager'];
  const npmAddress = (addresses as Record<string, Address>)['UniswapV3NonfungiblePositionManager'];
  const transferEvent = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)');
  const collectEvent = parseAbiItem('event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1)');
  const decreaseEvent = parseAbiItem('event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)');

  const transferLogs = await client.getLogs({
    address: npmAddress,
    event: transferEvent,
    args: { to: vlmAddress },
    fromBlock: 0n,
    toBlock: 'latest',
  }).catch((e: Error) => {
    yieldWarnings.push(`Transfer scan: ${e.message}`);
    return [] as never[];
  });
  const vlmTokenIds = Array.from(new Set(transferLogs.map(l => l.args.tokenId).filter((id): id is bigint => id !== undefined)));

  // Per-tokenId fee aggregation
  const feesPerTokenId = new Map<bigint, { collect0: bigint; collect1: bigint; dec0: bigint; dec1: bigint }>();
  if (vlmTokenIds.length > 0) {
    const [collectLogs, decreaseLogs] = await Promise.all([
      client.getLogs({
        address: npmAddress,
        event: collectEvent,
        args: { tokenId: vlmTokenIds },
        fromBlock: 0n,
        toBlock: 'latest',
      }).catch(() => [] as never[]),
      client.getLogs({
        address: npmAddress,
        event: decreaseEvent,
        args: { tokenId: vlmTokenIds },
        fromBlock: 0n,
        toBlock: 'latest',
      }).catch(() => [] as never[]),
    ]);
    for (const id of vlmTokenIds) feesPerTokenId.set(id, { collect0: 0n, collect1: 0n, dec0: 0n, dec1: 0n });
    for (const log of collectLogs) {
      const id = log.args.tokenId;
      if (id === undefined) continue;
      const e = feesPerTokenId.get(id)!;
      e.collect0 += log.args.amount0 ?? 0n;
      e.collect1 += log.args.amount1 ?? 0n;
    }
    for (const log of decreaseLogs) {
      const id = log.args.tokenId;
      if (id === undefined) continue;
      const e = feesPerTokenId.get(id)!;
      e.dec0 += log.args.amount0 ?? 0n;
      e.dec1 += log.args.amount1 ?? 0n;
    }
  }

  // Per-tokenId pair attribution: read positions() for every historical tokenId so we can
  // bucket each one's (Collect - DecreaseLiquidity) into the right pair, even after rebalances.
  // Burned NFTs revert; those fees stay unattributed (rare in practice — VLM doesn't burn).
  const tokenIdPair = new Map<bigint, { token0: Address; token1: Address; fee: number }>();
  if (vlmTokenIds.length > 0) {
    const histPosResults = await client.multicall({
      contracts: vlmTokenIds.map(id => ({ ...npmConfig, functionName: 'positions', args: [id] })),
      allowFailure: true
    });
    for (let i = 0; i < vlmTokenIds.length; i++) {
      const r = histPosResults[i];
      if (r.status !== 'success') continue;
      const pos = r.result as unknown as PositionTuple;
      tokenIdPair.set(vlmTokenIds[i], { token0: pos[2], token1: pos[3], fee: pos[4] });
    }
  }

  // Helper: V3 amounts from liquidity given current sqrtPrice and tick range
  const TICK_BASE = 1.0001;
  const Q96 = 2n ** 96n;
  const tickToSqrtPriceX96 = (tick: number): bigint => {
    // sqrt(1.0001^tick) * 2^96 — float is fine for display amounts
    const sqrt = Math.sqrt(Math.pow(TICK_BASE, tick));
    return BigInt(Math.floor(sqrt * Number(Q96)));
  };
  const getAmountsForLiquidity = (
    sqrtP: bigint, sqrtPa: bigint, sqrtPb: bigint, liquidity: bigint
  ): { amount0: bigint; amount1: bigint } => {
    if (sqrtPa > sqrtPb) { const t = sqrtPa; sqrtPa = sqrtPb; sqrtPb = t; }
    if (sqrtP <= sqrtPa) {
      const amount0 = (liquidity * (sqrtPb - sqrtPa) * Q96) / (sqrtPb * sqrtPa);
      return { amount0, amount1: 0n };
    }
    if (sqrtP >= sqrtPb) {
      const amount1 = (liquidity * (sqrtPb - sqrtPa)) / Q96;
      return { amount0: 0n, amount1: 0n + amount1 };
    }
    const amount0 = (liquidity * (sqrtPb - sqrtP) * Q96) / (sqrtPb * sqrtP);
    const amount1 = (liquidity * (sqrtP - sqrtPa)) / Q96;
    return { amount0, amount1 };
  };

  // Resolve per-asset Currency by address (uses already-fetched assets array; falls back to symbol-only)
  const currencyByAddr = (addr: Address): Currency => {
    const known = assets.find(a => a.address.toLowerCase() === addr.toLowerCase());
    if (known) return known.currency;
    return { symbol: addr.slice(0, 6) + '…', decimals: 18 };
  };

  // Build per-pair view models
  let posOff = 0;
  const yieldPairs = pairData.map(pd => {
    if (!pd.cfg) {
      return {
        name: pd.name,
        configured: false as const,
        principal: new Amount(VY, pd.principal),
      };
    }
    const [poolAddr, fee, tickSpacing, rangeBps, token0Addr, , , , , token1Addr] = pd.cfg;
    const cur0 = currencyByAddr(token0Addr);
    const cur1 = currencyByAddr(token1Addr);

    const slot0Result = positionResults[posOff++];
    const positionResult = pd.tokenId > 0n ? positionResults[posOff++] : null;

    const slot0 = slot0Result?.status === 'success' ? slot0Result.result as unknown as Slot0Tuple : null;
    const position = positionResult?.status === 'success' ? positionResult.result as unknown as PositionTuple : null;

    if (!slot0) yieldWarnings.push(`slot0(${pd.name}): pool not initialized`);
    if (pd.tokenId > 0n && !position) yieldWarnings.push(`positions(${pd.name} #${pd.tokenId}): unavailable`);

    const currentTick = slot0 ? slot0[1] : 0;
    const currentSqrtP = slot0 ? slot0[0] : 0n;
    const tickLower = position ? position[5] : 0;
    const tickUpper = position ? position[6] : 0;
    const liquidity = position ? position[7] : 0n;
    const tokensOwed0 = position ? position[10] : 0n;
    const tokensOwed1 = position ? position[11] : 0n;

    // Amount math
    const sqrtPa = position ? tickToSqrtPriceX96(tickLower) : 0n;
    const sqrtPb = position ? tickToSqrtPriceX96(tickUpper) : 0n;
    const { amount0: principal0, amount1: principal1 } = (position && slot0)
      ? getAmountsForLiquidity(currentSqrtP, sqrtPa, sqrtPb, liquidity)
      : { amount0: 0n, amount1: 0n };

    // Band position % (tick-space)
    const midTick = position ? (tickLower + tickUpper) / 2 : 0;
    const halfRange = position ? (tickUpper - tickLower) / 2 : 0;
    const positionPct = position && halfRange > 0
      ? ((currentTick - midTick) / halfRange) * 100
      : 0;
    const inRange = position ? (currentTick >= tickLower && currentTick <= tickUpper) : false;

    // Price labels (token1 per token0), decimal-adjusted
    const dec0 = cur0.decimals ?? 18;
    const dec1 = cur1.decimals ?? 18;
    const tickToPrice = (tick: number) => Math.pow(TICK_BASE, tick) * Math.pow(10, dec0 - dec1);
    const priceLower = position ? tickToPrice(tickLower) : 0;
    const priceUpper = position ? tickToPrice(tickUpper) : 0;
    const priceCurrent = slot0 ? tickToPrice(currentTick) : 0;

    // Cumulative fees for this pair: sum (Collect - DecreaseLiquidity) across ALL historical tokenIds
    // VLM has owned for this pool (matched by token0/token1/fee), plus active position's tokensOwed.
    // This persists across rebalances — the number is monotonic per-pair.
    let cumFees0 = 0n;
    let cumFees1 = 0n;
    let attributedTokenIds = 0;
    let unattributedTokenIds = 0;
    for (const [tid, fees] of feesPerTokenId.entries()) {
      const meta = tokenIdPair.get(tid);
      if (!meta) { unattributedTokenIds++; continue; }
      const matches =
        meta.token0.toLowerCase() === token0Addr.toLowerCase() &&
        meta.token1.toLowerCase() === token1Addr.toLowerCase() &&
        meta.fee === fee;
      if (!matches) continue;
      attributedTokenIds++;
      cumFees0 += fees.collect0 - fees.dec0;
      cumFees1 += fees.collect1 - fees.dec1;
    }
    // Add live unclaimed (only on the active position; closed positions have tokensOwed=0)
    cumFees0 += tokensOwed0;
    cumFees1 += tokensOwed1;

    return {
      name: pd.name,
      configured: true as const,
      poolAddress: poolAddr,
      fee,
      tickSpacing,
      rangeBps,
      tokenId: pd.tokenId,
      lastRefresh: pd.lastRefresh,
      lastRebalance: pd.lastRebalance,
      hasPosition: pd.tokenId > 0n && !!position,
      tickLower,
      tickUpper,
      currentTick,
      midTick,
      positionPct,
      inRange,
      liquidity,
      principal: new Amount(VY, pd.principal),
      principal0: new Amount(cur0, principal0),
      principal1: new Amount(cur1, principal1),
      unclaimedFees0: new Amount(cur0, tokensOwed0),
      unclaimedFees1: new Amount(cur1, tokensOwed1),
      cumulativeFees0: new Amount(cur0, cumFees0),
      cumulativeFees1: new Amount(cur1, cumFees1),
      historicalPositions: attributedTokenIds,
      unattributedTokenIds,
      priceLower,
      priceUpper,
      priceCurrent,
      token0: cur0,
      token1: cur1,
    };
  });

  const stakedVYPctDeployed = vyInPools > 0n
    ? Number((totalDeployedVY * 10000n) / vyInPools) / 100
    : 0;

  // --- Cap Health (caps + deployed VY ≈ circulating) ---
  // The lag exists because the VY token batches collected fees and only flushes
  // them to the VCO every `transfersPerProcess` transfers. Until the next flush,
  // those fees sit in the token contract as `accumulatedFees`. So the lag must
  // exactly equal the token's accumulated-fees balance.
  const capCirculatingLag = (totalCaps + totalDeployedVY) - totalUncollateralized;
  const capHealthy = capCirculatingLag === vyAccumulatedFees;
  if (!capHealthy) {
    overviewErrors.push(
      `Cap-circulating mismatch: lag = ${(Number(capCirculatingLag) / 1e18).toFixed(2)} VY, ` +
      `VY token accumulatedFees = ${(Number(vyAccumulatedFees) / 1e18).toFixed(2)} VY (expected exact match)`
    );
  }

  // --- Round Floor (USD per VY backing across VRT collateral + LP holdings) ---
  // Numerator: Σ USD value of VRT collateral + Σ USD value of LP-pair holdings (incl. unclaimed fees)
  // Denominator: Σ caps in VCO + Total VY Deployed
  const priceFor = (addr: Address): bigint => {
    const known = assets.find(a => a.address.toLowerCase() === addr.toLowerCase());
    if (known?.isCollateral) return known.spotPrice.value as bigint;
    return 10n ** 18n; // USDC / stablecoins → $1
  };
  const decimalsFor = (addr: Address): number => {
    const known = assets.find(a => a.address.toLowerCase() === addr.toLowerCase());
    return known?.currency.decimals ?? 18;
  };
  const toUsd1e18 = (rawAmount: bigint, decimals: number, priceUsd1e18: bigint): bigint => {
    const scale = 10n ** BigInt(18 - decimals);
    return (rawAmount * scale * priceUsd1e18) / 10n ** 18n;
  };

  let vrtCollateralUSD = 0n;
  for (const a of assets) {
    if (!a.isCollateral) continue;
    vrtCollateralUSD += a.reserveBalanceUSD.value as bigint;
  }

  let lpHoldingsUSD = 0n;
  for (const pd of pairData) {
    if (!pd.cfg) continue;
    const [, , , , token0Addr, , , , , token1Addr] = pd.cfg;
    const yp = yieldPairs.find(y => y.configured && y.name === pd.name);
    if (!yp || !yp.configured || !yp.hasPosition) continue;
    const p0 = (yp.principal0.value as bigint) + (yp.unclaimedFees0.value as bigint);
    const p1 = (yp.principal1.value as bigint) + (yp.unclaimedFees1.value as bigint);
    lpHoldingsUSD += toUsd1e18(p0, decimalsFor(token0Addr), priceFor(token0Addr));
    lpHoldingsUSD += toUsd1e18(p1, decimalsFor(token1Addr), priceFor(token1Addr));
  }

  const roundFloorDenominator = totalCaps + totalDeployedVY;
  const roundFloor: Amount<bigint> | 'Unavailable' = roundFloorDenominator > 0n
    ? new Amount(USD, ((vrtCollateralUSD + lpHoldingsUSD) * 10n ** 18n) / roundFloorDenominator)
    : 'Unavailable' as never;

  return {
    overview: {
      'VY Total Supply': new Amount(VY, vyTotalSupply),
      'Circulating': new Amount(VY, totalUncollateralized),
      'Total Caps': new Amount(VY, totalCaps),
      'Cap-Circ Lag': new Amount(VY, capCirculatingLag),
      'VY Token Accumulated Fees': new Amount(VY, vyAccumulatedFees),
      'Matches VY Token Fee Lag': capHealthy ? '✅ OK' : '⚠ Mismatch',
      TVL: new Amount(USD, tvl),
      MTP: mtp,
      'Round Floor': roundFloor
    },
    overviewErrors,
    overviewWarnings,
    hasConfigWarnings,
    balanceMap,
    pool: {
      'VY Price': vyReserve > 0n ? new Amount(USD, (usdcReserve * 10n**30n) / vyReserve) : 'No liquidity',
      'VY Reserve': new Amount(VY, vyReserve),
      'USDC Reserve': new Amount(USDC, usdcReserve),
    },
    assets: assets.map(asset => omit(asset, ['currency'])),
    dax: {
      overview: {
        'Num Pools': String(numPools),
        'Total VY Reserves': new Amount(VY, totalVYReserves),
        'Deposits Paused': daxDepositsPaused,
        'Withdrawals Paused': daxWithdrawalsPaused,
        'Swaps Paused': daxSwapsPaused,
      },
      pools: daxPools,
      errors: daxErrors,
    },
    stakingRouter: {
      overview: {
        'VY in Pools': new Amount(VY, vyInPools),
        'Total Staked VY': new Amount(VY, totalStakedVY),
        'Total DAX Credits': new Amount({ symbol: '', decimals: 18 }, totalDaxCredits),
        'Total UNI Credits': new Amount({ symbol: '', decimals: 18 }, totalUniCredits),
        'DAX Index': new Amount({ symbol: '×', decimals: 18 }, daxIndex),
        'UNI Index': new Amount({ symbol: '×', decimals: 18 }, uniIndex),
        'Deposits Paused': vsrDepositsPaused,
        'Withdrawals Paused': vsrWithdrawalsPaused,
      },
      tokenHoldings: {
        'VDAX Balance': new Amount(VDAX, routerVDAX),
        'UNI-LP Balance': new Amount(UNI_LP, routerUniLP),
      },
      errors: vsrErrors,
    },
    buyback: {
      'VY Bought Back': new Amount(VY, totalVyBoughtBack),
      'VY Holdings': new Amount(VY, buybackVyBalance),
      'Buying Power': new Amount(USD, buybackBuyingPower),
    },
    yieldOptimization: {
      overview: {
        'Total VY Deployed': new Amount(VY, totalDeployedVY),
        '% of Staked VY Deployed': `${stakedVYPctDeployed.toFixed(2)}%`,
        'Active Positions': String(yieldPairs.filter(p => p.configured && p.hasPosition).length),
        'VLM Paused': vlmPaused,
      },
      pairs: yieldPairs,
      errors: yieldErrors,
      warnings: yieldWarnings,
    },
  };
};

type MonitorData = Awaited<ReturnType<typeof fetchData>>;

export default function Mainnet() {
  const [data, setData] = useState<MonitorData | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    const load = () => {
      fetchData()
        .then(d => { if (active) setData(d); })
        .catch(e => { if (active) setError(e.message); });
    };
    load();
    const interval = setInterval(load, 30_000);
    return () => { active = false; clearInterval(interval); };
  }, []);

  if (error) return <p style={{ textAlign: 'center', color: 'red' }}>Error: {error}</p>;
  if (!data) return <p style={{ textAlign: 'center' }}>Loading...</p>;
  return <Content data={data} />;
}

function Content({ data }: { data: MonitorData }) {

  return (
    <div className="monitor">
      <div>
        <h2>Overview</h2>
        <div className={`box ${data.overviewErrors.length > 0 ? 'box--error' : data.overviewWarnings.length > 0 ? 'box--warning' : ''}`}>
          {data.overviewErrors.length > 0 && (
            <div className="error-list">
              {data.overviewErrors.map((err, i) => (
                <div key={i} className="error-item">✗ {err}</div>
              ))}
            </div>
          )}
          {data.overviewWarnings.length > 0 && (
            <div className="warning-list">
              {data.overviewWarnings.map((warn, i) => (
                <div key={i} className="warning-item">⚠ {warn}</div>
              ))}
            </div>
          )}
          {renderValues(data.overview)}
        </div>
      </div>

      <div>
        <h2>Balances</h2>
        <div className="box">
          <BalanceTable data={data.balanceMap} />
        </div>
      </div>

      <div>
        <h2>Buyback</h2>
        <div className="box">
          {renderValues(data.buyback)}
        </div>
      </div>

      <div>
        <h2>Pool (VY/USDC)</h2>
        <div className="box">
          {renderValues(data.pool)}
        </div>
      </div>

      <div>
        <h2>Valinity Arbitrage Exchange</h2>
        <div className={`box ${data.dax.errors.length > 0 ? 'box--error' : ''}`}>
          {data.dax.errors.length > 0 && (
            <div className="error-list">
              {data.dax.errors.map((err, i) => (
                <div key={i} className="error-item">✗ {err}</div>
              ))}
            </div>
          )}
          {renderValues(data.dax.overview)}
          {data.dax.pools.length > 0 && (() => {
            const pools = [...data.dax.pools];
            const nvIdx = pools.findIndex(p => /nv/i.test(p.symbol));
            const linkIdx = pools.findIndex(p => /link/i.test(p.symbol));
            if (nvIdx !== -1 && linkIdx !== -1) {
              [pools[nvIdx], pools[linkIdx]] = [pools[linkIdx], pools[nvIdx]];
            }
            return (
            <>
              <h3 style={{ marginTop: '12px' }}>Pools</h3>
              <div style={{
                display: 'grid',
                gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)',
                gap: '5px 8px',
                alignItems: 'start',
                marginTop: '8px',
              }}>
                {pools.map((pool) => (
                  <div key={pool.symbol} className="box" style={{ marginBottom: 0 }}>
                    <h4>{pool.symbol}</h4>
                    {renderValues({
                      [`${pool.symbol} Token`]: pool.asset,
                      'VY Reserve': pool.reserveVY,
                      [`${pool.symbol} Reserve`]: pool.reserveAsset,
                    })}
                  </div>
                ))}
              </div>
            </>
            );
          })()}
        </div>
      </div>

      <div>
        <h2>Staking Router</h2>
        <div className={`box ${data.stakingRouter.errors.length > 0 ? 'box--error' : ''}`}>
          {data.stakingRouter.errors.length > 0 && (
            <div className="error-list">
              {data.stakingRouter.errors.map((err, i) => (
                <div key={i} className="error-item">✗ {err}</div>
              ))}
            </div>
          )}
          {renderValues(data.stakingRouter.overview, undefined, {
            'Total DAX Credits': 'Sum of all stakers\' DAX credit shares in the router',
            'Total UNI Credits': 'Sum of all stakers\' UNI-LP credit shares in the router',
            'DAX Index': 'Conversion ratio from DAX credits to VDAX tokens (grows over time with yield)',
            'UNI Index': 'Conversion ratio from UNI credits to UNI-LP tokens (grows over time with yield)',
            'Deposits Paused': 'Whether new staking deposits are currently accepted',
            'Withdrawals Paused': 'Whether staking withdrawals are currently allowed',
          })}
          <h3 style={{ marginTop: '12px' }}>Token Holdings</h3>
          {renderValues(data.stakingRouter.tokenHoldings, undefined, {
            'VDAX Balance': 'Actual VDAX token balance held by the router contract',
            'UNI-LP Balance': 'Actual UNI-LP token balance held by the router contract',
          })}
        </div>
      </div>

      <div>
        <h2>Yield Optimization (VRYO + VLM)</h2>
        <div className={`box ${data.yieldOptimization.errors.length > 0 ? 'box--error' : data.yieldOptimization.warnings.length > 0 ? 'box--warning' : ''}`}>
          {data.yieldOptimization.errors.length > 0 && (
            <div className="error-list">
              {data.yieldOptimization.errors.map((err, i) => (
                <div key={i} className="error-item">✗ {err}</div>
              ))}
            </div>
          )}
          {data.yieldOptimization.warnings.length > 0 && (
            <div className="warning-list">
              {data.yieldOptimization.warnings.map((warn, i) => (
                <div key={i} className="warning-item">⚠ {warn}</div>
              ))}
            </div>
          )}
          {renderValues(data.yieldOptimization.overview, undefined, {
            'Total VY Deployed': 'VY locked across all VRYO-managed V3 LP positions (Σ pairPrincipal)',
            '% of Staked VY Deployed': 'Share of total staked VY currently working in V3 pairs',
            'Active Positions': 'Number of pairs with a live tokenId on the NonfungiblePositionManager',
            'VLM Paused': 'When true, VLM cannot rebalance/refresh',
          })}

          {data.yieldOptimization.pairs.length > 0 && (
            <>
              <h3 style={{ marginTop: '12px' }}>Pairs</h3>
              <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)', gap: '8px', alignItems: 'start' }}>
                {data.yieldOptimization.pairs.map(pair => (
                  <div key={pair.name} style={{ minWidth: 0 }}>
                    <PairCard pair={pair} />
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </div>

      <div>
        <h2>Assets</h2>
        {data.assets.filter(a => a.isCollateral).map(({ symbol, errors, warnings, isCollateral, notCollateral, ...values }) => (
          <div key={symbol} className={`box ${errors && errors.length > 0 ? 'box--error' : warnings && warnings.length > 0 ? 'box--warning' : ''}`}>
            <h3>
              {symbol}
              {notCollateral && <span className="info-badge"> (stablecoin — not collateral)</span>}
              {errors && errors.length > 0 && (
                <span className="error-badge">⚠ {errors.length} error{errors.length > 1 ? 's' : ''}</span>
              )}
              {warnings && warnings.length > 0 && !errors?.length && (
                <span className="warning-badge">⚠ {warnings.length} warning{warnings.length > 1 ? 's' : ''}</span>
              )}
            </h3>
            {errors && errors.length > 0 && (
              <div className="error-list">
                {errors.map((err, i) => (
                  <div key={i} className="error-item">✗ {err}</div>
                ))}
              </div>
            )}
            {warnings && warnings.length > 0 && (
              <div className="warning-list">
                {warnings.map((warn, i) => (
                  <div key={i} className="warning-item">⚠ {warn}</div>
                ))}
              </div>
            )}
            {renderValues(values)}
          </div>
        ))}
      </div>

      {data.hasConfigWarnings && (
        <div>
          <h2>Configuration Status</h2>
          <div className="box box--warning">
            <p>Some contract calls are reverting. On-chain configuration needed:</p>
            <ul style={{ margin: '8px 0', paddingLeft: '20px' }}>
              <li>Configure fee tiers in AcquisitionOfficer for WETH, WBTC, PAXG</li>
              <li>Provide liquidity to VY/USDC pool on Uniswap V2</li>
              <li>Configure Uniswap V3 pools for USDC/WETH, USDC/WBTC, USDC/PAXG pairs</li>
              <li>Register assets in CapOfficer (setAssetCap)</li>
            </ul>
          </div>
        </div>
      )}
    </div>
  )
}

function renderValues(
  data: object,
  transform?: (key: string, value: unknown) => unknown,
  tooltips?: Record<string, string>
): JSX.Element {
  return (
    <table>
      <tbody>
        {Object.entries(data).map(([key, value]) => (
          <tr key={key}>
            <td >
              <strong title={tooltips?.[key]}  style={tooltips?.[key] ? { cursor: 'help', borderBottom: '1px dotted #888' } : undefined}>{startCase(key)}</strong>
            </td>
            <td>
              <Value>{transform ? transform(key, value) : value}</Value>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

type YieldPair = MonitorData['yieldOptimization']['pairs'][number];

const formatPrice = (p: number) => {
  if (!isFinite(p) || p === 0) return '—';
  if (p >= 1000) return p.toLocaleString('en', { maximumFractionDigits: 2 });
  if (p >= 1) return p.toFixed(4);
  return p.toPrecision(4);
};

const formatTimestamp = (ts: bigint) => {
  if (ts === 0n) return '—';
  return new Date(Number(ts) * 1000).toISOString().replace('T', ' ').slice(0, 19) + ' UTC';
};

const PairCard = ({ pair }: { pair: YieldPair }) => {
  if (!pair.configured) {
    return (
      <div className="box box--warning" style={{ marginTop: '8px' }}>
        <h4>{pair.name}</h4>
        <p style={{ margin: 0, fontSize: '0.75rem', color: '#aaa' }}>
          Pair not configured in VLM
        </p>
        {renderValues({ 'VY Deployed (principal)': pair.principal })}
      </div>
    );
  }

  const sym0 = pair.token0.symbol;
  const sym1 = pair.token1.symbol;

  const stats = {
    'VY Deployed': pair.principal,
    'Pool Address': pair.poolAddress,
    'Fee Tier': `${(pair.fee / 10000).toFixed(2)}%`,
    'Range Width': `${(pair.rangeBps / 100).toFixed(2)}% (${pair.rangeBps} bps)`,
    'Token ID': pair.tokenId > 0n ? String(pair.tokenId) : '— (no active position)',
    'In Range': pair.inRange ? 'Yes' : 'No',
    'Last Refresh': formatTimestamp(pair.lastRefresh),
    'Last Rebalance': formatTimestamp(pair.lastRebalance),
  };

  const positionStats = pair.hasPosition ? {
    [`${sym0} in position`]: pair.principal0,
    [`${sym1} in position`]: pair.principal1,
    'Liquidity': pair.liquidity.toString(),
    'Tick Range': `${pair.tickLower} → ${pair.tickUpper} (current: ${pair.currentTick})`,
    'Price Range': `${formatPrice(pair.priceLower)} – ${formatPrice(pair.priceUpper)} ${sym1}/${sym0}`,
    'Current Price': `${formatPrice(pair.priceCurrent)} ${sym1}/${sym0}`,
  } : {};

  const yieldStats = pair.hasPosition ? {
    [`Cumulative Fees (${sym0})`]: pair.cumulativeFees0,
    [`Cumulative Fees (${sym1})`]: pair.cumulativeFees1,
    [`Unclaimed Fees (${sym0})`]: pair.unclaimedFees0,
    [`Unclaimed Fees (${sym1})`]: pair.unclaimedFees1,
    'Positions Counted': `${pair.historicalPositions} (lifetime, includes closed)`,
    ...(pair.unattributedTokenIds > 0 ? { 'Unattributed (burned NFTs)': String(pair.unattributedTokenIds) } : {}),
  } : {};

  return (
    <div className="box" style={{ marginTop: '8px' }}>
      <h4>
        {pair.name}
        {pair.hasPosition && (
          <span style={{
            marginLeft: '0.5rem',
            padding: '0.15rem 0.4rem',
            fontSize: '0.7rem',
            fontWeight: 'bold',
            color: '#fff',
            background: pair.inRange ? '#2ecc71' : '#e74c3c',
            borderRadius: '0.25rem',
            verticalAlign: 'middle'
          }}>
            {pair.inRange ? 'IN RANGE' : 'OUT OF RANGE'}
          </span>
        )}
      </h4>

      {renderValues(stats)}

      {pair.hasPosition && (
        <>
          <h4 style={{ marginTop: '12px', borderBottom: '1px solid #444', paddingBottom: '4px' }}>Position</h4>
          {renderValues(positionStats)}

          <h4 style={{ marginTop: '12px', borderBottom: '1px solid #444', paddingBottom: '4px' }}>Band Indicator</h4>
          <div style={{ marginTop: '8px' }}>
            <BandIndicator
              positionPct={pair.positionPct}
              bandWidthPct={pair.rangeBps / 100}
              upperLabel={`upper · ${formatPrice(pair.priceUpper)}`}
              midLabel={`mid · ${formatPrice((pair.priceLower + pair.priceUpper) / 2)}`}
              lowerLabel={`lower · ${formatPrice(pair.priceLower)}`}
              currentLabel={`now · ${formatPrice(pair.priceCurrent)}`}
            />
          </div>

          <h4 style={{ marginTop: '12px', borderBottom: '1px solid #444', paddingBottom: '4px' }}>Yield</h4>
          {renderValues(yieldStats)}
        </>
      )}
    </div>
  );
};

const BalanceTable = ({ data }: {
  data: { [key: string]: Amount<bigint>[] }
}) => {
  const totals: Amount<bigint>[] = [];

  for (const amounts of Object.values(data)) {
    amounts.forEach((amount, i) => {
      const sum = totals[i] ?? new Amount(amount.currency, 0n);
      sum.value += amount.value;
      totals[i] = sum;
    });
  }

  return (
    <table>
      <thead>
        <tr>
          <th>Holder</th>
          {Object.values(data)[0].map(amount => (
            <th key={amount.currency.symbol}>{amount.currency.symbol}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {Object.entries(data).map(([holder, amounts]) => (
          <tr key={holder}>
            <td>
              {CONTRACT_ACRONYMS[holder as keyof typeof CONTRACT_ACRONYMS] ?? holder}
            </td>
            {amounts.map(amount => (
              <td key={amount.currency.symbol}>
                <Value includeSybmol={false}>{amount}</Value>
              </td>
            ))}
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <td>Total</td>
          {totals.map(amount => (
            <td key={amount.currency.symbol}>
              <Value includeSybmol={false}>{amount}</Value>
            </td>
          ))}
        </tr>
      </tfoot>
    </table>
  )
}

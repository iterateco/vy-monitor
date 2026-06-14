import flatten from 'lodash/flatten';
import omit from 'lodash/omit';
import startCase from 'lodash/startCase';
import { useEffect, useState, type JSX } from 'react';
import { createPublicClient, http, parseAbiItem, type Address } from 'viem';
import { mainnet } from 'viem/chains';
import { Value } from '../components/core';
import { CONTRACT_ACRONYMS, MAINNET_RPC_URL, MAINNET_API_URL } from '../config';
import { Amount, USD, VY, VDAX, UNI_LP } from '../models';
import type { Currency } from '../models';
import networks from '../networks';


/**
 * Assets soportados como colateral (LoanOfficer, CapOfficer, AcquisitionOfficer).
 * USDC NO es colateral — llamar getAssetView(USDC) causa UnsupportedAsset().
 */
const COLLATERAL_SYMBOLS = new Set(['WETH', 'WBTC', 'PAXG']);

/**
 * Cap Health dust tolerance, in VY wei (1 VY = 1e18 wei).
 * Total caps should equal circulating supply exactly, but integer-division
 * truncation in cap accounting can leave a few wei of rounding dust (each cap
 * mutation floors down by ≤1 wei). A strict `=== 0n` check flags that harmless
 * dust as a 🔴 mismatch. We allow up to this many wei of |lag| before alerting.
 *
 * Kept deliberately tiny for safety: 1e3 wei = 1e-15 VY — 15 orders of magnitude
 * below 1 VY, so any economically meaningful mismatch (sub-VY or larger) still
 * trips the alert, while ~1000 single-wei truncations are absorbed.
 */
const CAP_HEALTH_DUST_WEI = 1_000n;

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

    // Collateral-only calls: spotPrice, assetView, assetMetrics, + VRYO per-asset
    // allocator state (folded into the asset card; VRYO has no standalone section).
    const collateralContracts = isCollateral ? [
      { ...vaoConfig, functionName: 'getAssetTwapPrice', args: [assetAddr] },
      { ...vloConfig, functionName: 'getAssetView', args: [assetAddr] },
      { ...vcoConfig, functionName: 'getAssetMetrics', args: [assetAddr] },
      { ...vcoConfig, functionName: 'getAssetCollateralized', args: [assetAddr] },
      { ...vcoConfig, functionName: 'getAssetCap', args: [assetAddr] },
      { ...vryoConfig, functionName: 'capVRYO', args: [assetAddr] },
      { ...vryoConfig, functionName: 'deployedAsset', args: [assetAddr] },
      { ...vryoConfig, functionName: 'assetDeployRatioBps', args: [assetAddr] },
      { ...vryoConfig, functionName: 'getGlobalCap', args: [assetAddr] },
      { ...vryoConfig, functionName: 'getInternalLTV', args: [assetAddr] },
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
      const warnLabels = ['getAssetTwapPrice', 'getAssetMetrics', 'capVRYO', 'deployedAsset', 'assetDeployRatioBps', 'getGlobalCap', 'getInternalLTV'];
      if (warnLabels.includes(label)) {
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
        // VRYO per-asset allocator fields (zero for non-collateral / unmanaged)
        targetDeployRatio: '—',
        deployedRatio: '—',
        globalCap: new Amount(VY, 0n),
        globalLTV: 0n,
        globalLTVF: new Amount(USD, 0n),
        vryoCap: new Amount(VY, 0n),
        vryoLTV: 0n,
        vryoLTVF: new Amount(USD, 0n),
        deployedBalance: new Amount(currency, 0n),
        deployedBalanceUSD: new Amount(USD, 0n),
        notCollateral: true
      }
    }

    // Collateral asset — parse remaining results (indices 2..6)
    const spotPrice = get(2, 'getAssetTwapPrice', 0n);
    const assetView = results[3].status === 'success'
      ? results[3].result as unknown as { ltv: bigint; reserveBalance: bigint; totalLoaned: bigint }
      : (() => { errors.push(`getAssetView: ${(results[3].error as Error).message ?? 'reverted'}`); return { ltv: 0n, reserveBalance: 0n, totalLoaned: 0n }; })();
    const { reserveBalance, totalLoaned } = assetView;
    const defaultMetrics = { totalReserve: 0n, collateralCap: 0n, ltvRatio: 0n, ltvF: 0n, utilized: 0n, available: 0n };
    const metrics = results[4].status === 'success'
      ? results[4].result as unknown as typeof defaultMetrics
      : (() => { warnings.push(`getAssetMetrics: ${(results[4].error as Error).message ?? 'reverted'}`); return defaultMetrics; })();
    const { ltvRatio: ltv, ltvF: ltvf, collateralCap: metricsCap, utilized } = metrics;
    // getAssetMetrics reverts when the VAO TWAP oracle is stale (e.g. PAXG's thin
    // pool reverts "OLD"), which would zero collateralCap and trip a false
    // cap-circulating mismatch. Fall back to the raw getAssetCap storage read,
    // which never touches the oracle, so the cap total stays correct.
    const rawCap = get(6, 'getAssetCap', 0n);
    const cap = results[4].status === 'success' ? metricsCap : rawCap;
    const collateralized = get(5, 'getAssetCollateralized', utilized);

    // VRYO per-asset allocator state (idx 7..11).
    const vryoCap = get(7, 'capVRYO', 0n);
    const deployedBalance = get(8, 'deployedAsset', 0n);
    const targetRatioBps = Number(get(9, 'assetDeployRatioBps', 0));
    const globalCap = get(10, 'getGlobalCap', 0n);   // = vryoCap + VCO cap
    const vryoLTV = get(11, 'getInternalLTV', 0n);   // deployedAsset ÷ vryoCap (asset18-per-VY, WAD)

    const scaleFactor = BigInt(10) ** BigInt(18 - decimals);
    const toUSD = (native: bigint) => spotPrice ? ((native * scaleFactor) * spotPrice) / BigInt(1e18) : 0n;
    const toLTVF = (ltvWad: bigint) => (ltvWad * spotPrice) / BigInt(1e18); // asset-per-VY × USD/asset = USD/VY

    // Deployed ratio: actual deployed share of the global cap (capVRYO ÷ globalCap).
    const deployedRatioPct = globalCap > 0n ? Number((vryoCap * 10000n) / globalCap) / 100 : 0;
    // Global LTV: (VRYO-deployed asset + VRT reserve asset) ÷ global cap, asset18-per-VY (WAD).
    const globalLTV = globalCap > 0n
      ? (((deployedBalance + reserveBalance) * scaleFactor) * BigInt(1e18)) / globalCap
      : 0n;

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
      reserveBalanceUSD: new Amount(USD, toUSD(reserveBalance)),
      totalLoaned: new Amount(currency, totalLoaned),
      totalLoanedUSD: new Amount(USD, toUSD(totalLoaned)),
      cap: new Amount(VY, cap),
      capFloor: new Amount(VY, effectiveFloor),
      collateralized: new Amount(VY, collateralized),
      // VRYO per-asset allocator fields
      targetDeployRatio: `${(targetRatioBps / 100).toFixed(2)}%`,
      deployedRatio: `${deployedRatioPct.toFixed(2)}%`,
      globalCap: new Amount(VY, globalCap),
      globalLTV,
      globalLTVF: new Amount(USD, toLTVF(globalLTV)),
      vryoCap: new Amount(VY, vryoCap),
      vryoLTV,
      vryoLTVF: new Amount(USD, toLTVF(vryoLTV)),
      deployedBalance: new Amount(currency, deployedBalance),
      deployedBalanceUSD: new Amount(USD, toUSD(deployedBalance)),
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

  const [overviewResults, mtpResponse, stakingStatsResponse] = await Promise.all([
    client.multicall({
      contracts: [
        { ...vyTokenConfig, functionName: 'totalSupply' },
        { ...pairConfig, functionName: 'getReserves' },
        { ...pairConfig, functionName: 'token0' },
      ],
      allowFailure: true
    }),
    fetch(`${MAINNET_API_URL}/market-data?count=1`).then(r => r.json()).catch(() => null),
    fetch(`${MAINNET_API_URL}/staking/stats`).then(r => r.json()).catch(() => null),
  ]);

  const vyTotalSupply = overviewResults[0].status === 'success'
    ? overviewResults[0].result as bigint
    : (() => { overviewErrors.push(`totalSupply: ${(overviewResults[0].error as Error).message ?? 'reverted'}`); return 0n; })();
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
  ] as const;

  const tokenHolderReads = tokenHolders.map(name => {
    return [
      {
        ...vyTokenConfig,
        functionName: 'balanceOf',
        args: [(addresses as Record<string, Address>)[name]]
      }
    ]
  });

  const balancesRaw = await client.multicall({
    contracts: flatten(tokenHolderReads),
    allowFailure: true
  });

  const balanceMap = {} as { [K in typeof tokenHolders[number]]: Amount<bigint>[] }
  const balancesResultBatchLen = 1;

  for (let i = 0; i < tokenHolders.length; i++) {
    const holder = tokenHolders[i];
    const batch = balancesRaw.slice(
      i * balancesResultBatchLen,
      balancesResultBatchLen + i * balancesResultBatchLen
    );
    balanceMap[holder] = batch.map((r) => {
      if (r.status === 'success') return new Amount(VY, r.result as bigint);
      overviewErrors.push(`balanceOf(${holder}, VY): reverted`);
      return new Amount(VY, 0n);
    })
  }

  const totalUncollateralized = (
    vyTotalSupply -
    balanceMap.ValinityYieldTreasury[0].value -
    balanceMap.ValinityReserveTreasury[0].value
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
  type DaxPool = { asset: Address; symbol: string; reserveVY: Amount<bigint>; reserveAsset: Amount<bigint>; reserveAssetUSD: Amount<bigint> };
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
        // For known collateral assets, use TWAP spot price.
        // For unknown assets (e.g. TSLA, NVDA, LINK), the DAX is arbitraged against Uniswap,
        // so asset reserve value ≈ VY reserve value. Derive from the Uniswap VY/USDC price.
        let reserveAssetUSD: Amount<bigint>;
        if (known) {
          const spotPriceRaw = known.spotPrice.value as bigint;
          const assetDecimals = currency!.decimals ?? 18;
          const scaleFactor = BigInt(10) ** BigInt(18 - assetDecimals);
          reserveAssetUSD = new Amount(USD, spotPriceRaw > 0n
            ? (reserveAsset * scaleFactor * spotPriceRaw) / BigInt(1e18)
            : 0n);
        } else {
          // reserveVY_dax * usdcReserve_uni * 10^12 / vyReserve_uni gives 18-decimal USD
          reserveAssetUSD = new Amount(USD, vyReserve > 0n
            ? (reserveVY * usdcReserve * BigInt(10 ** 12)) / vyReserve
            : 0n);
        }
        daxPools.push({
          asset,
          symbol: symbol!,
          reserveVY: new Amount(VY, reserveVY),
          reserveAsset: new Amount(currency!, reserveAsset),
          reserveAssetUSD,
        });
      } else {
        daxErrors.push(`getPoolReserves(${i}): ${(r.error as Error).message ?? 'reverted'}`);
      }
    }
  }

  // --- VDAO DAX (second arbitrage exchange contract) ---
  // Unlike the original ValinityDAX (VY/asset pools), the VDAO DAX pairs a VDAO
  // token (e.g. VGC, launched on top of VY) with an external asset (e.g. WBTC).
  // getPoolReserves returns BOTH token addresses + reserves, and there is no
  // VY-denominated total accessor.
  const vdaoDaxConfig = getContractConfig('ValinityVdaoDAX', (addresses as Record<string, Address>)['VDAODAX']);
  const vdaoDaxErrors: string[] = [];
  const vdaoDaxBaseResults = await client.multicall({
    contracts: [
      { ...vdaoDaxConfig, functionName: 'getNumPools' },
      { ...vdaoDaxConfig, functionName: 'swapsPaused' },
    ],
    allowFailure: true
  });

  const vdaoDaxGet = <T,>(idx: number, label: string, fallback: T): T => {
    const r = vdaoDaxBaseResults[idx];
    if (r.status === 'success') return r.result as T;
    vdaoDaxErrors.push(`${label}: ${(r.error as Error).message ?? 'reverted'}`);
    return fallback;
  };

  const vdaoNumPools = vdaoDaxGet(0, 'getNumPools', 0n);
  const vdaoDaxSwapsPaused = vdaoDaxGet(1, 'swapsPaused', false);

  const resolveToken = async (addr: Address): Promise<{ symbol: string; currency: Currency }> => {
    const known = assets.find(a => a.address.toLowerCase() === addr.toLowerCase());
    if (known) return { symbol: known.symbol, currency: known.currency! };
    const info = await client.multicall({
      contracts: [
        { abi: abis.ERC20, address: addr, functionName: 'symbol' },
        { abi: abis.ERC20, address: addr, functionName: 'decimals' },
      ],
      allowFailure: true
    });
    const symbol = info[0].status === 'success' ? info[0].result as string : addr.slice(0, 10);
    const decimals = info[1].status === 'success' ? info[1].result as number : 18;
    return { symbol, currency: { symbol, decimals } };
  };

  type VdaoPool = {
    vdaoToken: Address; vdaoSymbol: string; reserveVdao: Amount<bigint>;
    asset: Address; assetSymbol: string; reserveAsset: Amount<bigint>;
    reserveAssetUSD: Amount<bigint> | null;
  };
  const vdaoDaxPools: VdaoPool[] = [];
  if (vdaoNumPools > 0n) {
    const poolContracts = [];
    for (let i = 0n; i < vdaoNumPools; i++) {
      poolContracts.push({ ...vdaoDaxConfig, functionName: 'getPoolReserves', args: [i] });
    }
    const poolResults = await client.multicall({ contracts: poolContracts, allowFailure: true });
    for (let i = 0; i < poolResults.length; i++) {
      const r = poolResults[i];
      if (r.status !== 'success') {
        vdaoDaxErrors.push(`getPoolReserves(${i}): ${(r.error as Error).message ?? 'reverted'}`);
        continue;
      }
      const [asset, vdaoToken, reserveAsset, reserveVdao] =
        r.result as unknown as [Address, Address, bigint, bigint];
      const assetInfo = await resolveToken(asset);
      const vdaoInfo = await resolveToken(vdaoToken);

      // Price the external-asset side via TWAP spot price when it is a known
      // collateral asset; otherwise leave it unpriced — this DAX has no VY base
      // from which to derive a fallback price.
      let reserveAssetUSD: Amount<bigint> | null = null;
      const knownAsset = assets.find(a => a.address.toLowerCase() === asset.toLowerCase());
      if (knownAsset) {
        const spotPriceRaw = knownAsset.spotPrice.value as bigint;
        const assetDecimals = assetInfo.currency.decimals ?? 18;
        const scaleFactor = BigInt(10) ** BigInt(18 - assetDecimals);
        reserveAssetUSD = new Amount(USD, spotPriceRaw > 0n
          ? (reserveAsset * scaleFactor * spotPriceRaw) / BigInt(1e18)
          : 0n);
      }

      vdaoDaxPools.push({
        vdaoToken,
        vdaoSymbol: vdaoInfo.symbol,
        reserveVdao: new Amount(vdaoInfo.currency, reserveVdao),
        asset,
        assetSymbol: assetInfo.symbol,
        reserveAsset: new Amount(assetInfo.currency, reserveAsset),
        reserveAssetUSD,
      });
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

  // --- Staking System Debt (principal + accrued-but-unpaid yield, per asset) ---
  // The protocol's outstanding liability to stakers, grouped so every stake of
  // the same asset is summed together. Two stake kinds:
  //   • VY stakes  → principal is the aggregate `totalStakedVY`; accrued-unpaid
  //                  yield is Σ VYO.pendingYield(user, stakeId) over each user's
  //                  currently-active stakes.
  //   • Asset stakes → principal is the aggregate VSR.totalPrincipalByAsset(asset)
  //                  (asset-native units); accrued-unpaid yield is
  //                  Σ VYO.pendingAssetYield(user, stakeId) grouped by asset.
  // No on-chain aggregate of yield-owed exists, so stakers are enumerated from
  // the VSR deposit events and each active stake's pending yield is read live.
  const vyoConfig = getContractConfig('ValinityYieldOfficer');
  const vsrDepositEvent = parseAbiItem('event Deposit(address indexed user, uint8 stakeId, uint256 vyAmount, uint8 tierId, uint256 vdaxMinted, uint256 uniMinted, uint256 daxCreditsAdd, uint256 uniCreditsAdd)');
  const assetStakeDepositedEvent = parseAbiItem('event AssetStakeDeposited(address indexed user, uint256 indexed stakeId, address indexed asset, uint256 principalAsset, uint8 tier, uint256 lpAmount, bool isUniLP)');

  const [vyDepositLogs, assetDepositLogs] = await Promise.all([
    client.getLogs({ address: vsrConfig.address, event: vsrDepositEvent, fromBlock: 0n, toBlock: 'latest' }),
    client.getLogs({ address: vsrConfig.address, event: assetStakeDepositedEvent, fromBlock: 0n, toBlock: 'latest' }),
  ]);

  // VY stakes: accrued-unpaid yield over every active stake of every VY staker.
  const vyStakers = [...new Set(vyDepositLogs.map(l => l.args.user as Address))];
  let vyPendingYield = 0n;
  if (vyStakers.length > 0) {
    const activeStakesResults = await client.multicall({
      contracts: vyStakers.map(u => ({ ...vyoConfig, functionName: 'getActiveStakes', args: [u] })),
      allowFailure: true,
    });
    const vyPendingCalls: { user: Address; stakeId: number }[] = [];
    vyStakers.forEach((u, i) => {
      const r = activeStakesResults[i];
      if (r.status === 'success') {
        for (const id of r.result as unknown as readonly number[]) vyPendingCalls.push({ user: u, stakeId: Number(id) });
      } else {
        vsrErrors.push(`VYO.getActiveStakes(${u}): ${(r.error as Error).message ?? 'reverted'}`);
      }
    });
    if (vyPendingCalls.length > 0) {
      const vyPendingResults = await client.multicall({
        contracts: vyPendingCalls.map(c => ({ ...vyoConfig, functionName: 'pendingYield', args: [c.user, c.stakeId] })),
        allowFailure: true,
      });
      vyPendingYield = vyPendingResults.reduce((s, r) => s + (r.status === 'success' ? r.result as bigint : 0n), 0n);
    }
  }

  // Asset stakes: dedupe (user, stakeId) — stakeIds are monotonic so each pair is
  // unique, but inactive (withdrawn) stakes return 0 yield by design.
  const assetStakeKeys = assetDepositLogs.map(l => ({
    user: l.args.user as Address,
    stakeId: l.args.stakeId as bigint,
    asset: l.args.asset as Address,
  }));
  const seenAssetStake = new Set<string>();
  const uniqueAssetStakes = assetStakeKeys.filter(k => {
    const key = `${k.user}-${k.stakeId}`;
    if (seenAssetStake.has(key)) return false;
    seenAssetStake.add(key);
    return true;
  });

  const yieldByAsset = new Map<Address, bigint>();
  if (uniqueAssetStakes.length > 0) {
    const assetPendingResults = await client.multicall({
      contracts: uniqueAssetStakes.map(k => ({ ...vyoConfig, functionName: 'pendingAssetYield', args: [k.user, k.stakeId] })),
      allowFailure: true,
    });
    uniqueAssetStakes.forEach((k, i) => {
      const r = assetPendingResults[i];
      const y = r.status === 'success' ? r.result as bigint : 0n;
      yieldByAsset.set(k.asset, (yieldByAsset.get(k.asset) ?? 0n) + y);
    });
  }

  // Per-asset principal (aggregate) + native-unit metadata for display.
  const stakedAssets = [...new Set(assetStakeKeys.map(k => k.asset))];
  const assetDebtRows: { symbol: string; principal: Amount<bigint>; yieldOwed: Amount<bigint> }[] = [];
  if (stakedAssets.length > 0) {
    const assetMetaResults = await client.multicall({
      contracts: stakedAssets.flatMap(a => [
        { ...vsrConfig, functionName: 'totalPrincipalByAsset', args: [a] },
        { abi: abis.ERC20, address: a, functionName: 'decimals' },
        { abi: abis.ERC20, address: a, functionName: 'symbol' },
      ]),
      allowFailure: true,
    });
    stakedAssets.forEach((a, i) => {
      const principalR = assetMetaResults[i * 3];
      const decimalsR = assetMetaResults[i * 3 + 1];
      const symbolR = assetMetaResults[i * 3 + 2];
      const principal = principalR.status === 'success' ? principalR.result as bigint : 0n;
      const decimals = decimalsR.status === 'success' ? Number(decimalsR.result) : 18;
      const symbol = symbolR.status === 'success' ? symbolR.result as string : a.slice(0, 8);
      const cur: Currency = { symbol, decimals };
      assetDebtRows.push({
        symbol,
        principal: new Amount(cur, principal),
        yieldOwed: new Amount(cur, yieldByAsset.get(a) ?? 0n),
      });
    });
  }

  // VY stakes lead the table (principal = the live aggregate totalStakedVY).
  const stakingDebtRows = [
    { symbol: 'VY', principal: new Amount(VY, totalStakedVY), yieldOwed: new Amount(VY, vyPendingYield) },
    ...assetDebtRows,
  ];

  // --- Treasury Solvency (over-collateralization invariant) ---
  // The protocol pays yield (and tops up principal shortfalls) from VYT, and the
  // Yield Officer only lets payouts continue while
  //   VYT.getAvailableForYield() >= VYO.totalPromisedYield()
  // Both are VY-denominated. `totalPromisedYield` is the system's full reserved
  // debt (committed-but-unpaid yield + the 2× principal-protection reservation),
  // a superset of the accrued yield shown per-asset above — so a green check here
  // proves every row of the debt table is covered. (Principal itself is LP-backed
  // in the router; VYT only stands behind yield + shortfalls.)
  const vytConfig = getContractConfig('ValinityYieldTreasury');
  const solvencyResults = await client.multicall({
    contracts: [
      { ...vytConfig, functionName: 'getBalance' },
      { ...vytConfig, functionName: 'getAvailableForYield' },
      { ...vyoConfig, functionName: 'totalPromisedYield' },
    ],
    allowFailure: true,
  });
  const vytBalance = solvencyResults[0].status === 'success' ? solvencyResults[0].result as bigint : (() => { vsrErrors.push('VYT.getBalance: reverted'); return 0n; })();
  const vytAvailableForYield = solvencyResults[1].status === 'success' ? solvencyResults[1].result as bigint : (() => { vsrErrors.push('VYT.getAvailableForYield: reverted'); return 0n; })();
  const totalPromisedYield = solvencyResults[2].status === 'success' ? solvencyResults[2].result as bigint : (() => { vsrErrors.push('VYO.totalPromisedYield: reverted'); return 0n; })();
  const solvencySurplus = vytAvailableForYield - totalPromisedYield;
  const overCollateralized = solvencySurplus >= 0n;
  const solvencyRatioPct = totalPromisedYield > 0n
    ? Number((vytAvailableForYield * 10000n) / totalPromisedYield) / 100
    : null;
  const solvencyMagnitudeVY = (Number(solvencySurplus < 0n ? -solvencySurplus : solvencySurplus) / 1e18)
    .toLocaleString('en-US', { maximumFractionDigits: 2 });
  const coverageSuffix = solvencyRatioPct != null ? ` (${solvencyRatioPct.toFixed(1)}% coverage)` : '';
  const solvencyLabel = overCollateralized
    ? `✅ Over-Collateralized — surplus ${solvencyMagnitudeVY} VY${coverageSuffix}`
    : `🔴 Under-Collateralized — short ${solvencyMagnitudeVY} VY${coverageSuffix}`;

  // Net VY Staked (from API: deposits - withdrawals)
  const netVyStakedRaw = stakingStatsResponse?.data?.net_vy_staked;
  const netVyStaked = netVyStakedRaw != null
    ? new Amount(VY, BigInt(Math.round(parseFloat(netVyStakedRaw) * 1e18)))
    : 'Unavailable' as const;

  // --- Buyback ---
  const buybackAddress = (addresses as Record<string, Address>)['ValinityBuybackOfficer'];
  const oldBuybackAddress = '0xD2F0826af20EbDc833c8418E312F23f373F8500e' as Address;
  const vytAddress = (addresses as Record<string, Address>)['ValinityYieldTreasury'];
  const erc20TransferEvent = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)');
  const [buybackBalanceResult, buybackToVytLogs, oldBuybackToVytLogs] = await Promise.all([
    client.multicall({
      contracts: [
        { ...vyTokenConfig, functionName: 'balanceOf', args: [buybackAddress] },
      ],
      allowFailure: true
    }),
    client.getLogs({
      address: vyTokenConfig.address,
      event: erc20TransferEvent,
      args: { from: buybackAddress, to: vytAddress },
      fromBlock: 0n,
      toBlock: 'latest',
    }),
    client.getLogs({
      address: vyTokenConfig.address,
      event: erc20TransferEvent,
      args: { from: oldBuybackAddress, to: vytAddress },
      fromBlock: 0n,
      toBlock: 'latest',
    }),
  ]);
  const buybackVyBalance = buybackBalanceResult[0].status === 'success'
    ? buybackBalanceResult[0].result as bigint
    : 0n;
  const newVyBoughtBack = buybackToVytLogs.reduce(
    (sum, log) => sum + (log.args.value ?? 0n),
    0n
  );
  const oldVyBoughtBack = oldBuybackToVytLogs.reduce(
    (sum, log) => sum + (log.args.value ?? 0n),
    0n
  );
  const totalVyBoughtBack = oldVyBoughtBack + newVyBoughtBack;
  const collateralLTVFs = assets
    .filter(a => a.isCollateral && a.LTVF.value > 0n)
    .map(a => a.LTVF.value);
  const lowestLTVF = collateralLTVFs.length > 0
    ? collateralLTVFs.reduce((min, v) => v < min ? v : min)
    : 0n;
  const buybackBuyingPower = lowestLTVF > 0n
    ? (buybackVyBalance * lowestLTVF) / BigInt(1e18)
    : 0n;

  // --- VRYO allocator aggregate (per-asset data lives on each asset card) ---
  // VLM removed (V3 redesign, live impl 0xc8b848b9…0a241). VRYO no longer runs
  // Uniswap V3 concentrated LP; it deploys each collateral asset VRT→DAX, driving
  // its VY-cap share toward assetDeployRatioBps of the global cap. The per-asset
  // reads are folded into the asset cards (see asset construction). capVRYO_total
  // is deprecated (now 0), so the authoritative deployed total is Σ per-asset
  // capVRYO — this feeds the cap-conservation invariant and Round Floor below.
  const totalDeployedVY = assets
    .filter(a => a.isCollateral)
    .reduce((sum, a) => sum + (a.vryoCap.value as bigint), 0n);

  const circulatingPctDeployed = totalUncollateralized > 0n
    ? Number((totalDeployedVY * 10000n) / totalUncollateralized) / 100
    : 0;

  // --- Cap Health (totalCaps must equal circulating supply) ---
  // Fees now flow directly to VBBO (not batched through the VY token to VCO),
  // so accumulatedFees will always be zero and there is no lag. Total caps
  // must equal the circulating supply at all times.
  const capCirculatingLag = (totalCaps + totalDeployedVY) - totalUncollateralized;
  const capLagMagnitude = capCirculatingLag < 0n ? -capCirculatingLag : capCirculatingLag;
  // Treat sub-dust lag (integer-truncation rounding) as healthy; only a lag
  // above CAP_HEALTH_DUST_WEI signals a real cap/circulating mismatch.
  const capHealthy = capLagMagnitude <= CAP_HEALTH_DUST_WEI;
  if (!capHealthy) {
    overviewErrors.push(
      `Cap-circulating mismatch: (totalCaps + totalDeployedVY) − circulating = ${(Number(capCirculatingLag) / 1e18).toFixed(2)} VY (expected 0)`
    );
  }

  // --- Round Floor (USD per VY backing across VRT collateral + VRYO-deployed) ---
  // Numerator: Σ USD value of VRT collateral (VCO leg) + Σ USD value of the asset
  //   VRYO deployed into DAX (VRYO leg) — both precomputed per asset.
  // Denominator: Σ caps in VCO + Total VY Deployed (VRYO caps).

  let vrtCollateralUSD = 0n;
  for (const a of assets) {
    if (!a.isCollateral) continue;
    vrtCollateralUSD += a.reserveBalanceUSD.value as bigint;
  }

  // VRYO-deployed assets back the VRYO caps (totalDeployedVY) in the floor
  // denominator. With the V3 redesign VRYO injects the asset into the DAX pool
  // reserve, so each asset's `deployedBalanceUSD` is the live backing for the
  // VRYO leg. (This value also sits inside daxTVL — see the TVL note below.)
  let lpHoldingsUSD = 0n;
  for (const a of assets) {
    if (!a.isCollateral) continue;
    lpHoldingsUSD += a.deployedBalanceUSD.value as bigint;
  }

  const roundFloorDenominator = totalCaps + totalDeployedVY;
  const roundFloor: Amount<bigint> | 'Unavailable' = roundFloorDenominator > 0n
    ? new Amount(USD, ((vrtCollateralUSD + lpHoldingsUSD) * 10n ** 18n) / roundFloorDenominator)
    : 'Unavailable' as never;

  // VRYO no longer holds standalone Uniswap V3 LP NFTs; its deployed assets live
  // inside the DAX pool reserves, so they're already counted in daxTVL. Do NOT
  // add lpHoldingsUSD here or it would double-count against DAX TVL (it is only
  // surfaced separately in the Round Floor numerator above, which ignores TVL).
  const daxTVL = daxPools.reduce((sum, p) => sum + (p.reserveAssetUSD.value as bigint), 0n);
  tvl += daxTVL;

  // Liquid assets = VRT collateral + DAX non-VY reserves (incl. VRYO-deployed) + USDC pool
  const usdcPoolUSD = usdcReserve * 10n ** 12n; // 6→18 decimal, USDC ≈ $1
  const liquidAssetsUSD = vrtCollateralUSD + daxTVL + usdcPoolUSD;

  return {
    circulatingSupply: new Amount(VY, totalUncollateralized),
    vyTotalSupply: new Amount(VY, vyTotalSupply),
    overview: {
      'Total Caps': new Amount(VY, totalCaps + totalDeployedVY),
      'VCO Caps': new Amount(VY, totalCaps),
      'VRYO Caps': new Amount(VY, totalDeployedVY),
      'Cap Health': capHealthy ? '✅ Total Caps = Circulating Supply' : `🔴 Off by ${(Number(capCirculatingLag) / 1e18).toFixed(6)} VY`,
      TVL: new Amount(USD, tvl),
      'CLAV': new Amount(USD, liquidAssetsUSD),
      MTP: mtp,
      'Round Floor': roundFloor,
      'VRYO Deployed': totalUncollateralized > 0n
        ? `${circulatingPctDeployed.toFixed(2)}% of circulating`
        : 'Unavailable' as const,
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
    lps: (() => {
      const vyInLPs = totalVYReserves + vyReserve;
      const vyInUserWallets = totalUncollateralized > vyInLPs ? totalUncollateralized - vyInLPs : 0n;
      return {
        'VY in DAX': new Amount(VY, totalVYReserves),
        'VY in VY/USDC Pool': new Amount(VY, vyReserve),
        'Total VY in LPs': new Amount(VY, vyInLPs),
        'VY in User Wallets': new Amount(VY, vyInUserWallets),
      };
    })(),
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
    vdaoDax: {
      overview: {
        'Num Pools': String(vdaoNumPools),
        'Swaps Paused': vdaoDaxSwapsPaused,
      },
      pools: vdaoDaxPools,
      errors: vdaoDaxErrors,
    },
    stakingRouter: {
      debt: stakingDebtRows,
      solvency: {
        available: new Amount(VY, vytAvailableForYield),
        balance: new Amount(VY, vytBalance),
        promised: new Amount(VY, totalPromisedYield),
        surplus: new Amount(VY, solvencySurplus < 0n ? -solvencySurplus : solvencySurplus),
        overCollateralized,
        ratioPct: solvencyRatioPct,
        label: solvencyLabel,
      },
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
        'Net VY Staked': netVyStaked,
      },
      errors: vsrErrors,
    },
    buyback: {
      'Total VY Bought Back': new Amount(VY, totalVyBoughtBack),
      'VY Holdings': new Amount(VY, buybackVyBalance),
      'Buying Power': new Amount(USD, buybackBuyingPower),
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
        <h2>Balances <a href="https://etherscan.io/address/0xe58E29c947013B4CBCdb67f90d659c3894BE2974" target="_blank" rel="noreferrer" style={{ fontWeight: 'normal' }}>VYT ↗ Etherscan</a></h2>
        <div className="box">
          <BalanceTable
            data={data.balanceMap}
            headerRows={[
              { label: 'VY Total Supply', value: data.vyTotalSupply },
            ]}
            footerRows={[
              { label: 'VY in LPs', value: data.lps['Total VY in LPs'] },
              { label: 'Circulating Supply', value: data.circulatingSupply },
              { label: 'VY in User Wallets', value: data.lps['VY in User Wallets'] },
            ]}
          />
        </div>
      </div>

      <div>
        <h2>Current Stats</h2>
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
        <h2>Buyback <a href="https://etherscan.io/address/0x4B97D45d276084c1C5BDBd0aa29B417cE02bE2F6" target="_blank" rel="noreferrer" style={{ fontWeight: 'normal' }}>↗ Etherscan</a></h2>
        <div className="box">
          {renderValues(data.buyback)}
        </div>
      </div>

      <div>
        <h2>Pool (VY/USDC) <a href="https://etherscan.io/address/0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705" target="_blank" rel="noreferrer" style={{ fontWeight: 'normal' }}>↗ Etherscan</a></h2>
        <div className="box">
          {renderValues(data.pool)}
        </div>
      </div>

      <div>
        <h2>Valinity Arbitrage Exchange <a href="https://etherscan.io/address/0xD256C672616f7c5DEE3e42a8199f121EE08401B7" target="_blank" rel="noreferrer" style={{ fontWeight: 'normal' }}>↗ Etherscan</a></h2>
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
            const swap = (a: RegExp, b: RegExp) => {
              const ai = pools.findIndex(p => a.test(p.symbol));
              const bi = pools.findIndex(p => b.test(p.symbol));
              if (ai !== -1 && bi !== -1) [pools[ai], pools[bi]] = [pools[bi], pools[ai]];
            };
            swap(/nv/i, /link/i);
            swap(/nv/i, /wbtc/i);
            swap(/tsla/i, /weth/i);
            swap(/nv/i, /paxg/i);
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
                      [`${pool.symbol} Reserve (USDC)`]: pool.reserveAssetUSD,
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
        <h2>VDAO DAX <a href="https://etherscan.io/address/0x37Cd61b3EF849805E598023f8C14bFcafE5f222E" target="_blank" rel="noreferrer" style={{ fontWeight: 'normal' }}>↗ Etherscan</a></h2>
        <div className={`box ${data.vdaoDax.errors.length > 0 ? 'box--error' : ''}`}>
          {data.vdaoDax.errors.length > 0 && (
            <div className="error-list">
              {data.vdaoDax.errors.map((err, i) => (
                <div key={i} className="error-item">✗ {err}</div>
              ))}
            </div>
          )}
          {renderValues(data.vdaoDax.overview)}
          {data.vdaoDax.pools.length > 0 && (
            <>
              <h3 style={{ marginTop: '12px' }}>Pools</h3>
              <div style={{
                display: 'grid',
                gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)',
                gap: '5px 8px',
                alignItems: 'start',
                marginTop: '8px',
              }}>
                {data.vdaoDax.pools.map((pool, i) => (
                  <div key={i} className="box" style={{ marginBottom: 0 }}>
                    <h4>{pool.vdaoSymbol}/{pool.assetSymbol}</h4>
                    {renderValues({
                      [`${pool.vdaoSymbol} Token`]: pool.vdaoToken,
                      [`${pool.assetSymbol} Token`]: pool.asset,
                      [`${pool.vdaoSymbol} Reserve`]: pool.reserveVdao,
                      [`${pool.assetSymbol} Reserve`]: pool.reserveAsset,
                      ...(pool.reserveAssetUSD
                        ? { [`${pool.assetSymbol} Reserve (USDC)`]: pool.reserveAssetUSD }
                        : {}),
                    })}
                  </div>
                ))}
              </div>
            </>
          )}
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
          <h3
            title="The protocol's outstanding liability to stakers: original principal staked plus yield that has accrued but has not yet been claimed. Grouped so every stake of the same asset is summed together. Values are in each asset's native units."
            style={{ marginTop: 0, cursor: 'help', borderBottom: '1px dotted #888', display: 'inline-block' }}
          >System Debt (Principal + Accrued Yield Owed)</h3>
          <table>
            <thead>
              <tr>
                <th>Asset</th>
                <th>Principal Staked</th>
                <th>Accrued Yield Owed</th>
                <th>Total Debt</th>
              </tr>
            </thead>
            <tbody>
              {data.stakingRouter.debt.map(row => (
                <tr key={row.symbol}>
                  <td><strong>{row.symbol}</strong></td>
                  <td><Value>{row.principal}</Value></td>
                  <td><Value>{row.yieldOwed}</Value></td>
                  <td><Value>{new Amount(row.principal.currency, row.principal.value + row.yieldOwed.value)}</Value></td>
                </tr>
              ))}
            </tbody>
          </table>
          <h3 style={{ marginTop: '12px' }}>Token Holdings</h3>
          {renderValues(data.stakingRouter.tokenHoldings, undefined, {
            'VDAX Balance': 'Actual VDAX token balance held by the router contract',
            'UNI-LP Balance': 'Actual UNI-LP token balance held by the router contract',
            'Net VY Staked': 'Cumulative VY deposited minus VY withdrawn through the staking router',
          })}
          <h3 style={{ marginTop: '12px' }}>Treasury Solvency</h3>
          <table>
            <tbody>
              <tr>
                <td>
                  <strong title="VY held by the Yield Treasury (VYT) that is available to pay yield — its VY balance minus the 0.5% priority-officer cushion.">VYT Available for Yield</strong>
                </td>
                <td><Value>{data.stakingRouter.solvency.available}</Value></td>
              </tr>
              <tr>
                <td>
                  <strong title="Total reserved debt the treasury must stand behind: committed-but-unpaid yield plus the 2× principal-protection reservation, all in VY. This is a superset of the accrued yield shown per-asset above.">Total Promised Debt (reserved)</strong>
                </td>
                <td><Value>{data.stakingRouter.solvency.promised}</Value></td>
              </tr>
              <tr>
                <td>
                  <strong title="Over-collateralized when VYT Available for Yield ≥ Total Promised Debt — the protocol's own solvency invariant. The surplus is the VY buffer above all reserved debt.">Coverage</strong>
                </td>
                <td><Value>{data.stakingRouter.solvency.label}</Value></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div>
        <h2>Valinity Reserves <a href="https://etherscan.io/address/0x06087789B7122fA92E7F9868B10A286Dd4e4C832" target="_blank" rel="noreferrer" style={{ fontWeight: 'normal' }}>VRT ↗ Etherscan</a></h2>

        <div style={{ marginTop: '8px' }}>
          {data.assets.filter(a => a.isCollateral).map(asset => {
            const { symbol, errors, warnings } = asset;
            // Fixed field order: identity → VRYO target/actual → global → VRYO leg → VCO leg → VRT reserve.
            const displayStats = {
              'Address': asset.address,
              'Spot Price': asset.spotPrice,
              'Target Deploy Ratio': asset.targetDeployRatio,
              'Deployed Ratio': asset.deployedRatio,
              'Global Cap': asset.globalCap,
              'Global LTV': asset.globalLTV,
              'Global LTVF': asset.globalLTVF,
              'VRYO Cap': asset.vryoCap,
              'VRYO LTV': asset.vryoLTV,
              'VRYO LTVF': asset.vryoLTVF,
              'Deployed Balance': asset.deployedBalance,
              'Deployed Balance USD': asset.deployedBalanceUSD,
              'VCO Cap': asset.cap,
              'VCO Cap Floor': asset.capFloor,
              'VCO LTV': asset.LTV,
              'VCO LTVF': asset.LTVF,
              'Reserve Balance': asset.reserveBalance,
              'Reserve Balance USD': asset.reserveBalanceUSD,
              'Collateralized': asset.collateralized,
            };
            return (
              <div key={symbol} className={`box ${errors && errors.length > 0 ? 'box--error' : warnings && warnings.length > 0 ? 'box--warning' : ''}`} style={{ marginTop: '8px' }}>
                <h3>
                  {symbol}
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
                {renderValues(displayStats, undefined, {
                  'Target Deploy Ratio': 'assetDeployRatioBps — VRYO’s target deployed share of this asset’s global cap.',
                  'Deployed Ratio': 'Actual deployed share = capVRYO ÷ Global Cap.',
                  'Global Cap': 'VRYO cap + VCO cap for this asset (getGlobalCap).',
                  'Global LTV': '(VRYO-deployed asset + VRT reserve asset) ÷ Global Cap — asset per VY.',
                  'Global LTVF': 'Global LTV × spot — USD backing per VY across both legs.',
                  'VRYO LTV': 'getInternalLTV — deployed asset ÷ VRYO cap (asset per VY).',
                  'VRYO LTVF': 'VRYO LTV × spot — USD per VY of the VRYO-deployed leg.',
                  'Deployed Balance': 'deployedAsset — native amount VRYO has injected into the DAX pool.',
                  'VCO Cap': 'CapOfficer collateralCap for this asset.',
                  'VCO Cap Floor': 'VCO effective floor (global).',
                  'VCO LTVF': 'CapOfficer ltvF — USD per VY of the VCO leg.',
                  'Reserve Balance': 'Asset sitting in VRT (getAssetView.reserveBalance).',
                })}
              </div>
            );
          })}
        </div>
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

const BalanceTable = ({ data, headerRows, footerRows }: {
  data: { [key: string]: Amount<bigint>[] }
  headerRows?: { label: string; value: Amount<bigint> }[]
  footerRows?: { label: string; value: Amount<bigint> }[]
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
        {headerRows && headerRows.map(row => (
          <tr key={row.label}>
            <td>{row.label}</td>
            <td><Value includeSybmol={false}>{row.value}</Value></td>
          </tr>
        ))}
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
      {footerRows && footerRows.length > 0 && (
        <tfoot>
          {footerRows.map(row => (
            <tr key={row.label}>
              <td>{row.label}</td>
              <td><Value includeSybmol={false}>{row.value}</Value></td>
            </tr>
          ))}
        </tfoot>
      )}
    </table>
  )
}

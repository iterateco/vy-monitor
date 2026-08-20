import flatten from 'lodash/flatten';
import omit from 'lodash/omit';
import startCase from 'lodash/startCase';
import { useEffect, useState, type JSX } from 'react';
import { createPublicClient, http, parseAbiItem, type Address } from 'viem';
import { mainnet } from 'viem/chains';
import { Value } from '../components/core';
import { BackingTiles } from '../components/BalanceSheet';
import { CONTRACT_ACRONYMS, MAINNET_RPC_URL } from '../config';
import { Amount, USD, VY } from '../models';
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

/** VBSO proxy — the company balance sheet. */
const VBSO_ADDRESS = '0xDFd145401122d62987c6a363e370F4DB759BE1b4' as const;

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

  const assets = await Promise.all(assetEntries.map(async ([assetKey, assetAddr]) => {
    const tokenConfig = getContractConfig('ERC20', assetAddr);
    const isCollateral = COLLATERAL_SYMBOLS.has(assetKey);

    // Base calls: decimals + symbol (always)
    const baseContracts = [
      { ...tokenConfig, functionName: 'decimals' },
      { ...tokenConfig, functionName: 'symbol' },
    ];

    // Collateral-only calls. The VCO cap/metrics and VRYO allocator reads that used
    // to live here were deleted with the Valinity Reserves panel: they fed only that
    // panel, and on-chain they now return zeros (every hard asset left the VRT).
    // Spot price still feeds DAX/VDAODAX/VMMO valuation; getAssetView still feeds
    // the loan totals.
    const collateralContracts = isCollateral ? [
      { ...vaoConfig, functionName: 'getAssetTwapPrice', args: [assetAddr] },
      { ...vloConfig, functionName: 'getAssetView', args: [assetAddr] },
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
      const warnLabels = ['getAssetTwapPrice'];
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
        totalLoaned: new Amount(currency, 0n),
        totalLoanedUSD: new Amount(USD, 0n),
        notCollateral: true
      }
    }

    // Collateral asset — parse remaining results (indices 2..3)
    const spotPrice = get(2, 'getAssetTwapPrice', 0n);
    const assetView = results[3].status === 'success'
      ? results[3].result as unknown as { ltv: bigint; reserveBalance: bigint; totalLoaned: bigint }
      : (() => { errors.push(`getAssetView: ${(results[3].error as Error).message ?? 'reverted'}`); return { ltv: 0n, reserveBalance: 0n, totalLoaned: 0n }; })();
    const { totalLoaned } = assetView;

    const scaleFactor = BigInt(10) ** BigInt(18 - decimals);
    const toUSD = (native: bigint) => spotPrice ? ((native * scaleFactor) * spotPrice) / BigInt(1e18) : 0n;

    return {
      symbol,
      currency,
      address: assetAddr,
      isCollateral: true,
      errors,
      warnings,
      spotPrice: new Amount(USD, spotPrice),
      totalLoaned: new Amount(currency, totalLoaned),
      totalLoanedUSD: new Amount(USD, toUSD(totalLoaned)),
      notCollateral: false,
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

  const [overviewResults] = await Promise.all([
    client.multicall({
      contracts: [
        { ...vyTokenConfig, functionName: 'totalSupply' },
        { ...pairConfig, functionName: 'getReserves' },
        { ...pairConfig, functionName: 'token0' },
      ],
      allowFailure: true
    }),
  ]);

  const vyTotalSupply = overviewResults[0].status === 'success'
    ? overviewResults[0].result as bigint
    : (() => { overviewErrors.push(`totalSupply: ${(overviewResults[0].error as Error).message ?? 'reverted'}`); return 0n; })();
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

  let tvl = 0n;
  for (const asset of assets) {
    tvl += asset.totalLoanedUSD.value as bigint;
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

  // REMOVED 2026-08-20 — the Staking Router section (router state, credits and
  // indices, per-asset staking debt, VYT solvency, router token holdings, and the
  // /staking/stats API call behind Net VY Staked). Removed on request: this
  // reporting is moving onto the balance sheet.
  //
  // The VSR itself is still very much live and is read elsewhere — VBSO's
  // `_pairUsdcUsd` values the protocol's VY/USDC LP as `uniPair.balanceOf(vsr)`,
  // so the router's LP position still reaches the hard-assets figure above. Only
  // this page's own staking panel is gone.

  // --- Buyback ---
  const buybackAddress = (addresses as Record<string, Address>)['ValinityMarketStabilityOfficer'];
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

  // REMOVED 2026-08-20 — the whole VRT / VCO / VRYO reporting layer.
  //
  // Gone with it: the "Valinity Reserves" panel and its per-asset cards, Cap
  // Health, VCO caps, VRYO caps, Round Floor, and the per-asset reserve balances.
  // Every one of those was computed from VRT treasury balances or
  // VCO.getAssetMetrics().ltvF, and on-chain both now read exactly zero for
  // WETH/WBTC/PAXG (verified: totalReserve 0, ltvF 0) because all hard assets
  // moved out of the VRT into the DAX. They had stopped being stale and started
  // being FALSE — rendering $0.00 backing, and a red cap-mismatch alert nobody
  // could act on, for a system holding real collateral.
  //
  // Backing per VY now comes from VBSO.sheet(); see `balanceSheet` below.
  //
  // STILL LOAD-BEARING, do not delete: the VRT's *VY* balance. It holds ~10.2M VY
  // and circulating supply is totalSupply − VYT − VRT, which is the divisor for
  // every per-VY floor on the balance sheet. Removing it would inflate the floors
  // by roughly 20x.

  const daxTVL = daxPools.reduce((sum, p) => sum + (p.reserveAssetUSD.value as bigint), 0n);
  tvl += daxTVL;

  // ─── VBSO — the company balance sheet ──────────────────────
  // Authoritative backing source. All hard assets moved out of the VRT into the
  // DAX, so every treasury-balance panel now reads ~0; sheet() is the truth.
  const vbsoConfig = getContractConfig('ValinityBalanceSheetOfficer');
  const vbsoErrors: string[] = [];
  const vbsoResults = await client.multicall({
    contracts: [
      { ...vbsoConfig, functionName: 'sheet' },
      { ...vbsoConfig, functionName: 'hardEquityUsd' },
      { ...vbsoConfig, functionName: 'vyOracle' },
      { ...vcoConfig, functionName: 'getTotalCirculatingVY' },
      // Keep new calls APPENDED — the reads below index this array positionally.
      { ...vbsoConfig, functionName: 'projectedVyPrice' },
    ],
    allowFailure: true,
  });

  const sheetRaw = vbsoResults[0].status === 'success'
    ? vbsoResults[0].result as unknown as readonly bigint[]
    : (() => { vbsoErrors.push(`sheet: ${(vbsoResults[0].error as Error)?.message ?? 'reverted'}`); return null; })();

  const sheet = sheetRaw && {
    hardAssetsUsd: sheetRaw[0], coveredLoansUsd: sheetRaw[1], loansFaceUsd: sheetRaw[2],
    stakerDebtUsd: sheetRaw[3], equityUsd: sheetRaw[4], fuelUsd: sheetRaw[5],
    demandUsd: sheetRaw[6], masterRateBps: sheetRaw[7], eraMaxBps: sheetRaw[8],
    era: sheetRaw[9], mcapUsd: sheetRaw[10], usdPerVy: sheetRaw[11],
    custodyCollateralUsd: sheetRaw[12], custodyEarnedUsd: sheetRaw[13],
  };

  // hardEquityUsd() is deployed; floorHardUsd()/floorFullUsd()/circulatingVY()
  // are in the VBSO source but NOT in the live implementation (they revert), so
  // the per-VY floors are derived here. Swap to the direct calls after an upgrade.
  const hardEquityUsd = vbsoResults[1].status === 'success'
    ? vbsoResults[1].result as bigint
    : (sheet ? sheet.hardAssetsUsd - sheet.stakerDebtUsd : 0n);
  const vyOracleAddress = vbsoResults[2].status === 'success'
    ? vbsoResults[2].result as Address
    : null;
  // VCO is retired down to this single call; it matches totalSupply − VRT − VYT exactly.
  const circulatingVY = vbsoResults[3].status === 'success'
    ? vbsoResults[3].result as unknown as bigint
    : totalUncollateralized;

  // projectedVyPrice() reverts VmmoNotWired() before VMMO is set, so a failure is
  // a legitimate state, not an outage — surface it as "unavailable" rather than a
  // zero that would read as "no upside".
  const projection = vbsoResults[4].status === 'success'
    ? vbsoResults[4].result as unknown as {
        vyPriceUsd: bigint; ammoUsd: bigint; deployWindowSec: bigint;
        multipleX: bigint; livePriceUsd: bigint;
      }
    : null;
  const projectionError = vbsoResults[4].status === 'success'
    ? null
    : ((vbsoResults[4].error as Error)?.message?.includes('VmmoNotWired')
        ? 'VMMO not wired yet'
        : 'projection unavailable');

  const perVy = (usd: bigint) => (circulatingVY > 0n ? (usd * 10n ** 18n) / circulatingVY : 0n);
  const floorHard = perVy(hardEquityUsd);
  const marketPerVy = sheet?.usdPerVy ?? 0n;

  const vyUsdWad = marketPerVy;
  const vyToUsd = (vy: bigint) => (vy * vyUsdWad) / 10n ** 18n;

  // --- VMMO inventory — market-maker stock held on the officer itself ─────────
  // Un-deployed quoting inventory: it sits in the VMMO's own ERC20 balances, not
  // inside any pool, so it double-counts none of the venue rows below. It is
  // capital the desk can quote against on demand, so CLAV counts it at face.
  const vmmoAddress = (addresses as Record<string, Address>)['ValinityMarketMakerOfficer'];
  const vmmoRaw = await client.multicall({
    contracts: [
      ...assets.map(a => ({ ...getContractConfig('ERC20', a.address), functionName: 'balanceOf', args: [vmmoAddress] })),
      { ...vyTokenConfig, functionName: 'balanceOf', args: [vmmoAddress] },
    ],
    allowFailure: true,
  });

  let vmmoInventoryUSD = 0n;
  const vmmoHeld: string[] = [];
  assets.forEach((a, i) => {
    const r = vmmoRaw[i];
    if (r.status !== 'success') {
      overviewWarnings.push(`balanceOf(VMMO, ${a.symbol}): reverted`);
      return;
    }
    const bal = r.result as bigint;
    if (bal === 0n) return;
    // USDC is not collateral, so it has no VAO TWAP — price it at $1. Collateral
    // assets use the same spot price the reserve/loan rows are valued with.
    const priceWad = a.symbol === 'USDC' ? 10n ** 18n : (a.spotPrice.value as bigint);
    if (priceWad === 0n) {
      // Stale/reverting TWAP (PAXG's thin pool does this) — count nothing rather
      // than count it at zero silently.
      overviewWarnings.push(`VMMO ${a.symbol}: no spot price, excluded from CLAV`);
      return;
    }
    vmmoInventoryUSD += (bal * 10n ** BigInt(18 - a.currency.decimals) * priceWad) / 10n ** 18n;
    vmmoHeld.push(a.symbol);
  });
  const vmmoVY = vmmoRaw[assets.length].status === 'success'
    ? vmmoRaw[assets.length].result as bigint
    : 0n;
  if (vmmoVY > 0n) {
    vmmoInventoryUSD += vyToUsd(vmmoVY);
    vmmoHeld.push('VY');
  }

  // --- CLAV — Current Liquid Assets Value ---
  // Total tradable depth of the system, counting BOTH sides of every venue — the
  // way an aggregator (DEXScreener et al) reports pool liquidity. A constant-
  // product pool holds equal value on each side, so counting only the asset side
  // reports half the real depth. Venues:
  //   • main DAX  → asset side + VY side of every pool
  //   • Uni pool  → USDC side + VY side of VY/USDC
  //   • VDAODAX   → priced side ×2 — its pair token (VGC) has no USD market, and
  //                 constant-product parity imputes the unpriced leg
  //   • VMMO      → idle market-maker inventory, counted once (it is not a pool)
  // The VRT is deliberately NOT added: its hard assets moved into the DAX, so its
  // balances are ~0 and adding them would double-count the DAX rows.
  const daxAssetSideUSD = daxPools.reduce((sum, p) => sum + (p.reserveAssetUSD.value as bigint), 0n);
  const daxVySideUSD = daxPools.reduce((sum, p) => sum + vyToUsd(p.reserveVY.value as bigint), 0n);
  const uniUsdcSideUSD = usdcReserve * 10n ** 12n; // 6→18 decimal, USDC ≈ $1
  const uniVySideUSD = vyToUsd(vyReserve);
  const vdaoPricedSideUSD = vdaoDaxPools.reduce((sum, p) =>
    sum + ((p.reserveAssetUSD?.value as bigint) ?? 0n), 0n);
  const vdaoBothSidesUSD = vdaoPricedSideUSD * 2n;

  const liquidAssetsUSD =
    daxAssetSideUSD + daxVySideUSD + uniUsdcSideUSD + uniVySideUSD + vdaoBothSidesUSD
    + vmmoInventoryUSD;

  return {
    circulatingSupply: new Amount(VY, totalUncollateralized),
    vyTotalSupply: new Amount(VY, vyTotalSupply),
    overview: {
      TVL: new Amount(USD, tvl),
      'CLAV (Current Liquid Assets Value)': new Amount(USD, liquidAssetsUSD),
    },
    balanceSheet: sheet && {
      floors: {
        projected: projection ? Number(projection.vyPriceUsd) / 1e18 : null,
        projectedAmmoUsd: projection ? Number(projection.ammoUsd) / 1e18 : 0,
        projectedWindowSec: projection ? Number(projection.deployWindowSec) : 0,
        projectedMultiple: projection ? Number(projection.multipleX) / 1e18 : 0,
        projectedError: projectionError,
        hard: Number(floorHard) / 1e18,
        market: Number(marketPerVy) / 1e18,
        circulating: Number(circulatingVY) / 1e18,
        equityUsd: Number(sheet.equityUsd) / 1e18,
        hardEquityUsd: Number(hardEquityUsd) / 1e18,
        hardAssetsUsd: Number(sheet.hardAssetsUsd) / 1e18,
        coveredLoansUsd: Number(sheet.coveredLoansUsd) / 1e18,
        loansFaceUsd: Number(sheet.loansFaceUsd) / 1e18,
        stakerDebtUsd: Number(sheet.stakerDebtUsd) / 1e18,
        mcapUsd: Number(sheet.mcapUsd) / 1e18,
      },
      rows: {
        'Hard assets': new Amount(USD, sheet.hardAssetsUsd),
        'Covered loans': new Amount(USD, sheet.coveredLoansUsd),
        'Loans at face': new Amount(USD, sheet.loansFaceUsd),
        'Staker debt': new Amount(USD, sheet.stakerDebtUsd),
        'Equity': new Amount(USD, sheet.equityUsd),
        'Hard equity': new Amount(USD, hardEquityUsd),
        'Fuel': new Amount(USD, sheet.fuelUsd),
        'Demand': new Amount(USD, sheet.demandUsd),
        'Custody collateral': new Amount(USD, sheet.custodyCollateralUsd),
        'Custody earned': new Amount(USD, sheet.custodyEarnedUsd),
        'Master rate': `${Number(sheet.masterRateBps) / 100}%`,
        'Era': `${sheet.era} (max ${Number(sheet.eraMaxBps) / 100}%)`,
      },
      // mcapUsd is priced on TOTAL supply while the floors divide by CIRCULATING
      // — a 32x different denominator. Never present them as comparable.
      mcap: {
        'Market cap (VBSO)': new Amount(USD, sheet.mcapUsd),
        'Circulating VY': new Amount(VY, circulatingVY),
        'Circulating market cap': new Amount(USD, vyToUsd(circulatingVY)),
      },
      vyOracle: vyOracleAddress,
      // Exact wei for the stress-curve validation gate. Round-tripping these
      // through the float `floors` above would fail the equality check every time.
      raw: {
        usdPerVy: marketPerVy,
        equityUsd: sheet.equityUsd,
        coveredLoansUsd: sheet.coveredLoansUsd,
        circulatingVY,
      },
      errors: vbsoErrors,
    },
    // Rendered with a verbatim-label table, not renderValues — startCase would
    // turn "VY/USDC — USDC side" into "VY USDC USDC Side".
    clav: [
      { venue: 'DAX', side: 'asset side', value: new Amount(USD, daxAssetSideUSD) },
      { venue: 'DAX', side: 'VY side', value: new Amount(USD, daxVySideUSD) },
      { venue: 'VY/USDC (Uniswap)', side: 'USDC side', value: new Amount(USD, uniUsdcSideUSD) },
      { venue: 'VY/USDC (Uniswap)', side: 'VY side', value: new Amount(USD, uniVySideUSD) },
      { venue: 'VDAODAX', side: 'both sides (VGC leg imputed)', value: new Amount(USD, vdaoBothSidesUSD) },
      { venue: 'VMMO (market maker)', side: vmmoHeld.length ? `inventory — ${vmmoHeld.join(' + ')}` : 'inventory (empty)', value: new Amount(USD, vmmoInventoryUSD) },
      { venue: 'CLAV total', side: '', value: new Amount(USD, liquidAssetsUSD), total: true },
    ],
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
    buyback: {
      'Total VY Bought Back': new Amount(VY, totalVyBoughtBack),
      'VY Holdings': new Amount(VY, buybackVyBalance),
    },
  };
};

type MonitorData = Awaited<ReturnType<typeof fetchData>>;

export default function Mainnet() {
  const [data, setData] = useState<MonitorData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    let active = true;
    const load = () => {
      fetchData()
        .then(d => { if (active) setData(d); })
        .catch(e => { if (active) setError(e.message ?? String(e)); });
    };
    load();
    const interval = setInterval(load, 30_000);
    return () => { active = false; clearInterval(interval); };
  }, []);

  // The first paint needs a few hundred RPC round trips and takes ~15s. A bare
  // "Loading..." for that long is indistinguishable from a hung page, so show the
  // clock — and after 40s say plainly that something is wrong, rather than
  // spinning forever.
  useEffect(() => {
    if (data) return;
    const t = setInterval(() => setElapsed((s) => s + 1), 1000);
    return () => clearInterval(t);
  }, [data]);

  if (error) return <p style={{ textAlign: 'center', color: 'red' }}>Error: {error}</p>;
  if (!data) return (
    <p style={{ textAlign: 'center', opacity: 0.8 }}>
      Loading on-chain data… {elapsed}s
      {elapsed > 40 && (
        <><br /><span style={{ color: '#e67e22' }}>
          This is taking longer than it should (normal is ~15s). The RPC may be
          throttling, or this tab may be pointed at a dev server that is no longer
          running — reload it.
        </span></>
      )}
    </p>
  );
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

      {data.balanceSheet && (
        <div>
          <h2>
            Balance Sheet — backing per VY{' '}
            <a href={`https://etherscan.io/address/${VBSO_ADDRESS}`} target="_blank" rel="noreferrer" style={{ fontWeight: 'normal' }}>
              VBSO ↗ Etherscan
            </a>
          </h2>
          <div className={`box ${data.balanceSheet.errors.length > 0 ? 'box--error' : ''}`}>
            {data.balanceSheet.errors.map((err, i) => (
              <div key={i} className="error-item">✗ {err}</div>
            ))}

            <BackingTiles floors={data.balanceSheet.floors} />

            <div className="vy-note">
              These three are published together on purpose. <strong>Floor (hard)</strong> is
              what the system holds in coin, net of staker debt — the number that does not
              depend on the loan book. Equity in the sheet below is larger because it also
              counts <strong>covered loans</strong>, currently{' '}
              {(100 * data.balanceSheet.floors.coveredLoansUsd / Math.max(data.balanceSheet.floors.equityUsd, 1e-9)).toFixed(0)}%
              of it, and those loans are <strong>collateralised in VY</strong> — an equity
              figure that is partly a claim about VY priced in VY, which is why it is not
              shown here as a headline price. Only{' '}
              {(100 * data.balanceSheet.floors.coveredLoansUsd / Math.max(data.balanceSheet.floors.loansFaceUsd, 1e-9)).toFixed(1)}%
              of the ${Math.round(data.balanceSheet.floors.loansFaceUsd).toLocaleString('en-US')} face
              loan book passes the coverage gate at all.
            </div>

            <h3 style={{ marginTop: '1.25rem' }}>Sheet</h3>
            {renderValues(data.balanceSheet.rows)}

            <h3 style={{ marginTop: '1rem' }}>Market cap</h3>
            {renderValues(data.balanceSheet.mcap)}
            <div className="vy-note">
              VBSO's <code>mcapUsd</code> prices <strong>total</strong> supply
              ({Math.round(data.balanceSheet.floors.mcapUsd / Math.max(data.balanceSheet.floors.market, 1e-9)).toLocaleString('en-US')} VY),
              while the floors divide by <strong>circulating</strong>
              ({Math.round(data.balanceSheet.floors.circulating).toLocaleString('en-US')} VY).
              Different denominators — do not compare them directly.
            </div>
          </div>
        </div>
      )}

      <div>
        <h2>Liquidity — CLAV (Current Liquid Assets Value)</h2>
        <div className="box">
          <table>
            <tbody>
              {data.clav.map((row, i) => (
                <tr key={i}>
                  <td><strong>{row.venue}</strong></td>
                  <td style={{ opacity: 0.7 }}>{row.side}</td>
                  <td style={{ fontWeight: row.total ? 'bold' : undefined }}>
                    <Value>{row.value}</Value>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="vy-note">
            Both sides of every venue, the way an aggregator reports pool liquidity —
            a constant-product pool holds equal value on each side, so counting only
            the asset side reports half the real depth. VDAODAX's pair token (VGC)
            has no USD market, so its unpriced leg is imputed at parity. The VMMO's
            idle market-making inventory is counted once, at face — it sits in the
            officer's own balances, not in a pool. The VRT is not counted: its hard
            assets moved into the DAX and adding them would double-count.
          </div>
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
        <h2>Market Stability — VMSO <a href="https://etherscan.io/address/0x4B97D45d276084c1C5BDBd0aa29B417cE02bE2F6" target="_blank" rel="noreferrer" style={{ fontWeight: 'normal' }}>↗ Etherscan</a></h2>
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

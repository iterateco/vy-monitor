import flatten from 'lodash/flatten';
import omit from 'lodash/omit';
import startCase from 'lodash/startCase';
import { Suspense, type JSX } from 'react';
import { createPublicClient, http, type Address } from 'viem';
import { mainnet } from 'viem/chains';
import { Value } from '../components/core';
import { CONTRACT_ACRONYMS, MAINNET_RPC_URL } from '../config';
import { Amount, USD, VY } from '../models';
import type { Currency } from '../models';
import networks from '../networks';
import createResource from '../utils/createResource';

/**
 * Assets soportados como colateral (LoanOfficer, CapOfficer, AcquisitionOfficer).
 * USDC NO es colateral — llamar getAssetView(USDC) causa UnsupportedAsset().
 */
const COLLATERAL_SYMBOLS = new Set(['WETH', 'WBTC', 'PAXG']);

const client = createPublicClient({
  chain: mainnet,
  transport: http(MAINNET_RPC_URL),
});

const dataResource = createResource(async () => {
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
        collateralized: new Amount(VY, 0n),
        notCollateral: true
      }
    }

    // Collateral asset — parse remaining results (indices 2..4)
    const spotPrice = get(2, 'getAssetTwapPrice', 0n);
    const assetView = results[3].status === 'success'
      ? results[3].result as unknown as { ltv: bigint; reserveBalance: bigint; totalLoaned: bigint }
      : (() => { errors.push(`getAssetView: ${(results[3].error as Error).message ?? 'reverted'}`); return { ltv: 0n, reserveBalance: 0n, totalLoaned: 0n }; })();
    const { reserveBalance, totalLoaned } = assetView;
    const defaultMetrics = { totalReserve: 0n, collateralCap: 0n, ltvRatio: 0n, ltvF: 0n, utilized: 0n, available: 0n };
    const metrics = results[4].status === 'success'
      ? results[4].result as unknown as typeof defaultMetrics
      : (() => { warnings.push(`getAssetMetrics: ${(results[4].error as Error).message ?? 'reverted'}`); return defaultMetrics; })();
    const { ltvRatio: ltv, ltvF: ltvf, collateralCap: cap, utilized: collateralized } = metrics;

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
      collateralized: new Amount(VY, collateralized)
    }
  }));

  const overviewErrors: string[] = [];
  const overviewWarnings: string[] = [];

  const pairAddress = (addresses as Record<string, Address>)['UniswapV2Pair_VY_USDC'];
  const vyTokenAddress = (addresses as Record<string, Address>)['ValinityToken'];
  const pairAbi = [
    { inputs: [], name: 'getReserves', outputs: [{ name: 'reserve0', type: 'uint112' }, { name: 'reserve1', type: 'uint112' }, { name: 'blockTimestampLast', type: 'uint32' }], stateMutability: 'view', type: 'function' },
    { inputs: [], name: 'token0', outputs: [{ name: '', type: 'address' }], stateMutability: 'view', type: 'function' },
  ] as const;
  const pairConfig = { abi: pairAbi, address: pairAddress };

  const overviewResults = await client.multicall({
    contracts: [
      { ...vyTokenConfig, functionName: 'totalSupply' },
      { ...vaoConfig, functionName: 'getMTP' },
      { ...pairConfig, functionName: 'getReserves' },
      { ...pairConfig, functionName: 'token0' },
    ],
    allowFailure: true
  });

  const vyTotalSupply = overviewResults[0].status === 'success'
    ? overviewResults[0].result as bigint
    : (() => { overviewErrors.push(`totalSupply: ${(overviewResults[0].error as Error).message ?? 'reverted'}`); return 0n; })();
  const mtp = overviewResults[1].status === 'success'
    ? overviewResults[1].result
    : (() => { overviewWarnings.push(`getMTP: Uniswap pools likely not configured yet`); return 'Pending configuration'; })();

  const USDC: Currency = { symbol: 'USDC', decimals: 6 };
  let vyReserve = 0n;
  let usdcReserve = 0n;
  if (overviewResults[2].status === 'success' && overviewResults[3].status === 'success') {
    const [reserve0, reserve1] = overviewResults[2].result as [bigint, bigint, number];
    const token0 = overviewResults[3].result as Address;
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

  let tvl = 0n;
  for (const asset of assets) {
    tvl += (asset.reserveBalanceUSD.value as bigint) + (asset.totalLoanedUSD.value as bigint);
  }

  // Check if any collateral asset has config warnings (pools not ready)
  const hasConfigWarnings = overviewWarnings.length > 0 ||
    assets.some(a => a.isCollateral && a.warnings && a.warnings.length > 0);

  return {
    overview: {
      'VY Total Supply': new Amount(VY, vyTotalSupply),
      'Total Uncollateralized': new Amount(VY, totalUncollateralized),
      TVL: new Amount(USD, tvl),
      MTP: mtp
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
  };
});

export default function Testnet() {
  return (
    <Suspense fallback={<p style={{ textAlign: 'center' }}>Loading...</p>}>
      <Content />
    </Suspense>
  )
}

function Content() {
  const data = dataResource.read();

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
        <h2>Pool (VY/USDC)</h2>
        <div className="box">
          {renderValues(data.pool)}
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
  transform?: (key: string, value: unknown) => unknown
): JSX.Element {
  return (
    <table>
      <tbody>
        {Object.entries(data).map(([key, value]) => (
          <tr key={key}>
            <td >
              <strong>{startCase(key)}</strong>
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

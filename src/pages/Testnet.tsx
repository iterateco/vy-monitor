import flatten from 'lodash/flatten';
import omit from 'lodash/omit';
import startCase from 'lodash/startCase';
import { Suspense, type JSX } from 'react';
import { createPublicClient, getContract, http, type Address } from 'viem';
import { sepolia } from 'viem/chains';
import { Value } from '../components/core';
import { CONTRACT_ACRONYMS, TESTNET_RPC_URL } from '../config';
import { Amount, USD, VY } from '../models';
import networks from '../networks';
import { getRegisteredAddresses } from '../resources/getContractAddresses';
import createResource from '../utils/createResource';

const client = createPublicClient({
  chain: sepolia,
  transport: http(TESTNET_RPC_URL),
});

const dataResource = createResource(async () => {
  const networkName = 'sepolia';
  const { abis, addresses: staticAddrs } = networks[networkName]
  const registeredAddrs = await getRegisteredAddresses(client, networkName);
  const addresses = { ...staticAddrs, ...registeredAddrs };

  const getContractConfig = <T extends keyof typeof abis>(name: T, address?: Address) => {
    return {
      abi: abis[name],
      address: address ?? addresses[name as keyof typeof addresses]
    }
  }

  const _getContract = <T extends keyof typeof abis>(name: T, address?: Address) => {
    return getContract({
      ...getContractConfig(name, address),
      client
    });
  }

  const assetRegistry = _getContract('ValinityAssetRegistry');
  const vyTokenConfig = getContractConfig('ValinityToken');
  const vaoConfig = getContractConfig('ValinityAcquisitionOfficer');
  const vcoConfig = getContractConfig('ValinityCapOfficer');
  const vloConfig = getContractConfig('ValinityLoanOfficer');

  const assetAddrs = await assetRegistry.read.getAssets();

  const assets = await Promise.all(assetAddrs.map(async assetAddr => {
    const tokenConfig = getContractConfig('ERC20', assetAddr);
    const [
      decimals,
      symbol,
      spotPrice,
      { ltv, reserveBalance, totalLoaned },
      ltvf,
      cap,
      collateralized
    ] = await client.multicall({
      contracts: [
        { ...tokenConfig, functionName: 'decimals' },
        { ...tokenConfig, functionName: 'symbol' },
        { ...vaoConfig, functionName: 'getSpotPriceUSD', args: [assetAddr] },
        { ...vloConfig, functionName: 'getAssetView', args: [assetAddr] },
        { ...vaoConfig, functionName: 'getLTVF', args: [assetAddr] },
        { ...vcoConfig, functionName: 'getAssetCap', args: [assetAddr] },
        { ...vcoConfig, functionName: 'getAssetCollateralized', args: [assetAddr] }
      ],
      allowFailure: false
    });

    const currency = { symbol, decimals };
    const scaleFactor = BigInt(10) ** BigInt(18 - decimals);

    return {
      symbol,
      currency,
      address: assetAddr,
      spotPrice: new Amount(USD, spotPrice),
      LTV: ltv,
      LTVF: new Amount(USD, ltvf),
      reserveBalance: new Amount(currency, reserveBalance),
      reserveBalanceUSD: new Amount(USD, ((reserveBalance * scaleFactor) * spotPrice) / BigInt(1e18)),
      totalLoaned: new Amount(currency, totalLoaned),
      totalLoanedUSD: new Amount(USD, ((totalLoaned * scaleFactor) * spotPrice) / BigInt(1e18)),
      cap: new Amount(VY, cap),
      collateralized: new Amount(VY, collateralized)
    }
  }));

  const [
    vyTotalSupply,
    mtp,
  ] = await client.multicall({
    contracts: [
      { ...vyTokenConfig, functionName: 'totalSupply' },
      { ...vaoConfig, functionName: 'getMTP' }
    ],
    allowFailure: false
  });

  const tokenHolders = [
    'ValinityAcquisitionTreasury',
    'ValinityReserveTreasury',
    'ValinityCapOfficer',
    'Comptroller'
  ] as const;

  const tokenHolderReads = tokenHolders.map(name => {
    return [
      {
        ...vyTokenConfig,
        functionName: 'balanceOf',
        args: [addresses[name]]
      },
      ...assets.map(asset => ({
        abi: abis.ERC20,
        address: asset.address,
        functionName: 'balanceOf',
        args: [addresses[name]]
      }))
    ]
  });

  const balancesResult = await client.multicall({
    contracts: flatten(tokenHolderReads),
    allowFailure: false
  }) as bigint[]

  const balanceMap = {} as { [K in typeof tokenHolders[number]]: Amount<bigint>[] }
  const balancesResultBatchLen = assets.length + 1;

  for (let i = 0; i < tokenHolders.length; i++) {
    const holder = tokenHolders[i];
    const balances = balancesResult.slice(
      i * balancesResultBatchLen,
      balancesResultBatchLen + i * balancesResultBatchLen
    );
    balanceMap[holder] = balances.map((balance, j) => {
      const currency = j === 0 ? VY : assets[j - 1].currency;
      return new Amount(currency, balance);
    })
  }

  const totalUncollateralized = (
    vyTotalSupply -
    balanceMap.ValinityAcquisitionTreasury[0].value -
    balanceMap.ValinityReserveTreasury[0].value -
    balanceMap.ValinityCapOfficer[0].value
  );

  let tvl = 0n;
  for (const asset of assets) {
    tvl += (asset.reserveBalanceUSD.value as bigint) + (asset.totalLoanedUSD.value as bigint);
  }

  return {
    overview: {
      'VY Total Supply': new Amount(VY, vyTotalSupply),
      'Total Uncollateralized': new Amount(VY, totalUncollateralized),
      TVL: new Amount(USD, tvl),
      MTP: mtp
    },
    balanceMap,
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
        <div className="box">
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
        <h2>Assets</h2>
        {data.assets.map(({ symbol, ...values }) => (
          <div key={symbol} className="box">
            <h3>{symbol}</h3>
            {renderValues(values)}
          </div>
        ))}
      </div>
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

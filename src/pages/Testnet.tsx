import startCase from 'lodash/startCase';
import { Suspense, type JSX } from 'react';
import { createPublicClient, getContract, http, type Address } from 'viem';
import { sepolia } from 'viem/chains';
import { Value } from '../components/core';
import { TESTNET_RPC_URL } from '../config';
import { Amount, USD, VY } from '../models';
import networks from '../networks';
import { getContractAddresses } from '../resources/getContractAddresses';
import createResource from '../utils/createResource';

const client = createPublicClient({
  chain: sepolia,
  transport: http(TESTNET_RPC_URL),
});

const dataResource = createResource(async () => {
  const networkName = 'sepolia';
  const { abis } = networks[networkName]
  const addresses = await getContractAddresses(client, networkName);

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

    const assetCurrency = { symbol, decimals };

    return {
      symbol,
      address: assetAddr,
      spotPrice: new Amount(USD, spotPrice),
      LTV: ltv,
      LTVF: new Amount(USD, ltvf),
      reserveBalance: new Amount(assetCurrency, reserveBalance),
      reserveBalanceUSD: new Amount(USD, (reserveBalance * spotPrice) / BigInt(1e18)),
      totalLoaned: new Amount(assetCurrency, totalLoaned),
      totalLoanedUSD: new Amount(USD, (totalLoaned * spotPrice) / BigInt(1e18)),
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

  const vyBalancesResult = await client.multicall({
    contracts: Object.values(addresses).map((address) => ({
      ...vyTokenConfig,
      functionName: 'balanceOf',
      args: [address]
    })),
    allowFailure: false
  });

  const vyBalances = {} as { [K in keyof typeof addresses]: bigint };
  Object.keys(addresses).forEach((name, i) => {
    vyBalances[name as keyof typeof addresses] = vyBalancesResult[i] as bigint;
  });

  const totalUncollateralized = (
    vyTotalSupply - vyBalances.ValinityAcquisitionTreasury - vyBalances.ValinityReserveTreasury - vyBalances.ValinityCapOfficer
  );

  let tvl = 0n;
  for (const asset of assets) {
    tvl += (asset.reserveBalanceUSD.value as bigint) + (asset.totalLoanedUSD.value as bigint);
  }

  return {
    VYTotalSupply: new Amount(VY, vyTotalSupply),
    totalUncollateralized: new Amount(VY, totalUncollateralized),
    TVL: new Amount(USD, tvl),
    MTP: mtp,
    assets,
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
  const { assets, ...rest } = data;

  return (
    <div className="monitor">
      <div>
        <h2>Summary</h2>
        <div className="box">
          {renderValues(rest)}
        </div>
      </div>

      <div>
        <h2>Assets</h2>
        {assets.map(({ symbol, ...values }) => (
          <div key={symbol} className="box">
            <h3>{symbol}</h3>
            {renderValues(values)}
          </div>
        ))}
      </div>
    </div>
  )
}

function renderValues(data: object): JSX.Element {
  return (
    <table>
      {Object.entries(data).map(([key, value]) => (
        <tr key={key}>
          <td >
            <strong>{startCase(key)}</strong>
          </td>
          <td>
            <Value>{value}</Value>
          </td>
        </tr>
      ))}
    </table>
  );
}

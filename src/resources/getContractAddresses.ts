import { keccak256, toBytes, type Address, type PublicClient } from 'viem';
import networks from '../networks';

export async function getRegisteredAddresses(client: PublicClient, networkName: keyof typeof networks) {
  const { abis, registeredContractNames, addresses: staticAddresses } = networks[networkName];

  const registeredAddresses = await client.multicall({
    contracts: registeredContractNames.map(name => ({
      address: staticAddresses.ValinityRegistrar,
      abi: abis.ValinityRegistrar,
      functionName: 'getContract',
      args: [keccak256(toBytes(name))]
    })),
    allowFailure: false
  });

  const addresses = {} as { [K in typeof registeredContractNames[number]]: Address };
  registeredContractNames.forEach((name, i) => {
    addresses[name] = registeredAddresses[i];
  });

  return addresses;
}

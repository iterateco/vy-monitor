import common from '../common';

export default {
  abis: {
    ...common.abis
  },
  registeredContractNames: [
    ...common.registeredContractNames
  ],
  addresses: {
    ValinityRegistrar: '0x0000000000000000000000000000000000000000'
  }
} as const;

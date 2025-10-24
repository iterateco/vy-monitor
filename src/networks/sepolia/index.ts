import common from '../common';

export default {
  abis: {
    ...common.abis
  },
  registeredContractNames: [
    ...common.registeredContractNames
  ],
  addresses: {
    ValinityRegistrar: '0x025a45c77FE16f5e11f75b1a3E438EE7cE05AE51'
  }
} as const;

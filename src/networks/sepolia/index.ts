import common from '../common';
import ValinityAcquisitionOfficer from './ValinityAcquisitionOfficer';
import ValinityAssetRegistry from './ValinityAssetRegistry';
import ValinityCapOfficer from './ValinityCapOfficer';
import ValinityLoanOfficer from './ValinityLoanOfficer';

export default {
  abis: {
    ...common.abis,
    ValinityAcquisitionOfficer,
    ValinityAssetRegistry,
    ValinityCapOfficer,
    ValinityLoanOfficer
  },
  registeredContractNames: [
    ...common.registeredContractNames
  ],
  addresses: {
    ValinityRegistrar: '0x025a45c77FE16f5e11f75b1a3E438EE7cE05AE51',
    Comptroller: '0xEc2Ec9668aEde69996eE17821094d16a2257d1b4',
  }
} as const;

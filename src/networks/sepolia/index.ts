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
    ValinityRegistrar: '0x32eD520bca8798B21f6eF9514c2f0a752a573598',
    Comptroller: '0xEc2Ec9668aEde69996eE17821094d16a2257d1b4',
  }
} as const;

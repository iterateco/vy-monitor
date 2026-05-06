import common from '../common';
import addresses from './addresses.json';
import assets from './assets.json';
import ValinityAcquisitionOfficer from './ValinityAcquisitionOfficer';
import ValinityCapOfficer from './ValinityCapOfficer';
import ValinityLoanOfficer from './ValinityLoanOfficer';

export default {
  abis: {
    ...common.abis,
    ValinityAcquisitionOfficer,
    ValinityCapOfficer,
    ValinityLoanOfficer
  },
  addresses,
  assets
} as const;

import common from '../common';
import addresses from './addresses.json';
import assets from './assets.json';
import ValinityAcquisitionOfficer from './ValinityAcquisitionOfficer';
import ValinityBalanceSheetOfficer from './ValinityBalanceSheetOfficer';
import ValinityCapOfficer from './ValinityCapOfficer';
import ValinityLoanOfficer from './ValinityLoanOfficer';
import ValinityMarketMakerOfficer from './ValinityMarketMakerOfficer';
import ValinityReserveYieldOfficer from './ValinityReserveYieldOfficer';

export default {
  abis: {
    ...common.abis,
    ValinityAcquisitionOfficer,
    ValinityBalanceSheetOfficer,
    ValinityCapOfficer,
    ValinityLoanOfficer,
    ValinityMarketMakerOfficer,
    ValinityReserveYieldOfficer
  },
  addresses,
  assets
} as const;

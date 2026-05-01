import common from '../common';
import addresses from './addresses.json';
import assets from './assets.json';
import ValinityAcquisitionOfficer from './ValinityAcquisitionOfficer';
import ValinityCapOfficer from './ValinityCapOfficer';
import ValinityLoanOfficer from './ValinityLoanOfficer';
import ValinityReserveYieldOfficer from './ValinityReserveYieldOfficer';
import ValinityLiquidityManager from './ValinityLiquidityManager';
import { NonfungiblePositionManager, UniswapV3Pool } from './UniswapV3';

export default {
  abis: {
    ...common.abis,
    ValinityAcquisitionOfficer,
    ValinityCapOfficer,
    ValinityLoanOfficer,
    ValinityReserveYieldOfficer,
    ValinityLiquidityManager,
    NonfungiblePositionManager,
    UniswapV3Pool
  },
  addresses,
  assets
} as const;

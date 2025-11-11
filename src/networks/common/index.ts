import abis from './abis';

export default {
  abis: abis,
  registeredContractNames: [
    'ValinityAssetRegistry',
    'ValinityToken',
    'ValinityAcquisitionTreasury',
    'ValinityReserveTreasury',
    'ValinityAcquisitionOfficer',
    'ValinityCapOfficer',
    'ValinityLoanOfficer',
    'ValinityPortal'
  ]
} as const;


const isDev = import.meta.env.DEV;

export const MAINNET_RPC_URL = isDev ? '/api-mainnet/rpc-proxy' : 'https://api.valinity.io/rpc-proxy'
export const TESTNET_RPC_URL = isDev ? '/api-testnet/rpc-proxy' : 'https://api-dev.valinity.io/rpc-proxy'

export const MAINNET_API_URL = isDev ? '/api-mainnet' : 'https://api.valinity.io'
export const TESTNET_API_URL = isDev ? '/api-testnet' : 'https://api-dev.valinity.io'

export const CONTRACT_ACRONYMS: Record<string, string> = {
  Admin: 'Admin',
  ValinityToken: 'VY',
  ValinityYieldTreasury: 'VYT',
  ValinityReserveTreasury: 'VRT',
  ValinityCapOfficer: 'VCO',
  ValinityLoanOfficer: 'VLO',
  ValinityAcquisitionOfficer: 'VAO',
  ValinityPortal: 'VP',
  VDAX: 'VDAX',
  ValinityDAX: 'VDAX',
  ValinityGovernanceCommittee: 'VGC',
  ValinityExecutor: 'VE',
  ValinityGovernanceOfficer: 'VGO',
  ValinityMEVBot: 'VMEV',
  ValinityBuybackOfficer: 'VBO',
  ValinityDCAOfficer: 'VDCA',
  ValinityYieldOfficer: 'VYO',
  ValinityStakingRouter: 'VSR'
}

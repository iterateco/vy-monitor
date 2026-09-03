const isDev = import.meta.env.DEV;

export const MAINNET_RPC_URL = isDev ? '/api-mainnet/rpc-proxy' : 'https://api.valinity.io/rpc-proxy'
export const TESTNET_RPC_URL = isDev ? '/api-testnet/rpc-proxy' : 'https://api-dev.valinity.io/rpc-proxy'

/**
 * Shared HTTP tuning for the on-chain clients.
 *
 * viem's defaults — 10s timeout, 3 retries, 150ms base backoff — are sized for a
 * healthy endpoint: they give up after ~1s of retrying. During the 2026-09-03
 * Alchemy incident the proxy answered healthy calls in 6-29s and 403'd or 504'd
 * the rest, so all four attempts landed inside the same bad window and the page
 * died on a blip. A wider timeout and a backoff measured in seconds ride out a
 * provider wobble instead of surfacing it. Backoff is (1 << n) * retryDelay, so
 * this retries over ~10.5s before failing.
 */
export const RPC_HTTP_OPTS = {
  timeout: 25_000,
  retryCount: 4,
  retryDelay: 700,
} as const;

export const MAINNET_API_URL = isDev ? '/api-mainnet' : 'https://api.valinity.io'
export const TESTNET_API_URL = isDev ? '/api-testnet' : 'https://api-dev.valinity.io'

export const CONTRACT_ACRONYMS: Record<string, string> = {
  Admin: 'Admin',
  ValinityToken: 'VY',
  ValinityYieldTreasury: 'VYT',
  ValinityCollateralTreasury: 'VCT',
  ValinityCapOfficer: 'VCO',
  ValinityLoanOfficer: 'VLO',
  ValinityBalanceSheetOfficer: 'VBSO',
  // Same address as the former Acquisition Officer — it is now the Asset Oracle.
  // Old "VAO" dashboards mean the opposite thing.
  ValinityAssetOracle: 'VAO',
  ValinityAcquisitionOfficer: 'VAO',
  ValinityMarketStabilityOfficer: 'VMSO',
  ValinityMarketMakerOfficer: 'VMMO',
  VyTwapOracle: 'VY TWAP',
  LoanLens: 'Lens',
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

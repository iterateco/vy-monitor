export interface Currency {
  symbol: string
  decimals?: number
}

export const USD: Currency = { symbol: 'USD', decimals: 18 }
export const VY: Currency = { symbol: 'VY', decimals: 18 }
export const VDAX: Currency = { symbol: 'VDAX', decimals: 18 }
export const UNI_LP: Currency = { symbol: 'UNI-LP', decimals: 18 }

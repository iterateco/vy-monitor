export interface Currency {
  symbol: string
  decimals?: number
}

export const USD: Currency = { symbol: 'USD', decimals: 18 }
export const VY: Currency = { symbol: 'VY', decimals: 18 }

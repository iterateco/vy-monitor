import { etherUnits, formatUnits } from 'viem';
import { Amount } from '../models';

export interface FormatValueOptions {
  includeSybmol?: boolean
}

export function formatValue(value: unknown, options?: FormatValueOptions) {
  const currency = value instanceof Amount ? value.currency : undefined;
  value = value instanceof Amount ? value.value : value;
  let formatted: string

  if (typeof value === 'bigint') {
    value = parseFloat(formatUnits(value, currency?.decimals ?? etherUnits.wei));
  }
  if (typeof value === 'number') {
    const fractionDigits = (currency?.symbol === 'USD' || currency?.symbol === 'USDC') ? 3 : 5;
    formatted = value.toLocaleString('en', {
      minimumFractionDigits: fractionDigits,
      maximumFractionDigits: fractionDigits
    });
  } else {
    formatted = String(value);
  }

  if (currency && options?.includeSybmol !== false) {
    formatted += ` ${currency.symbol}`;
  }

  return formatted;
}

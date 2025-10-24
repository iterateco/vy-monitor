import { etherUnits, formatUnits } from 'viem';
import { Amount } from '../models';

export function formatValue(value: unknown) {
  const currency = value instanceof Amount ? value.currency : undefined;
  value = value instanceof Amount ? value.value : value;
  let formatted: string

  if (typeof value === 'bigint') {
    value = parseFloat(formatUnits(value, currency?.decimals ?? etherUnits.wei));
  }
  if (typeof value === 'number') {
    formatted = value.toLocaleString('en', {
      maximumFractionDigits: 18
    });
  } else {
    formatted = String(value);
  }

  if (currency) {
    formatted += ` ${currency.symbol}`;
  }

  return formatted;
}

import { type Currency } from './Currency';

export class Amount<T = number | bigint> {
  currency: Currency;
  value: T;

  constructor(currency: Currency, value: T) {
    this.currency = currency;
    this.value = value;
  }
}

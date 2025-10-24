import { type Currency } from './Currency';

export class Amount {
  currency: Currency;
  value: number | bigint;

  constructor(currency: Currency, value: number | bigint) {
    this.currency = currency;
    this.value = value;
  }
}

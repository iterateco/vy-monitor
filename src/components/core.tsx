import { formatValue, type FormatValueOptions } from '../utils/formatValue';

export interface ValueProps extends FormatValueOptions {
  children: unknown
}

export function Value({ children, ...options }: ValueProps) {
  return (
    <span>{formatValue(children, options)}</span>
  )
}

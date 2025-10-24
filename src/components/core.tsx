import { formatValue } from '../utils/formatValue';

export interface ValueProps {
  children: unknown
}

export function Value({ children }: ValueProps) {
  return (
    <span>{formatValue(children)}</span>
  )
}

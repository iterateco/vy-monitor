import { formatValue, type FormatValueOptions } from '../utils/formatValue';

export interface ValueProps extends FormatValueOptions {
  children: unknown
}

export function Value({ children, ...options }: ValueProps) {
  return (
    <span>{formatValue(children, options)}</span>
  )
}

export interface BandIndicatorProps {
  /** -100 = at lower band, 0 = mid, +100 = at upper band. May exceed range when out-of-range. */
  positionPct: number;
  /** Optional human-readable labels next to the gauge */
  upperLabel?: string;
  midLabel?: string;
  lowerLabel?: string;
  currentLabel?: string;
}

export function BandIndicator({
  positionPct,
  upperLabel,
  midLabel,
  lowerLabel,
  currentLabel,
}: BandIndicatorProps) {
  const W = 220;
  const H = 160;
  const padTop = 12;
  const padBot = 12;
  const trackX = 70;
  const trackTop = padTop;
  const trackBot = H - padBot;
  const trackHeight = trackBot - trackTop;
  const midY = trackTop + trackHeight / 2;

  // Map % (top = +100, bottom = -100) → y. Clamp dot position to slightly outside the track if OOR.
  const clamped = Math.max(-110, Math.min(110, positionPct));
  const dotY = midY - (clamped / 100) * (trackHeight / 2);

  const absPct = Math.abs(positionPct);
  const oor = absPct > 100;
  const color = oor ? '#e74c3c' : absPct >= 80 ? '#e74c3c' : absPct >= 50 ? '#f39c12' : '#2ecc71';

  // 20% gridlines from -100..+100
  const gridlines: { pct: number; y: number; major: boolean }[] = [];
  for (let p = -100; p <= 100; p += 20) {
    gridlines.push({ pct: p, y: midY - (p / 100) * (trackHeight / 2), major: p === 0 || Math.abs(p) === 100 });
  }

  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12 }}>
      <svg width={W} height={H} style={{ overflow: 'visible' }}>
        {/* Track */}
        <line x1={trackX} y1={trackTop} x2={trackX} y2={trackBot} stroke="#444" strokeWidth={2} />

        {/* Gridlines + labels */}
        {gridlines.map(g => (
          <g key={g.pct}>
            <line
              x1={trackX - (g.major ? 14 : 6)}
              y1={g.y}
              x2={trackX + (g.major ? 14 : 6)}
              y2={g.y}
              stroke={g.major ? '#888' : '#444'}
              strokeWidth={g.major ? 2 : 1}
            />
            <text
              x={trackX - 18}
              y={g.y + 3}
              textAnchor="end"
              fontSize={g.major ? 11 : 9}
              fill={g.major ? '#ccc' : '#777'}
            >
              {g.pct === 0 ? '0' : `${Math.abs(g.pct)}`}
            </text>
          </g>
        ))}

        {/* Top/bottom band labels */}
        {upperLabel && (
          <text x={trackX + 22} y={trackTop + 4} fontSize={10} fill="#aaa">{upperLabel}</text>
        )}
        {midLabel && (
          <text x={trackX + 22} y={midY + 4} fontSize={10} fill="#888">{midLabel}</text>
        )}
        {lowerLabel && (
          <text x={trackX + 22} y={trackBot + 4} fontSize={10} fill="#aaa">{lowerLabel}</text>
        )}

        {/* Current position dot */}
        <circle cx={trackX} cy={dotY} r={4} fill={color} stroke="#fff" strokeWidth={1} />
        {currentLabel && (
          <text x={trackX + 22} y={dotY + 4} fontSize={11} fill={color} fontWeight="bold">{currentLabel}</text>
        )}

        {/* OOR badge */}
        {oor && (
          <text x={trackX} y={H - 2} textAnchor="middle" fontSize={11} fill="#e74c3c" fontWeight="bold">
            OUT OF RANGE
          </text>
        )}
      </svg>

      <div style={{ fontSize: '0.75rem', lineHeight: 1.5 }}>
        <div><strong>Band Position</strong></div>
        <div style={{ color }}>
          {oor ? 'Out of range' : `${positionPct >= 0 ? '+' : ''}${positionPct.toFixed(1)}%`}
        </div>
        <div style={{ color: '#888', marginTop: 6 }}>
          0% = mid<br />
          ±100% = band edge
        </div>
      </div>
    </div>
  );
}

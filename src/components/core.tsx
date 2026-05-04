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
  /** Configured band width in % (e.g. 10 for a ±10% band). Shown below band position. */
  bandWidthPct?: number;
  /** Optional human-readable labels next to the gauge */
  upperLabel?: string;
  midLabel?: string;
  lowerLabel?: string;
  currentLabel?: string;
}

export function BandIndicator({
  positionPct,
  bandWidthPct,
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
        <line x1={trackX} y1={trackTop} x2={trackX} y2={trackBot} stroke="#888" strokeWidth={2} />

        {/* Gridlines + labels */}
        {gridlines.map(g => (
          <g key={g.pct}>
            <line
              x1={trackX - (g.major ? 14 : 6)}
              y1={g.y}
              x2={trackX + (g.major ? 14 : 6)}
              y2={g.y}
              stroke="#888"
              strokeOpacity={g.major ? 1 : 0.5}
              strokeWidth={g.major ? 2 : 1}
            />
            <text
              x={trackX - 18}
              y={g.y + 3}
              textAnchor="end"
              fontSize={g.major ? 11 : 9}
              fill="currentColor"
              fillOpacity={g.major ? 0.85 : 0.55}
            >
              {g.pct === 0 ? '0' : `${Math.abs(g.pct)}`}
            </text>
          </g>
        ))}

        {/* Top/bottom band labels */}
        {upperLabel && (
          <text x={trackX + 22} y={trackTop + 4} fontSize={10} fill="currentColor" fillOpacity={0.7}>{upperLabel}</text>
        )}
        {midLabel && (
          <text x={trackX + 22} y={midY + 4} fontSize={10} fill="currentColor" fillOpacity={0.55}>{midLabel}</text>
        )}
        {lowerLabel && (
          <text x={trackX + 22} y={trackBot + 4} fontSize={10} fill="currentColor" fillOpacity={0.7}>{lowerLabel}</text>
        )}

        {/* Current position dot */}
        <circle cx={trackX} cy={dotY} r={4} fill={color} stroke="currentColor" strokeOpacity={0.4} strokeWidth={1} />
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
        <div style={{ opacity: 0.6, marginTop: 6 }}>
          0% = mid<br />
          ±100% = band edge
        </div>
        {bandWidthPct !== undefined && (
          <>
            <div style={{ marginTop: 6 }}><strong>Band Width</strong></div>
            <div style={{ opacity: 0.8 }}>{`±${bandWidthPct.toFixed(2)}%`}</div>
          </>
        )}
      </div>
    </div>
  );
}

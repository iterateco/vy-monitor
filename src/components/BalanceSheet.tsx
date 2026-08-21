/**
 * VBSO balance-sheet presentation.
 *
 * THREE NUMBERS, published together on purpose — never one alone. Shown left to
 * right as projected · market · floor, so the market price sits between the
 * optimistic projection and the conservative floor:
 *
 *   projected  VBSO.projectedVyPrice()          — where VY prices out once VMMO
 *                                                 spends its whole book
 *   market     sheet.usdPerVy                   — what VY trades at now
 *   floor_hard hardEquityUsd / circulating VY   — coins actually held, net staker debt
 *
 * The projection is a MECHANICAL buy-pressure calculation, not a forecast: it
 * assumes zero opposing flow for the entire deploy window, and much of the
 * liquidity it buys from is protocol-owned. The contract's own NatSpec requires
 * it to be shown with the inputs that produce it, so the tile carries ammo,
 * window and multiple inline — they are not optional decoration.
 *
 * floor (full) — equity ÷ circulating, which counts the covered loan book — was
 * removed from this panel on request. It read ~$1.22 against a ~$0.33 market
 * while being ~95% composed of loans collateralised in VY, i.e. a claim about VY
 * priced in VY. The underlying equity rows are still shown in the sheet below.
 */

export type Floors = {
  projected: number | null;
  projectedAmmoUsd: number;
  projectedWindowSec: number;
  projectedMultiple: number;
  projectedError: string | null;
  hard: number;
  borrowUsdPerVy: number;
  ltvBps: number;
  maxLoanVy: number;
  market: number;
  circulating: number;
  equityUsd: number;
  hardEquityUsd: number;
  hardAssetsUsd: number;
  coveredLoansUsd: number;
  loansFaceUsd: number;
  stakerDebtUsd: number;
  mcapUsd: number;
};

const fmtDays = (sec: number) => {
  const d = sec / 86_400;
  return d >= 1 ? `${d.toFixed(1)} days` : `${(sec / 3600).toFixed(1)} h`;
};

const fmtUsd = (n: number, dp = 4) =>
  n >= 1000
    ? '$' + n.toLocaleString('en-US', { maximumFractionDigits: 0 })
    : '$' + n.toFixed(dp);

export function BackingTiles({ floors }: { floors: Floors }) {
  return (
    <>
      <div className="vy-tiles">
        <div className="vy-tile">
          <div className="vy-tile__label">
            <span className="vy-swatch" style={{ background: 'var(--vy-series-1)' }} />
            Projected
          </div>
          <div className="vy-tile__value" style={{ color: 'var(--vy-series-1)' }}>
            {floors.projected == null ? '—' : fmtUsd(floors.projected)}
          </div>
          {floors.projected == null ? (
            <div className="vy-tile__caveat">{floors.projectedError ?? 'unavailable'}</div>
          ) : (
            <>
              <div className="vy-tile__hint">
                {floors.projectedMultiple.toFixed(2)}× live · once VMMO deploys its book
              </div>
              <div className="vy-tile__caveat">
                ammo {fmtUsd(floors.projectedAmmoUsd, 0)} over {fmtDays(floors.projectedWindowSec)}
              </div>
            </>
          )}
        </div>

        <div className="vy-tile">
          <div className="vy-tile__label">
            <span className="vy-swatch" style={{ background: 'var(--vy-ink-2)' }} />
            Market
          </div>
          <div className="vy-tile__value" style={{ color: 'var(--vy-ink-2)' }}>
            {fmtUsd(floors.market)}
          </div>
          <div className="vy-tile__hint">VBSO usdPerVy (TWAP)</div>
          <div className="vy-tile__caveat">what VY actually trades at</div>
        </div>

        <div className="vy-tile">
          <div className="vy-tile__label">
            <span className="vy-swatch" style={{ background: 'var(--vy-series-2)' }} />
            Loan to VY value
          </div>
          <div className="vy-tile__value" style={{ color: 'var(--vy-series-2)' }}>
            {fmtUsd(floors.borrowUsdPerVy)}
          </div>
          <div className="vy-tile__hint">
            per VY posted, at {(floors.ltvBps / 100).toFixed(0)}% LTV
          </div>
          <div className="vy-tile__caveat">
            max {floors.maxLoanVy.toLocaleString('en-US', { maximumFractionDigits: 0 })} VY per loan
          </div>
        </div>

      </div>

    </>
  );
}

// ─────────────────────────────────────────────────────────────
// Holdings / Debt / Invested / Equity
// ─────────────────────────────────────────────────────────────
/**
 * The four-column balance sheet, every input read from VMMO:
 *
 *   HOLDINGS  VMMO.heldOf(asset) — system holdings, all five sources
 *   DEBT      aggReservedAsset + aggWithdrawingAsset — principal + unclaimed yield
 *   INVESTED  USDC debt − USDC held: the part of the USDC book that is not sitting
 *             in USDC, i.e. what was put into WETH/WBTC/PAXG. Exact as a total;
 *             the per-asset split is PRO-RATA on holdings, because nothing on
 *             chain tags which WBTC was bought with which USDC.
 *   EQUITY    holdings − debt − invested, per asset
 *
 * The identity closes both ways: debt + equity == holdings, and
 * (hard holdings − invested − hard debt) == (total holdings − total debt).
 */
export type AssetRow = {
  symbol: string;
  heldNative: string;
  heldUsd: number;
  debtNative: string;
  debtUsd: number;
  investedNative: string | null;
  investedUsd: number;
  equityUsd: number;
};

export type AssetTable = {
  rows: AssetRow[];
  totals: { held: number; debt: number; invested: number; equity: number; ratio: number };
};

const money = (n: number) =>
  '$' + n.toLocaleString('en-US', { maximumFractionDigits: 0 });

function Col({
  title, sub, children, accent,
}: { title: string; sub: string; children: React.ReactNode; accent?: string }) {
  return (
    <div className="vy-col">
      <div className="vy-col__head" style={accent ? { color: accent } : undefined}>{title}</div>
      <div className="vy-col__sub">{sub}</div>
      {children}
    </div>
  );
}

function Cell({ sym, native, usd, muted }: { sym: string; native: string | null; usd: number; muted?: boolean }) {
  return (
    <div className={`vy-cell${muted ? ' vy-cell--muted' : ''}`}>
      <div className="vy-cell__sym">{sym}</div>
      <div className="vy-cell__native">{native ?? '—'}</div>
      <div className="vy-cell__usd">{money(usd)}</div>
    </div>
  );
}

export function HoldingsTable({ table }: { table: AssetTable }) {
  const { rows, totals } = table;
  const hard = rows.filter((r) => r.symbol !== 'USDC');
  const over = totals.held >= totals.debt;

  return (
    <div className="vy-sheet">
      <div className="vy-cols">
        <Col title="Holdings" sub="" accent="var(--vy-series-1)">
          {rows.map((r) => <Cell key={r.symbol} sym={r.symbol} native={r.heldNative} usd={r.heldUsd} />)}
          <div className="vy-col__total">{money(totals.held)}</div>
        </Col>

        <Col title="Debt" sub="principal + unclaimed yield" accent="var(--vy-series-2)">
          {rows.map((r) => <Cell key={r.symbol} sym={r.symbol} native={r.debtNative} usd={r.debtUsd} />)}
          <div className="vy-col__total">{money(totals.debt)}</div>
        </Col>

        <Col title="USDC debt invested" sub="the USDC book held as hard assets">
          <div className="vy-cell vy-cell--muted">
            <div className="vy-cell__sym">USDC</div>
            <div className="vy-cell__native">held as USDC</div>
            <div className="vy-cell__usd">—</div>
          </div>
          {hard.map((r) => <Cell key={r.symbol} sym={r.symbol} native={r.investedNative} usd={r.investedUsd} />)}
          <div className="vy-col__total">{money(totals.invested)}</div>
        </Col>

        <Col title="Equity" sub="held, beyond every debt">
          <div className="vy-cell vy-cell--muted">
            <div className="vy-cell__sym">USDC</div>
            <div className="vy-cell__native">fully owed</div>
            <div className="vy-cell__usd">{money(0)}</div>
          </div>
          {hard.map((r) => (
            <div className="vy-cell" key={r.symbol}>
              <div className="vy-cell__sym">{r.symbol}</div>
              <div className="vy-cell__native">&nbsp;</div>
              <div className="vy-cell__usd">{money(r.equityUsd)}</div>
            </div>
          ))}
          <div className="vy-col__total">{money(totals.equity)}</div>
        </Col>
      </div>

      <div className={`vy-verdict${over ? '' : ' vy-verdict--bad'}`}>
        <span className="vy-verdict__mark">{over ? '✓' : '✗'}</span>
        <span>
          <strong>{money(totals.held)}</strong> held against{' '}
          <strong>{money(totals.debt)}</strong> owed —{' '}
          <strong>{totals.ratio.toFixed(2)}×</strong>{' '}
          {over ? 'overcollateralized' : 'UNDERCOLLATERALIZED'}, equity{' '}
          <strong>{money(totals.equity)}</strong>
        </span>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Era ladder
// ─────────────────────────────────────────────────────────────
/**
 * Market-cap ratchet. The reached rung carries the check; the rest are targets.
 *
 * Each rung shows the interest ceiling it unlocks. The rate is the premium anchor
 * (read live) scaled by that era's multiplier, so the ladder steps DOWN as the
 * market cap grows: 100% of anchor at era 0, then 80.28 / 64.44 / 51.94 / 41.67%.
 * Those multipliers are `internal pure` in the contract and cannot be read, so
 * they are transcribed here — and the rung for the CURRENT era is checked against
 * the live `eraMaxBps`. A mismatch is shown rather than silently printed wrong.
 */
export function EraLadder({
  era, mcapUsd, anchorBps, liveEraMaxBps,
}: { era: number; mcapUsd: number; anchorBps: number; liveEraMaxBps: number }) {
  const rungs = [
    { era: 0, label: 'Era 0', threshold: 0, multBps: 10_000 },
    { era: 1, label: '$7M', threshold: 7_000_000, multBps: 8_028 },
    { era: 2, label: '$70M', threshold: 70_000_000, multBps: 6_444 },
    { era: 3, label: '$700M', threshold: 700_000_000, multBps: 5_194 },
    { era: 4, label: '$7B', threshold: 7_000_000_000, multBps: 4_167 },
  ].map((r) => ({
    ...r,
    // Math.floor replicates the contract's uint16 truncation — without it era 1
    // prints 14.26% where the chain says 14.25%.
    ratePct: Math.floor((anchorBps * r.multBps) / 10_000) / 100,
    relPct: r.multBps / 100,
  }));

  const next = rungs.find((r) => r.era === era + 1);
  const current = rungs.find((r) => r.era === era);
  // 1 bp of tolerance: the contract floors the multiply, we do not.
  const drift =
    current && Math.abs(current.ratePct * 100 - liveEraMaxBps) > 1;

  return (
    <div className="vy-ladder-wrap">
      <div className="vy-ladder">
        {rungs.map((r) => (
          <div
            key={r.era}
            className={`vy-rung${r.era === era ? ' vy-rung--now' : ''}${r.era < era ? ' vy-rung--done' : ''}`}
          >
            <div className="vy-rung__top">
              <span className="vy-rung__mark">{r.era <= era ? '✓' : ''}</span>
              {r.label}
            </div>
            <div className="vy-rung__rate">{r.ratePct.toFixed(2)}%</div>
            <div className="vy-rung__rel">{r.relPct.toFixed(0)}% of anchor</div>
          </div>
        ))}
      </div>
      <div className="vy-ladder__note">
        Max interest steps down as market cap grows.{' '}
        {next && (
          <>
            {money(mcapUsd)} of {money(next.threshold)} to era {next.era} — which
            would cut the ceiling from {current?.ratePct.toFixed(2)}% to{' '}
            {next.ratePct.toFixed(2)}%.
          </>
        )}
        {drift && (
          <strong style={{ color: 'var(--vy-cliff-ink, #e34948)' }}>
            {' '}Ladder disagrees with on-chain eraMaxBps ({(liveEraMaxBps / 100).toFixed(2)}%)
            — multiplier table is stale.
          </strong>
        )}
      </div>
    </div>
  );
}

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
  /** Days until 99% of today's book has deployed — the horizon the projected price belongs to. */
  projectedDaysTo99: number | null;
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
  /** VBSO.vyOracle() — read live, so the tile cites whatever oracle is actually wired. */
  vyOracle: string | null;
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
                ammo {fmtUsd(floors.projectedAmmoUsd, 0)}
                {floors.projectedDaysTo99 !== null && (
                  <> · 99% deployed in {floors.projectedDaysTo99} days</>
                )}
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
          <div className="vy-tile__hint">what VY actually trades at</div>
          <div className="vy-tile__caveat">
            price read from the official Valinity{' '}
            {floors.vyOracle ? (
              <a href={`https://etherscan.io/address/${floors.vyOracle}`} target="_blank" rel="noreferrer">
                price oracle contract
              </a>
            ) : 'price oracle contract'}
          </div>
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
 *             Debt is shown against the asset that BACKS it: the USDC book's
 *             invested slice (USDC debt − USDC held, split pro-rata on holdings
 *             because nothing on chain tags which WBTC came from which USDC)
 *             moves onto WETH/WBTC/PAXG.
 *   EQUITY    holdings − debt, per asset
 *
 * Every row reconciles: holdings − debt = equity, and the totals do too.
 */
export type AssetRow = {
  symbol: string;
  heldNative: string;
  heldUsd: number;
  debtNative: string;
  debtUsd: number;
  equityUsd: number;
};

export type AssetTable = {
  rows: AssetRow[];
  totals: { held: number; debt: number; equity: number; ratio: number };
};

// Minus sign OUTSIDE the dollar sign — `'$' + (-20921).toLocaleString()` would
// render "$-20,921". Rows can legitimately go negative now that debt is shown per
// asset rather than spread, so this is a live path, not a defensive branch.
const money = (n: number) =>
  (n < 0 ? '\u2212$' : '$') + Math.abs(n).toLocaleString('en-US', { maximumFractionDigits: 0 });

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
  const over = totals.held >= totals.debt;

  return (
    <div className="vy-sheet">
      <div className="vy-cols">
        <Col title="Holdings" sub="total ecosystem holdings" accent="var(--vy-series-1)">
          {rows.map((r) => <Cell key={r.symbol} sym={r.symbol} native={r.heldNative} usd={r.heldUsd} />)}
          <div className="vy-col__total">{money(totals.held)}</div>
        </Col>

        <Col title="Debt" sub="principal + unclaimed yield, per asset" accent="var(--vy-series-2)">
          {rows.map((r) => <Cell key={r.symbol} sym={r.symbol} native={r.debtNative} usd={r.debtUsd} />)}
          <div className="vy-col__total">{money(totals.debt)}</div>
        </Col>

        <Col title="Equity" sub="holdings minus debt">
          {rows.map((r) => (
            <div className="vy-cell" key={r.symbol}>
              <div className="vy-cell__sym">{r.symbol}</div>
              <div className="vy-cell__native">&nbsp;</div>
              <div className={`vy-cell__usd${r.equityUsd < 0 ? ' vy-cell__usd--neg' : ''}`}>
                {money(r.equityUsd)}
              </div>
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
export type AssetMult = { symbol: string; multBps: number };

export function EraLadder({
  era, mcapUsd, anchorBps, liveEraMaxBps, assetMults, tier3TermDays,
}: {
  era: number; mcapUsd: number; anchorBps: number; liveEraMaxBps: number;
  assetMults: AssetMult[]; tier3TermDays: number;
}) {
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
      {/* States the BASIS on the right, where the eye lands after the rungs. These
          are ceilings at the top tier over its full term — not an APY and not what
          a tier 1 stake quotes — so the qualifier travels with the numbers. */}
      <div className="vy-ladder__head">
        <span>Max yield ceiling per asset</span>
        {tier3TermDays > 0 && (
          <span className="vy-ladder__term">
            premium tier 3 · total over a <strong>{tier3TermDays}-day</strong> term
          </span>
        )}
      </div>
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

            {assetMults.length > 0 && (
              <div className="vy-rung__assets">
                {assetMults.map((a) => {
                  // Math.floor twice: the contract truncates to uint16 at each step.
                  const capBps = Math.floor((anchorBps * r.multBps) / 10_000);
                  const bps = Math.floor((capBps * a.multBps) / 10_000);
                  // Bars are scaled against ONE fixed reference — the anchor at era 0,
                  // which is USDC's ceiling — so a bar's length means the same thing in
                  // every rung and the staircase is visible across the whole ladder.
                  // Scaling per-rung would make every rung look identical.
                  const w = Math.max(2, (bps / anchorBps) * 100);
                  return (
                    <div className="vy-arate" key={a.symbol}>
                      <span className="vy-arate__sym">{a.symbol}</span>
                      <span className="vy-arate__track">
                        <span className="vy-arate__fill" style={{ width: `${w}%` }} />
                      </span>
                      <span className="vy-arate__pct">{(bps / 100).toFixed(2)}%</span>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        ))}

        {/* Sixth cell, filling the space the five rungs leave. It carries the
            market cap that DRIVES the ratchet plus the explanation, so cause and
            effect sit on one line instead of the reader pairing a figure at the
            bottom of the section with a ladder at the top. */}
        <div className="vy-rung vy-rung--note">
          <div className="vy-rung__top">Market cap</div>
          <div className="vy-mcap">{money(mcapUsd)}</div>
          <div className="vy-rung__note-body">
            Max interest steps down as market cap grows.{' '}
            {next && (
              <>
                {money(next.threshold - mcapUsd)} more reaches era {next.era},
                cutting the ceiling from {current?.ratePct.toFixed(2)}% to{' '}
                {next.ratePct.toFixed(2)}%.
              </>
            )}
            {!next && <>Final era — the ceiling does not step down again.</>}
          </div>
          {drift && (
            <div className="vy-rung__drift">
              Ladder disagrees with on-chain eraMaxBps
              ({(liveEraMaxBps / 100).toFixed(2)}%) — multiplier table is stale.
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Trading volume
// ─────────────────────────────────────────────────────────────
export type VolumeRow = {
  symbol: string;
  day: number; month: number; all: number;
  dayCount: number; monthCount: number; allCount: number;
};

export type VolumeData = {
  rows: VolumeRow[];
  totals: { day: number; month: number; all: number };
  txCount: { day: number; month: number; all: number };
};

/**
 * Asset flow through each venue, in USD. Historical flow is valued at TODAY's
 * marks — per-trade historical pricing is not available from a transfer log, so
 * the all-time column is "what that flow is worth now", not what it was worth
 * when it happened. The 24h column is unaffected in practice.
 */
export function TradingVolume({
  volume, progress,
}: { volume: VolumeData | null; progress: { done: number; total: number } | null }) {
  if (!volume) {
    return (
      <div className="vy-vol">
        <div className="vy-vol__title">
        Trading volume{' '}
        <a
          href="https://etherscan.io/token/0x597b29520098d6aaca3B2e0D1a380315c9240454"
          target="_blank"
          rel="noreferrer"
          style={{ fontWeight: 'normal', textTransform: 'none', letterSpacing: 0 }}
        >
          VY ↗ Etherscan
        </a>
      </div>
        <div className="vy-vol__loading">
          {progress && progress.total > 0
            ? `indexing VY transactions… ${progress.done.toLocaleString('en-US')} / ${progress.total.toLocaleString('en-US')}`
            : 'reading transfer logs…'}
        </div>
      </div>
    );
  }
  const { rows, totals } = volume;
  return (
    <div className="vy-vol">
      <div className="vy-vol__title">
        Trading volume{' '}
        <a
          href="https://etherscan.io/token/0x597b29520098d6aaca3B2e0D1a380315c9240454"
          target="_blank"
          rel="noreferrer"
          style={{ fontWeight: 'normal', textTransform: 'none', letterSpacing: 0 }}
        >
          VY ↗ Etherscan
        </a>
      </div>
      <table className="vy-vol__table">
        <thead>
          <tr>
            <th />
            <th>24h</th>
            <th>30d</th>
            <th>All time</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.symbol}>
              <td className="vy-vol__sym">{r.symbol}</td>
              <td>{money(r.day)}</td>
              <td>{money(r.month)}</td>
              <td>{money(r.all)}</td>
            </tr>
          ))}
          <tr className="vy-vol__total">
            <td>Total</td>
            <td>{money(totals.day)}</td>
            <td>{money(totals.month)}</td>
            <td>{money(totals.all)}</td>
          </tr>
        </tbody>
      </table>
      <div className="vy-vol__note">
        every USDC/WBTC/WETH/PAXG leg inside a VY transaction ({volume.txCount.all.toLocaleString('en-US')} txs
        indexed), valued at today's marks.
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Market-maker desk
// ─────────────────────────────────────────────────────────────

export type DeskRow = {
  symbol: string;
  heldNative: string;
  heldUsd: number;
  readyNative: string;
  readyUsd: number;
  lastAccrual: number;
};

export type ProjPoint = {
  label: string;
  deployedPct: number;
  priceUsd: number;
};

export type Desk = {
  deployWindowSec: number;
  stalestAccrual: number;
  rows: DeskRow[];
  totalHeldUsd: number;
  totalReadyUsd: number;
  projCurve: { livePriceUsd: number; rows: ProjPoint[] } | null;
  errors: string[];
};

/**
 * The desk's own book, not the same coins valued again.
 *
 * `held` is inventory sitting on the officer awaiting deployment; the drip
 * releases it over `deployWindow`, and `ready` is the slice released so far.
 * Read as a pair they answer "how much dry powder, and how much of it can move
 * today" — which is the question the projected-price tile's ammo figure begs.
 */
export function MarketMakerDesk({ desk }: { desk: Desk }) {

  return (
    <div className="vy-desk">
      <div className="vy-desk__head">
        <div>
          <div className="vy-desk__label">Undeployed book</div>
          <div className="vy-desk__big">{fmtUsd(desk.totalHeldUsd, 0)}</div>
        </div>
        <div>
          <div className="vy-desk__label">Ready to deploy</div>
          <div className="vy-desk__big">{fmtUsd(desk.totalReadyUsd, 0)}</div>
        </div>
        <div>
          <div className="vy-desk__label">Deploy window</div>
          <div className="vy-desk__big">{fmtDays(desk.deployWindowSec)}</div>
        </div>
      </div>

      <table className="vy-desk__table">
        <thead>
          <tr>
            <th />
            <th>holdings</th>
            <th>ready to deploy</th>
          </tr>
        </thead>
        <tbody>
          {desk.rows.map((r) => (
            <tr key={r.symbol}>
              <td><strong>{r.symbol}</strong></td>
              <td>
                {r.heldNative}
                <span className="vy-desk__usd">{fmtUsd(r.heldUsd, 0)}</span>
              </td>
              <td>
                {r.readyNative}
                <span className="vy-desk__usd">{fmtUsd(r.readyUsd, 0)}</span>
              </td>

            </tr>
          ))}
        </tbody>
      </table>

      {desk.projCurve && (
        <div className="vy-proj">
          <div className="vy-proj__title">
            Projected VY as the book deploys
            <span className="vy-proj__tag">projection · not a forecast</span>
          </div>

          <table className="vy-desk__table">
            <thead>
              <tr>
                <th />
                <th>book deployed</th>
                <th>projected VY</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {desk.projCurve.rows.map((r) => {
                const x = r.priceUsd / desk.projCurve!.livePriceUsd;
                return (
                  <tr key={r.label}>
                    <td><strong>{r.label}</strong></td>
                    <td>{r.deployedPct.toFixed(1)}%</td>
                    <td>{fmtUsd(r.priceUsd)}</td>
                    <td className="vy-proj__x">{x.toFixed(2)}×</td>
                  </tr>
                );
              })}
            </tbody>
          </table>

        </div>
      )}
    </div>
  );
}

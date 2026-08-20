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

const fmtUsd = (n: number, dp = 4) =>
  n >= 1000
    ? '$' + n.toLocaleString('en-US', { maximumFractionDigits: 0 })
    : '$' + n.toFixed(dp);

const fmtDays = (sec: number) => {
  const d = sec / 86_400;
  return d >= 1 ? `${d.toFixed(1)} days` : `${(sec / 3600).toFixed(1)} h`;
};

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
            Floor (hard)
          </div>
          <div className="vy-tile__value" style={{ color: 'var(--vy-series-2)' }}>
            {fmtUsd(floors.hard)}
          </div>
          <div className="vy-tile__hint">hard equity ÷ circulating VY</div>
          <div className="vy-tile__caveat">coins actually held, net staker debt</div>
        </div>
      </div>

      {floors.projected != null && (
        <div className="vy-note">
          <strong>Projected is not a forecast.</strong> It walks VMMO's entire{' '}
          {fmtUsd(floors.projectedAmmoUsd, 0)} book forward through the venues at
          constant product and reports the resulting price. It assumes{' '}
          <strong>zero opposing flow</strong> for the whole{' '}
          {fmtDays(floors.projectedWindowSec)} window — no sellers, no arbitrage — so
          realised price will be lower. Much of the liquidity it buys from is
          protocol-owned, meaning part of the move is the treasury transacting with
          itself, and it assumes WETH/WBTC/PAXG hold their prices. It answers "how
          far can our own capital move this", not "what will VY trade at".
        </div>
      )}
    </>
  );
}

/**
 * Valinity Asset Oracle — staleness watch.
 *
 * The VAO is the protocol's only source of USD prices for WBTC / PAXG / WETH,
 * read from Uniswap V3 30-minute TWAPs. It is fail-closed: if a pool's newest
 * observation is older than `maxObservationAge`, it REVERTS rather than serve a
 * price that stopped tracking the market. Correct — but a quiet pool halts lending.
 *
 * Two failure styles:
 *   loud   — VLO/VLOLegacyLib/LoanLens/VCO/VBSO hard-revert. Users notice.
 *   silent — VMMOCoverageLib/VMMOVenueLib swallow it and return 0/NO_PRICE. The
 *            market maker just stops rebalancing. This monitor is the only thing
 *            that makes that half visible.
 *
 * Goal: alert BEFORE the trip, not after.
 *
 *   node oracle-watch.mjs           # poll forever (default 60s)
 *   node oracle-watch.mjs --once    # single tick, then exit
 *
 * Exit code: 2 if any CRITICAL is live, 1 if any WARN, 0 if clean.
 * Env: RPC_URL, INTERVAL_MS, COOLDOWN_S, INFO_PCT, WARN_PCT.
 */

import { createPublicClient, http, decodeErrorResult, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';

// ─── Config ──────────────────────────────────────────────────
const RPC_URL     = process.env.RPC_URL     ?? 'https://api.valinity.io/rpc-proxy';
const INTERVAL_MS = Number(process.env.INTERVAL_MS ?? 60_000);
const COOLDOWN_S  = Number(process.env.COOLDOWN_S  ?? 1_800); // re-nag interval while still bad
const INFO_PCT    = Number(process.env.INFO_PCT ?? 0.50);
const WARN_PCT    = Number(process.env.WARN_PCT ?? 0.80);
const HYSTERESIS  = 0.90; // clear a level only after dropping to 90% of its entry threshold
const CARD_MARGIN = Number(process.env.CARD_MARGIN ?? 20); // WARN when observationCardinality < minCardinality + this

const ONCE = process.argv.includes('--once');

// ─── Addresses ───────────────────────────────────────────────
const VAO          = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const VAO_IMPL     = '0x2bA7F751fC9A1F5C6f5a89fce45b52926d96D2dd'; // alert if this changes
const VLO          = '0x8Fd8d5eB23f520D9BF8863364Ed44dbb29769DE4';
const UNIV3_FACTORY = '0x1F98431c8aD98523631AE4a59f267346ea31F984';

const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'; // EIP-1967

const TOKENS = {
  WBTC: { address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', decimals: 8 },
  PAXG: { address: '0x45804880De22913dAFE09f4980848ECE6EcbAf78', decimals: 18 },
  WETH: { address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', decimals: 18 },
  USDC: { address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
};
const SYMBOL = Object.fromEntries(
  Object.entries(TOKENS).map(([sym, t]) => [t.address.toLowerCase(), sym])
);

/** Only these are configured. canPrice(DAI) == false is correct behaviour, not a fault. */
const ASSETS = ['WBTC', 'PAXG', 'WETH'];

/** Baseline pools, for config-drift detection only. The polled pool is always the
 *  one the oracle actually resolves to via assetTwapQuoteToken/assetTwapFeeTier. */
const EXPECTED_POOLS = {
  'WBTC/WETH': '0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0',
  'WETH/USDC': '0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640', // SHARED: WBTC prices through it too
  'PAXG/USDC': '0x5aE13BAAEF0620FdaE1D355495Dc51a17adb4082', // the thin one
};

// ─── ABIs (minimal) ──────────────────────────────────────────
const vaoAbi = [
  { type: 'function', name: 'oracleGuards', stateMutability: 'view', inputs: [],
    outputs: [{ type: 'uint32', name: 'maxAge' }, { type: 'uint16', name: 'minCardinality' }] },
  { type: 'function', name: 'canPrice', stateMutability: 'view', inputs: [{ type: 'address' }],
    outputs: [{ type: 'bool', name: 'ok' }, { type: 'bytes', name: 'reason' }] },
  { type: 'function', name: 'getAssetTwapPrice', stateMutability: 'view', inputs: [{ type: 'address' }],
    outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'assetTwapQuoteToken', stateMutability: 'view', inputs: [{ type: 'address' }],
    outputs: [{ type: 'address' }] },
  { type: 'function', name: 'assetTwapFeeTier', stateMutability: 'view', inputs: [{ type: 'address' }],
    outputs: [{ type: 'uint24' }] },
];

const vloAbi = [
  { type: 'function', name: 'getLTV', stateMutability: 'view', inputs: [{ type: 'address', name: 'asset' }],
    outputs: [{ type: 'uint256' }] },
];

const factoryAbi = [
  { type: 'function', name: 'getPool', stateMutability: 'view',
    inputs: [{ type: 'address' }, { type: 'address' }, { type: 'uint24' }],
    outputs: [{ type: 'address' }] },
];

const poolAbi = [
  { type: 'function', name: 'slot0', stateMutability: 'view', inputs: [], outputs: [
    { type: 'uint160', name: 'sqrtPriceX96' }, { type: 'int24', name: 'tick' },
    { type: 'uint16', name: 'observationIndex' }, { type: 'uint16', name: 'observationCardinality' },
    { type: 'uint16', name: 'observationCardinalityNext' }, { type: 'uint8', name: 'feeProtocol' },
    { type: 'bool', name: 'unlocked' }] },
  { type: 'function', name: 'observations', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [
    { type: 'uint32', name: 'blockTimestamp' }, { type: 'int56', name: 'tickCumulative' },
    { type: 'uint160', name: 'secondsPerLiquidityCumulativeX128' }, { type: 'bool', name: 'initialized' }] },
];

const ZERO = '0x0000000000000000000000000000000000000000';
const client = createPublicClient({ chain: mainnet, transport: http(RPC_URL) });

// ─── Alert state machine ─────────────────────────────────────
// Alerts are edge-triggered and keyed. A key only prints when its level CHANGES,
// or when it has been sitting non-OK for COOLDOWN_S. PAXG crosses the INFO line
// most nights; that must cost one line, not one line per minute.
const LEVELS = { OK: 0, INFO: 1, WARN: 2, CRITICAL: 3 };
const state = new Map(); // key -> { level, since, lastEmit, msg }
const tickSeen = new Set();
let rpcFailStreak = 0;
let lastGuards = null;

/** One alert = one line. viem revert text is multi-line; grep/tail must stay usable. */
function oneLine(s) {
  return String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 300);
}

function stamp(blockTs) {
  return new Date(Number(blockTs) * 1000).toISOString().replace('.000Z', 'Z');
}

function report(key, level, rawMsg, blockTs) {
  const msg = oneLine(rawMsg);
  tickSeen.add(key);
  const prev = state.get(key) ?? { level: 'OK', since: blockTs, lastEmit: 0 };
  const changed = prev.level !== level;
  const stale = level !== 'OK' && Number(blockTs) - prev.lastEmit >= COOLDOWN_S;

  if (changed) {
    if (level === 'OK') {
      const held = Number(blockTs) - Number(prev.since);
      console.log(`${stamp(blockTs)}  RESOLVED  ${key}  (was ${prev.level} for ${fmtDur(held)}) — ${msg}`);
      state.delete(key);
      return;
    }
    state.set(key, { level, since: blockTs, lastEmit: Number(blockTs), msg });
    console.log(`${stamp(blockTs)}  ${level.padEnd(8)}  ${key}  ${msg}`);
    return;
  }

  if (level === 'OK') { state.delete(key); return; }
  state.set(key, { ...prev, level, msg, lastEmit: stale ? Number(blockTs) : prev.lastEmit });
  if (stale) {
    const held = Number(blockTs) - Number(prev.since);
    console.log(`${stamp(blockTs)}  ${level.padEnd(8)}  ${key}  ${msg}  (ongoing ${fmtDur(held)})`);
  }
}

/** A key that stopped being reported (e.g. an asset dropped from config) must not
 *  linger as a live alert. */
function sweep(blockTs) {
  for (const key of [...state.keys()]) {
    if (key.startsWith('monitor:')) continue; // owned by the runner, not by a tick
    if (!tickSeen.has(key)) {
      console.log(`${stamp(blockTs)}  RESOLVED  ${key}  (no longer reported)`);
      state.delete(key);
    }
  }
}

function worstLevel() {
  let worst = 'OK';
  for (const { level } of state.values()) if (LEVELS[level] > LEVELS[worst]) worst = level;
  return worst;
}

function fmtDur(s) {
  s = Math.max(0, Math.round(s));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m${String(s % 60).padStart(2, '0')}s`;
  return `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m`;
}

/** Level from age, with hysteresis: a key already at WARN stays at WARN until age
 *  drops to 90% of the WARN threshold. Stops flapping around the boundary. */
function ageLevel(age, maxAge, prevLevel) {
  const warnAt = maxAge * WARN_PCT;
  const infoAt = maxAge * INFO_PCT;
  const p = LEVELS[prevLevel ?? 'OK'];
  if (age >= warnAt || (p >= LEVELS.WARN && age >= warnAt * HYSTERESIS)) return 'WARN';
  if (age >= infoAt || (p >= LEVELS.INFO && age >= infoAt * HYSTERESIS)) return 'INFO';
  return 'OK';
}

/** canPrice returns raw revert data. Surface it in whatever form it came in. */
function decodeReason(data) {
  if (!data || data === '0x') return 'no reason';
  try {
    const d = decodeErrorResult({ abi: [], data });
    return `${d.errorName}(${(d.args ?? []).join(', ')})`;
  } catch {}
  if (data.startsWith('0x08c379a0')) {
    try {
      const { args } = decodeErrorResult({
        abi: [{ type: 'error', name: 'Error', inputs: [{ type: 'string' }] }], data,
      });
      return `"${args[0]}"`;
    } catch {}
  }
  return `selector ${data.slice(0, 10)}`;
}

// ─── Tick ────────────────────────────────────────────────────
async function tick() {
  tickSeen.clear();

  const block = await client.getBlock();
  const blockNumber = block.number;
  const blockTs = block.timestamp;

  // ── 1. Guards + implementation slot ────────────────────────
  const [guardsRes, implRaw] = await Promise.all([
    client.readContract({ address: VAO, abi: vaoAbi, functionName: 'oracleGuards', blockNumber }),
    client.getStorageAt({ address: VAO, slot: IMPL_SLOT, blockNumber }),
  ]);

  // Read live every tick. Guards are admin-tunable and have already changed once;
  // a monitor holding a stale copy of the threshold disagrees with the chain about
  // whether anything is wrong, which is worse than no monitor.
  const [maxAge, minCardinality] = guardsRes;

  const impl = '0x' + implRaw.slice(-40);
  report('vao:implementation',
    impl.toLowerCase() === VAO_IMPL.toLowerCase() ? 'OK' : 'CRITICAL',
    impl.toLowerCase() === VAO_IMPL.toLowerCase()
      ? `back to expected ${VAO_IMPL}`
      : `VAO implementation is ${impl}, expected ${VAO_IMPL} — unannounced upgrade`,
    blockTs);

  const guardsKey = `${maxAge}/${minCardinality}`;
  if (lastGuards !== null && lastGuards !== guardsKey) {
    report('vao:guards', 'WARN',
      `oracleGuards changed ${lastGuards} → ${guardsKey} (maxAge/minCardinality)`, blockTs);
  } else if (lastGuards === guardsKey) {
    report('vao:guards', 'OK', `oracleGuards stable at ${guardsKey}`, blockTs);
  }
  lastGuards = guardsKey;

  // ── 2. Per-asset oracle + loan-book agreement ──────────────
  const assetCalls = ASSETS.flatMap((sym) => {
    const a = TOKENS[sym].address;
    return [
      { address: VAO, abi: vaoAbi, functionName: 'canPrice', args: [a] },
      { address: VAO, abi: vaoAbi, functionName: 'getAssetTwapPrice', args: [a] },
      { address: VAO, abi: vaoAbi, functionName: 'assetTwapQuoteToken', args: [a] },
      { address: VAO, abi: vaoAbi, functionName: 'assetTwapFeeTier', args: [a] },
      { address: VLO, abi: vloAbi, functionName: 'getLTV', args: [a] },
    ];
  });
  const assetRes = await client.multicall({ contracts: assetCalls, allowFailure: true, blockNumber });

  const assets = {};
  ASSETS.forEach((sym, i) => {
    const [canPrice, price, quote, fee, ltv] = assetRes.slice(i * 5, i * 5 + 5);
    assets[sym] = {
      ok: canPrice.status === 'success' ? canPrice.result[0] : null,
      reason: canPrice.status === 'success' ? canPrice.result[1] : null,
      canPriceFailed: canPrice.status !== 'success',
      price: price.status === 'success' ? price.result : null,
      quote: quote.status === 'success' ? quote.result : null,
      fee: fee.status === 'success' ? Number(fee.result) : null,
      ltvOk: ltv.status === 'success',
      ltv: ltv.status === 'success' ? ltv.result : null,
      ltvErr: ltv.status === 'success' ? null : (ltv.error?.shortMessage ?? String(ltv.error)),
    };
  });

  for (const sym of ASSETS) {
    const a = assets[sym];

    // canPrice never reverts by design; if it did, the proxy itself is wrong.
    if (a.canPriceFailed) {
      report(`asset:${sym}:canPrice`, 'CRITICAL', `canPrice(${sym}) itself reverted — VAO is not answering`, blockTs);
    } else {
      report(`asset:${sym}:canPrice`,
        a.ok ? 'OK' : 'CRITICAL',
        a.ok ? `pricing again` : `oracle is REFUSING ${sym} now — ${decodeReason(a.reason)}`,
        blockTs);
    }

    // canPrice is the cheap gate the silent consumers (VMMO*) rely on. If it says
    // yes and the actual price read still reverts, the gate is lying and the market
    // maker will keep asking for a price it can never get.
    report(`asset:${sym}:priceRead`,
      a.ok === true && a.price == null ? 'CRITICAL' : 'OK',
      a.ok === true && a.price == null
        ? `canPrice(${sym}) says OK but getAssetTwapPrice(${sym}) reverted — the gate disagrees with the read`
        : `price read agrees with canPrice`,
      blockTs);

    report(`asset:${sym}:getLTV`,
      a.ltvOk ? 'OK' : 'CRITICAL',
      a.ltvOk ? `loan book pricing again` : `VLO.getLTV(${sym}) reverted — loan book is halted: ${a.ltvErr}`,
      blockTs);
  }

  // ── 3. Resolve the pools the oracle ACTUALLY uses ──────────
  // Hops are derived from on-chain config, not assumed: WBTC quotes in WETH, so it
  // prices through two pools and depends on WETH's hop as well.
  const hops = [];      // { label, tokenA, tokenB, fee, deps:Set<sym> }
  const addHop = (aSym, bSym, fee, dep) => {
    const label = `${aSym}/${bSym}`;
    const found = hops.find((h) => h.label === label && h.fee === fee);
    if (found) { found.deps.add(dep); return found; }
    const hop = { label, tokenA: TOKENS[aSym].address, tokenB: TOKENS[bSym].address, fee, deps: new Set([dep]) };
    hops.push(hop);
    return hop;
  };

  for (const sym of ASSETS) {
    const a = assets[sym];
    if (!a.quote || a.quote === ZERO || a.fee == null) {
      report(`asset:${sym}:config`, 'CRITICAL',
        `${sym} has no TWAP config on the oracle (quoteToken=${a.quote}, feeTier=${a.fee})`, blockTs);
      continue;
    }
    report(`asset:${sym}:config`, 'OK', `configured`, blockTs);

    const quoteSym = SYMBOL[a.quote.toLowerCase()] ?? a.quote;
    addHop(sym, quoteSym, a.fee, sym);

    // Second hop: anything not already quoted in USDC prices through the quote
    // token's own pool, and inherits its staleness.
    if (quoteSym !== 'USDC') {
      const q = ASSETS.includes(quoteSym) ? assets[quoteSym] : null;
      if (q?.quote && q.quote !== ZERO && q.fee != null) {
        addHop(quoteSym, SYMBOL[q.quote.toLowerCase()] ?? q.quote, q.fee, sym);
        report(`asset:${sym}:route`, 'OK', `2-hop route fully monitored`, blockTs);
      } else {
        // Refuse to look healthy while half the route is invisible.
        report(`asset:${sym}:route`, 'WARN',
          `${sym} quotes in ${quoteSym}, which is not a monitored asset — its ${quoteSym}→USD hop is NOT being watched`,
          blockTs);
      }
    } else {
      report(`asset:${sym}:route`, 'OK', `direct USDC route`, blockTs);
    }
  }

  const poolAddrs = await client.multicall({
    contracts: hops.map((h) => ({
      address: UNIV3_FACTORY, abi: factoryAbi, functionName: 'getPool', args: [h.tokenA, h.tokenB, h.fee],
    })),
    allowFailure: true, blockNumber,
  });

  const pools = [];
  hops.forEach((h, i) => {
    const addr = poolAddrs[i].status === 'success' ? poolAddrs[i].result : ZERO;
    if (addr === ZERO) {
      report(`pool:${h.label}`, 'CRITICAL',
        `no Uniswap V3 pool exists for ${h.label} @ ${h.fee / 10_000}% — oracle config points nowhere`, blockTs);
      return;
    }
    const expected = EXPECTED_POOLS[h.label];
    if (expected && addr.toLowerCase() !== expected.toLowerCase()) {
      report(`pool:${h.label}:address`, 'WARN',
        `${h.label} now resolves to ${addr}, baseline was ${expected} — setAssetTwapConfig changed the venue`, blockTs);
    } else if (expected) {
      report(`pool:${h.label}:address`, 'OK', `venue unchanged`, blockTs);
    }
    pools.push({ ...h, address: addr, deps: [...h.deps].sort() });
  });

  // ── 4. Observation age + cardinality ───────────────────────
  const slots = await client.multicall({
    contracts: pools.map((p) => ({ address: p.address, abi: poolAbi, functionName: 'slot0' })),
    allowFailure: true, blockNumber,
  });

  const obsCalls = [];
  pools.forEach((p, i) => {
    if (slots[i].status !== 'success') return;
    p.observationIndex = Number(slots[i].result[2]);
    p.cardinality = Number(slots[i].result[3]);
    p.cardinalityNext = Number(slots[i].result[4]);
    obsCalls.push({
      pool: p,
      call: { address: p.address, abi: poolAbi, functionName: 'observations', args: [BigInt(p.observationIndex)] },
    });
  });

  const obsRes = await client.multicall({
    contracts: obsCalls.map((o) => o.call), allowFailure: true, blockNumber,
  });

  const lines = [];
  pools.forEach((p, i) => {
    if (slots[i].status !== 'success') {
      report(`pool:${p.label}`, 'CRITICAL', `slot0() failed on ${p.address}: ${slots[i].error?.shortMessage}`, blockTs);
      return;
    }
    const o = obsCalls.findIndex((c) => c.pool === p);
    const obs = obsRes[o];
    if (obs.status !== 'success') {
      report(`pool:${p.label}`, 'CRITICAL', `observations() failed on ${p.address}`, blockTs);
      return;
    }
    const [obsTs, , , initialized] = obs.result;

    // Uniswap stores TRUNCATED uint32 timestamps: subtract with wrapping, or the
    // monitor breaks at the 2106 rollover and on any near-rollover comparison.
    const age = Number(BigInt.asUintN(32, BigInt.asUintN(32, blockTs) - BigInt(obsTs)));

    const pct = maxAge > 0 ? age / maxAge : 0;
    const who = p.deps.join('+');
    const prev = state.get(`pool:${p.label}:age`)?.level;
    const level = initialized ? ageLevel(age, maxAge, prev) : 'CRITICAL';

    const detail = `age ${fmtDur(age)} of ${fmtDur(maxAge)} (${(pct * 100).toFixed(0)}%) — halts ${who}`;
    report(`pool:${p.label}:age`, level,
      initialized
        ? (level === 'OK' ? `fresh again, ${detail}` : detail)
        : `observation slot ${p.observationIndex} is UNINITIALIZED on ${p.address}`,
      blockTs);

    // NOTE: deliberately NOT comparing cardinality to cardinalityNext. The active
    // value lagging next is a grow in progress and fills as the pool trades
    // (PAXG sits at 128 → 300). Alerting on that is a false page lasting hours.
    report(`pool:${p.label}:cardinality`,
      p.cardinality < minCardinality + CARD_MARGIN ? 'WARN' : 'OK',
      p.cardinality < minCardinality + CARD_MARGIN
        ? `observationCardinality ${p.cardinality} is within ${CARD_MARGIN} of the ${minCardinality} floor` +
          (p.cardinalityNext > p.cardinality ? ` (growing to ${p.cardinalityNext})` : '')
        : `cardinality ${p.cardinality} healthy`,
      blockTs);

    lines.push(`  ${p.label.padEnd(11)} ${String(fmtDur(age)).padStart(7)}/${fmtDur(maxAge)} ` +
      `${String(Math.round(pct * 100)).padStart(3)}%  card ${p.cardinality}` +
      (p.cardinalityNext > p.cardinality ? `→${p.cardinalityNext}` : '') +
      `  ${p.address}  [${who}]`);
  });

  sweep(blockTs);
  return { blockNumber, blockTs, maxAge, minCardinality, lines, assets };
}

// ─── Runner ──────────────────────────────────────────────────
function heartbeat(snap) {
  const prices = ASSETS.map((s) => {
    const a = snap.assets[s];
    return `${s} ${a.ok && a.price != null ? '$' + Number(formatUnits(a.price, 18)).toLocaleString('en-US', { maximumFractionDigits: 2 }) : 'NO PRICE'}`;
  }).join('  ');
  console.log(`${stamp(snap.blockTs)}  block ${snap.blockNumber}  guards ${snap.maxAge}s/${snap.minCardinality}  ${prices}  [${worstLevel()}]`);
  for (const l of snap.lines) console.log(l);
}

async function runTick(verbose) {
  try {
    const snap = await tick();
    rpcFailStreak = 0;
    report('monitor:rpc', 'OK', 'RPC healthy', snap.blockTs);
    if (verbose) heartbeat(snap);
    return snap;
  } catch (err) {
    rpcFailStreak++;
    // A blind monitor is itself an incident — say so rather than failing quietly.
    const level = rpcFailStreak >= 3 ? 'CRITICAL' : 'WARN';
    const ts = BigInt(Math.floor(Date.now() / 1000)); // no block available; local clock is the only option
    report('monitor:rpc', level,
      `tick failed ${rpcFailStreak}× — monitor is blind: ${err.shortMessage ?? err.message}`, ts);
    return null;
  }
}

const exitCode = () => ({ OK: 0, INFO: 0, WARN: 1, CRITICAL: 2 })[worstLevel()];

if (ONCE) {
  await runTick(true);
  process.exit(exitCode());
} else {
  console.log(`# oracle-watch — VAO ${VAO} — polling every ${INTERVAL_MS / 1000}s via ${RPC_URL}`);
  let ticks = 0;
  const HEARTBEAT_EVERY = Math.max(1, Math.round(900_000 / INTERVAL_MS)); // full table ~15min
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => { console.log(`# stopping — worst live: ${worstLevel()}`); process.exit(exitCode()); });
  }
  await runTick(true);
  setInterval(async () => { await runTick(++ticks % HEARTBEAT_EVERY === 0); }, INTERVAL_MS);
}

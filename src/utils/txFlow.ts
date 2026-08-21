import type { Address, PublicClient } from 'viem';
import { parseAbiItem } from 'viem';

/**
 * VY TRANSACTION FLOW — the token-tracker measure.
 *
 * Walks every VY Transfer, groups by transaction, and sums every USDC / WBTC /
 * WETH / PAXG transfer that appears in the same transaction.
 *
 * ⚠️ WHAT THIS COUNTS, stated plainly because the number is large and will be
 * read as trading volume: it counts EVERY leg of the transaction, including legs
 * that have nothing to do with VY. VY is routinely swept into MEV bundles — a
 * measured example, tx 0x9fe6710e…, carries 270 logs in which VY moved ~$196
 * while WETH moved ~$128,555 on an unrelated arbitrage path. That $128k is
 * counted here. Measured over 24h this method reads ~157x the asset flow that
 * actually crosses VY's own pools ($226,667 vs $1,443).
 *
 * It is therefore transaction FLOW, not trade volume. Chosen deliberately.
 *
 * COST. 3,132 transactions all-time, ~50ms per receipt at 25-way concurrency —
 * about 2.6 minutes for a cold pass. So results are cached in localStorage as
 * per-transaction native totals and only new blocks are indexed on later runs.
 * Native (not USD) is cached so the history can be re-priced without re-indexing.
 */

const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const transferEvent = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)');

export const FLOW_ASSETS = [
  { symbol: 'USDC', address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
  { symbol: 'WBTC', address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', decimals: 8 },
  { symbol: 'WETH', address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', decimals: 18 },
  { symbol: 'PAXG', address: '0x45804880De22913dAFE09f4980848ECE6EcbAf78', decimals: 18 },
] as const;

const BY_ADDRESS = new Map(FLOW_ASSETS.map((a, i) => [a.address.toLowerCase(), i]));

/** One transaction: block number, then native totals per FLOW_ASSETS index. */
type TxRecord = [number, string, string, string, string];

type Cache = { version: number; lastBlock: number; rows: TxRecord[] };

const CACHE_KEY = 'vy-txflow-v1';
const CACHE_VERSION = 1;
/** VY's first transfer — nothing to index before this. */
const GENESIS_BLOCK = 24_867_000n;
const LOG_CHUNK = 500_000n;   // the RPC rejects an unbounded VY-wide getLogs
const RECEIPT_CONCURRENCY = 25;

function readCache(): Cache {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (raw) {
      const c = JSON.parse(raw) as Cache;
      if (c.version === CACHE_VERSION && Array.isArray(c.rows)) return c;
    }
  } catch { /* corrupt or unavailable — reindex */ }
  return { version: CACHE_VERSION, lastBlock: Number(GENESIS_BLOCK) - 1, rows: [] };
}

function writeCache(c: Cache) {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(c));
  } catch { /* quota — running uncached is correct, just slower */ }
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      for (;;) {
        const i = next++;
        if (i >= items.length) return;
        out[i] = await fn(items[i]);
      }
    }),
  );
  return out;
}

export type FlowProgress = { done: number; total: number };

/**
 * Index every VY transaction up to `head`, resuming from cache.
 * Returns rows sorted by block.
 */
export async function indexTxFlow(
  client: PublicClient,
  vyToken: Address,
  head: bigint,
  onProgress?: (p: FlowProgress) => void,
): Promise<TxRecord[]> {
  const cache = readCache();
  const from = BigInt(cache.lastBlock + 1);
  if (from > head) return cache.rows;

  // 1. VY transfers in the un-indexed range, chunked (an unbounded query 500s).
  const hashes = new Map<string, number>();
  for (let b = from; b <= head; b += LOG_CHUNK) {
    const to = b + LOG_CHUNK - 1n > head ? head : b + LOG_CHUNK - 1n;
    const logs = await client.getLogs({ address: vyToken, event: transferEvent, fromBlock: b, toBlock: to });
    for (const l of logs) {
      if (l.transactionHash && l.blockNumber !== null) hashes.set(l.transactionHash, Number(l.blockNumber));
    }
  }

  // 2. One receipt per transaction; sum every in-scope token leg it contains.
  const list = [...hashes.entries()];
  let done = 0;
  const fresh = await mapLimit(list, RECEIPT_CONCURRENCY, async ([hash, block]) => {
    const sums = [0n, 0n, 0n, 0n];
    try {
      const receipt = await client.getTransactionReceipt({ hash: hash as `0x${string}` });
      for (const log of receipt.logs) {
        const idx = BY_ADDRESS.get(log.address.toLowerCase());
        if (idx === undefined) continue;
        // Must be Transfer — WETH also emits Deposit/Withdrawal from the same address.
        if (log.topics[0] !== TRANSFER_TOPIC || log.topics.length !== 3) continue;
        try { sums[idx] += BigInt(log.data); } catch { /* malformed */ }
      }
    } catch { /* dropped/reorged tx — contributes nothing */ }
    done++;
    if (onProgress && done % 25 === 0) onProgress({ done, total: list.length });
    return [block, sums[0].toString(), sums[1].toString(), sums[2].toString(), sums[3].toString()] as TxRecord;
  });

  const rows = [...cache.rows, ...fresh].sort((a, b) => a[0] - b[0]);
  writeCache({ version: CACHE_VERSION, lastBlock: Number(head), rows });
  onProgress?.({ done: list.length, total: list.length });
  return rows;
}

export type FlowTotals = {
  rows: { symbol: string; day: number; month: number; all: number }[];
  totals: { day: number; month: number; all: number };
  txCount: { day: number; month: number; all: number };
};

/** Bucket cached native totals into windows and price them at current marks. */
export function bucketFlow(
  rows: TxRecord[],
  cutoffs: { day: number; month: number },
  priceOf: Record<string, bigint>,
): FlowTotals {
  const acc = FLOW_ASSETS.map(() => ({ day: 0n, month: 0n, all: 0n }));
  const txCount = { day: 0, month: 0, all: rows.length };

  for (const r of rows) {
    const block = r[0];
    const inDay = block >= cutoffs.day;
    const inMonth = block >= cutoffs.month;
    if (inDay) txCount.day++;
    if (inMonth) txCount.month++;
    for (let i = 0; i < FLOW_ASSETS.length; i++) {
      const v = BigInt(r[i + 1]);
      if (v === 0n) continue;
      acc[i].all += v;
      if (inMonth) acc[i].month += v;
      if (inDay) acc[i].day += v;
    }
  }

  const out = FLOW_ASSETS.map((a, i) => {
    const px = priceOf[a.symbol] ?? 0n;
    const unit = 10n ** BigInt(a.decimals);
    const usd = (v: bigint) => (px === 0n ? 0 : Number((v * px) / unit) / 1e18);
    return { symbol: a.symbol, day: usd(acc[i].day), month: usd(acc[i].month), all: usd(acc[i].all) };
  });

  const sum = (k: 'day' | 'month' | 'all') => out.reduce((n, r) => n + r[k], 0);
  return { rows: out, totals: { day: sum('day'), month: sum('month'), all: sum('all') }, txCount };
}

import type { PublicClient } from 'viem';

/**
 * VY's first transfer. Nothing this app cares about exists before it, so every
 * "full history" scan starts here — asking an archive node for blocks 0..24.8M
 * is ~24.8M blocks of guaranteed-empty work on the single most expensive RPC
 * method there is.
 */
export const VY_GENESIS_BLOCK = 24_867_000n;

/** Window size per getLogs call. Matches src/utils/txFlow.ts. */
export const LOG_CHUNK = 500_000n;

/**
 * Run a getLogs-shaped scan across full VY history in bounded windows.
 *
 * An unbounded `fromBlock: 0n, toBlock: 'latest'` query is the heaviest thing we
 * can ask a provider for, and it is the first request to fail when one is
 * degraded — which is how a single Alchemy wobble took down a page whose other
 * few hundred calls were fine. Chunking keeps each request cheap enough to
 * succeed, and to be retried on its own.
 *
 * The callback keeps viem's log typing intact at the call site.
 */
export async function scanFullHistory<T>(
  client: PublicClient,
  scan: (fromBlock: bigint, toBlock: bigint) => Promise<T[]>,
  fromBlock: bigint = VY_GENESIS_BLOCK,
): Promise<T[]> {
  const head = await client.getBlockNumber();
  const out: T[] = [];
  for (let b = fromBlock; b <= head; b += LOG_CHUNK) {
    const to = b + LOG_CHUNK - 1n > head ? head : b + LOG_CHUNK - 1n;
    out.push(...await scan(b, to));
  }
  return out;
}

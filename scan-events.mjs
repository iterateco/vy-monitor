/**
 * Deep scan: trace all VY mints, acquisitions, cap changes, and fee reductions
 * to find the source of the 7,142 VY gap between circulating and total caps.
 */

import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';

const VY_TOKEN        = '0x597b29520098d6aaca3B2e0D1a380315c9240454';
const VYT             = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974';
const VRT             = '0x06087789B7122fA92E7F9868B10A286Dd4e4C832';
const CAP_OFFICER     = '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C';
const ACQ_OFFICER     = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const PORTAL          = '0xF612C21161F400AbA27A0ef18b030350898b7628';
const DAX             = '0xD256C672616f7c5DEE3e42a8199f121EE08401B7';
const BUYBACK         = '0xD2F0826af20EbDc833c8418E312F23f373F8500e';
const STAKING_ROUTER  = '0x664b3A81C963F07C1eb06516c560f9b2193698C7';
const VY_USDC_POOL    = '0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705';
const DEPLOYER        = '0x8310eA7EC55A7Ad6A4288aF683155A124A524a09';
const ZERO            = '0x0000000000000000000000000000000000000000';

const KNOWN_CONTRACTS = {
  [VYT.toLowerCase()]: 'VYT',
  [VRT.toLowerCase()]: 'VRT',
  [CAP_OFFICER.toLowerCase()]: 'CapOfficer',
  [ACQ_OFFICER.toLowerCase()]: 'AcqOfficer',
  [PORTAL.toLowerCase()]: 'Portal',
  [DAX.toLowerCase()]: 'DAX',
  [BUYBACK.toLowerCase()]: 'Buyback',
  [STAKING_ROUTER.toLowerCase()]: 'StakingRouter',
  [VY_USDC_POOL.toLowerCase()]: 'VyUsdcPool',
  [DEPLOYER.toLowerCase()]: 'Deployer',
  [ZERO]: 'ZERO (mint)',
};

const client = createPublicClient({
  chain: mainnet,
  transport: http('https://api.valinity.io/rpc-proxy'),
});

const fmt = (v) => formatUnits(v, 18);
const label = (addr) => KNOWN_CONTRACTS[addr.toLowerCase()] || addr.slice(0, 10);

async function main() {
  // Find deployment block by looking for VY token creation
  // We'll scan from a reasonable starting block. Let's find the first Transfer event.
  const latestBlock = await client.getBlockNumber();
  console.log(`Latest block: ${latestBlock}\n`);

  // ─── 1. Scan all Transfer events FROM address(0) = mints ───
  console.log('=== 1. VY MINTS (Transfer from 0x0) ===');
  const mintLogs = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: ZERO },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  let totalMinted = 0n;
  for (const log of mintLogs) {
    const { to, value } = log.args;
    totalMinted += value;
    console.log(`  Block ${log.blockNumber}: Minted ${fmt(value)} VY → ${label(to)}`);
  }
  console.log(`  TOTAL MINTED: ${fmt(totalMinted)} VY\n`);

  // ─── 2. Scan all Transfer events TO address(0) = burns ───
  console.log('=== 2. VY BURNS (Transfer to 0x0) ===');
  const burnLogs = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: ZERO },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  let totalBurned = 0n;
  for (const log of burnLogs) {
    const { from, value } = log.args;
    totalBurned += value;
    console.log(`  Block ${log.blockNumber}: Burned ${fmt(value)} VY from ${label(from)}`);
  }
  console.log(`  TOTAL BURNED: ${fmt(totalBurned)} VY\n`);

  // ─── 3. Scan Acquired events (AcquisitionOfficer) ───
  console.log('=== 3. ACQUISITIONS (VY minted + cap created) ===');
  const acquiredLogs = await client.getLogs({
    address: ACQ_OFFICER,
    event: parseAbiItem('event Acquired(address indexed asset, uint8 triggerReason, uint256 vyMinted, uint256 vyNet, uint256 vyFee, uint256 assetAmount, uint256 triggerVYPriceUSD, uint256 triggerAssetPriceUSD, uint256 triggerLTV, uint256 executionVYPriceUSD, uint256 executionAssetPriceUSD, uint256 executionLTV)'),
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  let totalAcqMinted = 0n;
  let totalAcqFees = 0n;
  let totalAcqNet = 0n;
  for (const log of acquiredLogs) {
    const { asset, vyMinted, vyNet, vyFee, triggerReason } = log.args;
    totalAcqMinted += vyMinted;
    totalAcqFees += vyFee;
    totalAcqNet += vyNet;
    const reason = triggerReason === 0 ? 'PriceDisparity' : 'LTVDisparity';
    console.log(`  Block ${log.blockNumber}: ${reason} | asset=${label(asset)} | minted=${fmt(vyMinted)} net=${fmt(vyNet)} fee=${fmt(vyFee)}`);
  }
  console.log(`  TOTAL Acq Minted: ${fmt(totalAcqMinted)} VY`);
  console.log(`  TOTAL Acq Fees:   ${fmt(totalAcqFees)} VY`);
  console.log(`  TOTAL Acq Net:    ${fmt(totalAcqNet)} VY\n`);

  // ─── 4. Scan CapReductionApplied events ───
  console.log('=== 4. CAP REDUCTIONS (tx fee reductions) ===');
  const capReductionLogs = await client.getLogs({
    address: CAP_OFFICER,
    event: parseAbiItem('event CapReductionApplied(address indexed asset, uint256 reductionAmount, uint256 newCap)'),
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  let totalCapReductions = 0n;
  for (const log of capReductionLogs) {
    const { asset, reductionAmount, newCap } = log.args;
    totalCapReductions += reductionAmount;
    console.log(`  Block ${log.blockNumber}: ${label(asset)} reduced by ${fmt(reductionAmount)} → new cap ${fmt(newCap)}`);
  }
  console.log(`  TOTAL Cap Reductions: ${fmt(totalCapReductions)} VY\n`);

  // ─── 5. Scan CapUpdated events ───
  console.log('=== 5. CAP UPDATES (admin / acquisition) ===');
  const capUpdatedLogs = await client.getLogs({
    address: CAP_OFFICER,
    event: parseAbiItem('event CapUpdated(address indexed asset, uint256 oldCap, uint256 newCap)'),
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  for (const log of capUpdatedLogs) {
    const { asset, oldCap, newCap } = log.args;
    const delta = newCap - oldCap;
    console.log(`  Block ${log.blockNumber}: ${label(asset)} ${fmt(oldCap)} → ${fmt(newCap)} (Δ ${delta >= 0n ? '+' : ''}${fmt(delta)})`);
  }
  console.log('');

  // ─── 6. Scan FeesProcessed events ───
  console.log('=== 6. FEES PROCESSED (CapOfficer) ===');
  const feesProcessedLogs = await client.getLogs({
    address: CAP_OFFICER,
    event: parseAbiItem('event FeesProcessed(uint256 amount)'),
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  let totalFeesProcessed = 0n;
  for (const log of feesProcessedLogs) {
    const { amount } = log.args;
    totalFeesProcessed += amount;
    console.log(`  Block ${log.blockNumber}: ${fmt(amount)} VY processed`);
  }
  console.log(`  TOTAL Fees Processed: ${fmt(totalFeesProcessed)} VY\n`);

  // ─── 7. Scan FeesSentToTreasury events ───
  console.log('=== 7. FEES SENT TO TREASURY ===');
  const feesTreasuryLogs = await client.getLogs({
    address: CAP_OFFICER,
    event: parseAbiItem('event FeesSentToTreasury(address indexed treasury, uint256 amount)'),
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  let totalFeesToTreasury = 0n;
  for (const log of feesTreasuryLogs) {
    const { treasury, amount } = log.args;
    totalFeesToTreasury += amount;
    console.log(`  Block ${log.blockNumber}: ${fmt(amount)} VY → ${label(treasury)}`);
  }
  console.log(`  TOTAL Fees to Treasury: ${fmt(totalFeesToTreasury)} VY\n`);

  // ─── 8. Scan all VY transfers FROM VYT and VRT ───
  console.log('=== 8. VY OUTFLOWS FROM TREASURIES ===');
  const vytOutflows = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: VYT },
    fromBlock: 0n,
    toBlock: latestBlock,
  });
  const vrtOutflows = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: VRT },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  let totalVytOut = 0n;
  console.log('  VYT outflows:');
  for (const log of vytOutflows) {
    const { to, value } = log.args;
    totalVytOut += value;
    console.log(`    Block ${log.blockNumber}: ${fmt(value)} VY → ${label(to)}`);
  }
  console.log(`  Total VYT outflow: ${fmt(totalVytOut)} VY\n`);

  let totalVrtOut = 0n;
  console.log('  VRT outflows:');
  for (const log of vrtOutflows) {
    const { to, value } = log.args;
    totalVrtOut += value;
    console.log(`    Block ${log.blockNumber}: ${fmt(value)} VY → ${label(to)}`);
  }
  console.log(`  Total VRT outflow: ${fmt(totalVrtOut)} VY\n`);

  // ─── 9. Check VY token transfer fee config ───
  console.log('=== 9. TRANSFER FEE CONFIG (AcquisitionOfficer) ===');
  try {
    const [feeBps, feeRecipient] = await Promise.all([
      client.readContract({
        address: ACQ_OFFICER,
        abi: [{ inputs: [], name: 'transferFeeBps', outputs: [{ type: 'uint16' }], stateMutability: 'view', type: 'function' }],
        functionName: 'transferFeeBps',
      }),
      client.readContract({
        address: ACQ_OFFICER,
        abi: [{ inputs: [], name: 'transferFeeRecipient', outputs: [{ type: 'address' }], stateMutability: 'view', type: 'function' }],
        functionName: 'transferFeeRecipient',
      }),
    ]);
    console.log(`  Transfer fee: ${feeBps} bps (${Number(feeBps) / 100}%)`);
    console.log(`  Fee recipient: ${feeRecipient} (${label(feeRecipient)})`);
  } catch (e) {
    console.log(`  Could not read transfer fee config: ${e.message}`);
  }

  // ─── SUMMARY ───
  console.log('\n========================================');
  console.log('           SUMMARY');
  console.log('========================================');
  console.log(`Total minted (all time):       ${fmt(totalMinted)} VY`);
  console.log(`Total burned (all time):       ${fmt(totalBurned)} VY`);
  console.log(`Net supply (minted - burned):  ${fmt(totalMinted - totalBurned)} VY`);
  console.log(`Acquisition minted:            ${fmt(totalAcqMinted)} VY`);
  console.log(`Acquisition fees:              ${fmt(totalAcqFees)} VY`);
  console.log(`Total cap reductions:          ${fmt(totalCapReductions)} VY`);
  console.log(`Total fees processed:          ${fmt(totalFeesProcessed)} VY`);
  console.log(`Total fees to treasury:        ${fmt(totalFeesToTreasury)} VY`);
  console.log(`VYT total outflow:             ${fmt(totalVytOut)} VY`);
  console.log(`VRT total outflow:             ${fmt(totalVrtOut)} VY`);
}

main().catch(e => { console.error(e); process.exit(1); });

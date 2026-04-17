/**
 * Trace VYT outflows to 0xA1B8d744 (MEV Bot) and AcqOfficer outflows
 * to find where the 7,142 VY gap comes from.
 * 
 * Key findings from scan:
 * - VYT sent VY to MEV Bot (0xA1B8d744) and AcqOfficer
 * - VRT sent VY to LoanOfficer (0x8Fd8d5eB) and VYT
 * - No VY burned, no acquisitions occurred, no fees processed
 * - Need to trace where MEV Bot and AcqOfficer VY ended up
 */

import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';

const VY_TOKEN     = '0x597b29520098d6aaca3B2e0D1a380315c9240454';
const MEV_BOT      = '0xA1B8d744B4c6498aBE473c320B46d581Cc9D33A4';
const ACQ_OFFICER  = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const LOAN_OFFICER = '0x8Fd8d5eB23f520D9BF8863364Ed44dbb29769DE4';
const CAP_OFFICER  = '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C';
const VYT          = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974';
const VRT          = '0x06087789B7122fA92E7F9868B10A286Dd4e4C832';
const PORTAL       = '0xF612C21161F400AbA27A0ef18b030350898b7628';
const DAX          = '0xD256C672616f7c5DEE3e42a8199f121EE08401B7';
const BUYBACK      = '0xD2F0826af20EbDc833c8418E312F23f373F8500e';
const STAKING_ROUTER = '0x664b3A81C963F07C1eb06516c560f9b2193698C7';
const VY_USDC_POOL = '0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705';
const DEPLOYER     = '0x8310eA7EC55A7Ad6A4288aF683155A124A524a09';

const KNOWN = {
  [VY_TOKEN.toLowerCase()]: 'VY Token',
  [MEV_BOT.toLowerCase()]: 'MEV Bot',
  [ACQ_OFFICER.toLowerCase()]: 'AcqOfficer',
  [LOAN_OFFICER.toLowerCase()]: 'LoanOfficer',
  [CAP_OFFICER.toLowerCase()]: 'CapOfficer',
  [VYT.toLowerCase()]: 'VYT',
  [VRT.toLowerCase()]: 'VRT',
  [PORTAL.toLowerCase()]: 'Portal',
  [DAX.toLowerCase()]: 'DAX',
  [BUYBACK.toLowerCase()]: 'Buyback',
  [STAKING_ROUTER.toLowerCase()]: 'StakingRouter',
  [VY_USDC_POOL.toLowerCase()]: 'VyUsdcPool',
  [DEPLOYER.toLowerCase()]: 'Deployer',
  '0x0000000000000000000000000000000000000000': 'ZERO',
};

const client = createPublicClient({
  chain: mainnet,
  transport: http('https://api.valinity.io/rpc-proxy'),
});

const fmt = (v) => formatUnits(v, 18);
const label = (addr) => KNOWN[addr.toLowerCase()] || addr;

async function traceAddress(name, address) {
  console.log(`\n=== ${name} (${address}) ===`);
  const latestBlock = await client.getBlockNumber();

  const [inflows, outflows] = await Promise.all([
    client.getLogs({
      address: VY_TOKEN,
      event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
      args: { to: address },
      fromBlock: 0n,
      toBlock: latestBlock,
    }),
    client.getLogs({
      address: VY_TOKEN,
      event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
      args: { from: address },
      fromBlock: 0n,
      toBlock: latestBlock,
    }),
  ]);

  let totalIn = 0n;
  let totalOut = 0n;

  console.log(`  INFLOWS (${inflows.length}):`);
  for (const log of inflows) {
    totalIn += log.args.value;
    console.log(`    Block ${log.blockNumber}: +${fmt(log.args.value)} from ${label(log.args.from)}`);
  }

  console.log(`  OUTFLOWS (${outflows.length}):`);
  for (const log of outflows) {
    totalOut += log.args.value;
    console.log(`    Block ${log.blockNumber}: -${fmt(log.args.value)} to ${label(log.args.to)}`);
  }

  console.log(`  Total In:  ${fmt(totalIn)} VY`);
  console.log(`  Total Out: ${fmt(totalOut)} VY`);
  console.log(`  Net:       ${fmt(totalIn - totalOut)} VY`);
}

async function main() {
  // Trace the 4 key addresses where VY flows from the treasuries
  await traceAddress('MEV Bot', MEV_BOT);
  await traceAddress('AcquisitionOfficer', ACQ_OFFICER);
  await traceAddress('LoanOfficer', LOAN_OFFICER);
  await traceAddress('Deployer', DEPLOYER);
  
  // Also trace the destination contracts that hold circulating VY
  await traceAddress('Portal', PORTAL);
  await traceAddress('DAX', DAX);
  await traceAddress('VyUsdcPool', VY_USDC_POOL);
  await traceAddress('Buyback', BUYBACK);
  await traceAddress('CapOfficer', CAP_OFFICER);
}

main().catch(e => { console.error(e); process.exit(1); });

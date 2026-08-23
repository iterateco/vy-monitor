/**
 * Final analysis: trace Deployer outflows and reconstruct the full accounting.
 */

import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';

const VY_TOKEN     = '0x597b29520098d6aaca3B2e0D1a380315c9240454';
const DEPLOYER     = '0x8310eA7EC55A7Ad6A4288aF683155A124A524a09';
const VYT          = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974';
const VCT          = '0x06087789B7122fA92E7F9868B10A286Dd4e4C832';
const CAP_OFFICER  = '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C';
const LOAN_OFFICER = '0x8Fd8d5eB23f520D9BF8863364Ed44dbb29769DE4';
const PORTAL       = '0xF612C21161F400AbA27A0ef18b030350898b7628';
const DAX          = '0xD256C672616f7c5DEE3e42a8199f121EE08401B7';
const BUYBACK      = '0xD2F0826af20EbDc833c8418E312F23f373F8500e';
const VY_USDC_POOL = '0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705';
const MEV_BOT      = '0xA1B8d744B4c6498aBE473c320B46d581Cc9D33A4';
const ACQ_OFFICER  = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const STAKING_ROUTER = '0x664b3A81C963F07C1eb06516c560f9b2193698C7';

const KNOWN = {
  [VYT.toLowerCase()]: 'VYT',
  [VCT.toLowerCase()]: 'VCT',
  [CAP_OFFICER.toLowerCase()]: 'CapOfficer',
  [LOAN_OFFICER.toLowerCase()]: 'LoanOfficer',
  [PORTAL.toLowerCase()]: 'Portal',
  [DAX.toLowerCase()]: 'DAX',
  [BUYBACK.toLowerCase()]: 'Buyback',
  [VY_USDC_POOL.toLowerCase()]: 'VyUsdcPool',
  [DEPLOYER.toLowerCase()]: 'Deployer',
  [MEV_BOT.toLowerCase()]: 'MEVBot',
  [ACQ_OFFICER.toLowerCase()]: 'AcqOfficer',
  [STAKING_ROUTER.toLowerCase()]: 'StakingRouter',
  '0x0000000000000000000000000000000000000000': 'MINT',
};

const client = createPublicClient({
  chain: mainnet,
  transport: http('https://api.valinity.io/rpc-proxy'),
});

const fmt = (v) => formatUnits(v, 18);
const label = (addr) => KNOWN[addr.toLowerCase()] || addr;

async function main() {
  const latestBlock = await client.getBlockNumber();

  // ─── Deployer outflows ───
  console.log('=== DEPLOYER OUTFLOWS ===');
  const deployerOut = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: DEPLOYER },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  const deployerDest = {};
  for (const log of deployerOut) {
    const dest = label(log.args.to);
    deployerDest[dest] = (deployerDest[dest] || 0n) + log.args.value;
  }
  for (const [dest, amount] of Object.entries(deployerDest)) {
    console.log(`  → ${dest}: ${fmt(amount)} VY`);
  }

  // ─── Deployer inflows ───
  console.log('\n=== DEPLOYER INFLOWS ===');
  const deployerIn = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: DEPLOYER },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  const deployerSrc = {};
  for (const log of deployerIn) {
    const src = label(log.args.from);
    deployerSrc[src] = (deployerSrc[src] || 0n) + log.args.value;
  }
  for (const [src, amount] of Object.entries(deployerSrc)) {
    console.log(`  ← ${src}: ${fmt(amount)} VY`);
  }

  // ─── MEV Bot outflows ───
  console.log('\n=== MEV BOT OUTFLOWS ===');
  const mevOut = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: MEV_BOT },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  const mevDest = {};
  for (const log of mevOut) {
    const dest = label(log.args.to);
    mevDest[dest] = (mevDest[dest] || 0n) + log.args.value;
  }
  for (const [dest, amount] of Object.entries(mevDest)) {
    console.log(`  → ${dest}: ${fmt(amount)} VY`);
  }

  // ─── MEV Bot inflows ───
  console.log('\n=== MEV BOT INFLOWS ===');
  const mevIn = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: MEV_BOT },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  const mevSrc = {};
  for (const log of mevIn) {
    const src = label(log.args.from);
    mevSrc[src] = (mevSrc[src] || 0n) + log.args.value;
  }
  for (const [src, amount] of Object.entries(mevSrc)) {
    console.log(`  ← ${src}: ${fmt(amount)} VY`);
  }

  // ─── LoanOfficer outflows ───
  console.log('\n=== LOAN OFFICER OUTFLOWS ===');
  const loOut = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: LOAN_OFFICER },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  const loDest = {};
  for (const log of loOut) {
    const dest = label(log.args.to);
    loDest[dest] = (loDest[dest] || 0n) + log.args.value;
  }
  for (const [dest, amount] of Object.entries(loDest)) {
    console.log(`  → ${dest}: ${fmt(amount)} VY`);
  }

  // ─── LoanOfficer inflows ───
  console.log('\n=== LOAN OFFICER INFLOWS ===');
  const loIn = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { to: LOAN_OFFICER },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  const loSrc = {};
  for (const log of loIn) {
    const src = label(log.args.from);
    loSrc[src] = (loSrc[src] || 0n) + log.args.value;
  }
  for (const [src, amount] of Object.entries(loSrc)) {
    console.log(`  ← ${src}: ${fmt(amount)} VY`);
  }

  // ─── AcqOfficer outflows ───
  console.log('\n=== ACQUISITION OFFICER OUTFLOWS ===');
  const aoOut = await client.getLogs({
    address: VY_TOKEN,
    event: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
    args: { from: ACQ_OFFICER },
    fromBlock: 0n,
    toBlock: latestBlock,
  });

  const aoDest = {};
  for (const log of aoOut) {
    const dest = label(log.args.to);
    aoDest[dest] = (aoDest[dest] || 0n) + log.args.value;
  }
  for (const [dest, amount] of Object.entries(aoDest)) {
    console.log(`  → ${dest}: ${fmt(amount)} VY`);
  }

  // ─── FULL ACCOUNTING RECONSTRUCTION ───
  console.log('\n========================================');
  console.log('     FULL VY FLOW RECONSTRUCTION');
  console.log('========================================');
  
  // Initial setup
  const initialCaps = 429000n * BigInt(1e18);
  const portalInflow = deployerDest['Portal'] || 0n;
  console.log(`\n1. INITIAL SETUP:`);
  console.log(`   Deployer → Portal: ${fmt(portalInflow)} VY`);
  console.log(`   Initial caps set:  429,000 VY (143k × 3 assets)`);
  console.log(`   Match: ${portalInflow === initialCaps ? '✅' : '❌'}`);

  // VYT flows that entered circulation  
  const vytToMev = deployerDest['MEVBot'] !== undefined ? 0n : 0n; // Need from VYT
  console.log(`\n2. VYT OUTFLOWS INTO CIRCULATION:`);
  console.log(`   VYT → MEVBot: enters circulation (no cap creation)`);
  console.log(`   VYT → AcqOfficer: enters circulation (caps created via acquisition)`);

  console.log(`\n3. NET EFFECT ON CIRCULATING:`);
  console.log(`   Minted to VYT (increases supply): 159,000 VY`);
  console.log(`   VYT outflow (enters circulation): 5,554.01 VY`);
  console.log(`   Of which to AcqOfficer (creates caps): ~1,217.76 VY`);
  console.log(`   Of which to MEVBot (NO cap created): ~4,336.24 VY`);
}

main().catch(e => { console.error(e); process.exit(1); });

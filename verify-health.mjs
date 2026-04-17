/**
 * On-chain health check: verify that circulating VY supply == sum of collateral caps.
 *
 * Circulating = TotalSupply - VYT_balance - VRT_balance
 * Expected:    sum(collateralCap) for WETH + WBTC + PAXG  (from CapOfficer)
 *
 * The caps may be SLIGHTLY HIGHER than circulating because tx fees
 * lower the cap of the lowest-LTVF asset every 7 transactions,
 * so at any snapshot the caps can lag behind.
 */

import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';

// ─── Addresses ───────────────────────────────────────────────
const VY_TOKEN        = '0x597b29520098d6aaca3B2e0D1a380315c9240454';
const VYT             = '0xe58E29c947013B4CBCdb67f90d659c3894BE2974'; // ValinityYieldTreasury
const VRT             = '0x06087789B7122fA92E7F9868B10A286Dd4e4C832'; // ValinityReserveTreasury
const CAP_OFFICER     = '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C'; // ValinityCapOfficer

const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const WBTC = '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599';
const PAXG = '0x45804880de22913dafe09f4980848ece6ecbaf78';

// ─── ABIs (minimal) ──────────────────────────────────────────
const erc20Abi = [
  { inputs: [], name: 'totalSupply', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
  { inputs: [{ name: 'account', type: 'address' }], name: 'balanceOf', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' },
];

const capOfficerAbi = [
  {
    inputs: [{ name: 'asset', type: 'address' }],
    name: 'getAssetMetrics',
    outputs: [{
      components: [
        { name: 'totalReserve', type: 'uint256' },
        { name: 'collateralCap', type: 'uint256' },
        { name: 'ltvRatio', type: 'uint256' },
        { name: 'ltvF', type: 'uint256' },
        { name: 'utilized', type: 'uint256' },
        { name: 'available', type: 'uint256' },
      ],
      type: 'tuple'
    }],
    stateMutability: 'view',
    type: 'function',
  },
];

// ─── Client ──────────────────────────────────────────────────
const client = createPublicClient({
  chain: mainnet,
  transport: http('https://api.valinity.io/rpc-proxy'),
});

// ─── Query ───────────────────────────────────────────────────
async function main() {
  console.log('Querying mainnet on-chain data...\n');

  // Additional contract addresses to check VY balances
  const PORTAL          = '0xF612C21161F400AbA27A0ef18b030350898b7628';
  const DAX             = '0xD256C672616f7c5DEE3e42a8199f121EE08401B7';
  const BUYBACK         = '0xD2F0826af20EbDc833c8418E312F23f373F8500e';
  const STAKING_ROUTER  = '0x664b3A81C963F07C1eb06516c560f9b2193698C7';
  const VY_USDC_POOL    = '0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705';
  const DEPLOYER        = '0x8310eA7EC55A7Ad6A4288aF683155A124A524a09';
  const MEV_BOT         = '0xA1B8d744B4c6498aBE473c320B46d581Cc9D33A4';

  const [
    totalSupply, vytBalance, vrtBalance,
    wethMetrics, wbtcMetrics, paxgMetrics,
    vcoBalance, portalBalance, daxBalance, buybackBalance,
    stakingBalance, poolBalance, deployerBalance, mevBotBalance
  ] = await Promise.all([
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'totalSupply' }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [VYT] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [VRT] }),
    client.readContract({ address: CAP_OFFICER, abi: capOfficerAbi, functionName: 'getAssetMetrics', args: [WETH] }),
    client.readContract({ address: CAP_OFFICER, abi: capOfficerAbi, functionName: 'getAssetMetrics', args: [WBTC] }),
    client.readContract({ address: CAP_OFFICER, abi: capOfficerAbi, functionName: 'getAssetMetrics', args: [PAXG] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [CAP_OFFICER] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [PORTAL] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [DAX] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [BUYBACK] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [STAKING_ROUTER] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [VY_USDC_POOL] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [DEPLOYER] }),
    client.readContract({ address: VY_TOKEN, abi: erc20Abi, functionName: 'balanceOf', args: [MEV_BOT] }),
  ]);

  const fmt = (v) => formatUnits(v, 18);

  // ── Circulating ────────────────────────────────────────────
  const circulating = totalSupply - vytBalance - vrtBalance;

  // ── Sum of caps ────────────────────────────────────────────
  const wethCap = wethMetrics.collateralCap;
  const wbtcCap = wbtcMetrics.collateralCap;
  const paxgCap = paxgMetrics.collateralCap;
  const totalCaps = wethCap + wbtcCap + paxgCap;

  // ── Diff ───────────────────────────────────────────────────
  const diff = totalCaps - circulating;  // positive = caps slightly higher (expected)

  console.log('=== VY Supply Breakdown ===');
  console.log(`  Total Supply:       ${fmt(totalSupply)} VY`);
  console.log(`  VYT Balance:        ${fmt(vytBalance)} VY  (locked)`);
  console.log(`  VRT Balance:        ${fmt(vrtBalance)} VY  (locked)`);
  console.log(`  Circulating:        ${fmt(circulating)} VY`);
  console.log('');
  console.log('=== Collateral Caps (CapOfficer) ===');
  console.log(`  WETH cap:           ${fmt(wethCap)} VY`);
  console.log(`  WBTC cap:           ${fmt(wbtcCap)} VY`);
  console.log(`  PAXG cap:           ${fmt(paxgCap)} VY`);
  console.log(`  Total Caps:         ${fmt(totalCaps)} VY`);
  console.log('');
  console.log('=== Health Check ===');
  console.log(`  Circulating:        ${fmt(circulating)} VY`);
  console.log(`  Total Caps:         ${fmt(totalCaps)} VY`);
  console.log(`  Diff (caps - circ): ${fmt(diff)} VY`);
  console.log('');

  if (diff >= 0n) {
    console.log(`  ✅ HEALTHY — Caps cover all circulating supply.`);
    if (diff > 0n) {
      console.log(`     Caps are ${fmt(diff)} VY higher than circulating (expected: tx fee cap reduction lag).`);
    } else {
      console.log(`     Exact match.`);
    }
  } else {
    console.log(`  ❌ UNHEALTHY — Circulating supply exceeds total caps by ${fmt(-diff)} VY!`);
    console.log(`     This means there is VY in circulation not backed by any collateral cap.`);
  }

  console.log('');
  console.log('=== VY Balances in All Contracts ===');
  console.log(`  VYT (locked):         ${fmt(vytBalance)} VY`);
  console.log(`  VRT (locked):         ${fmt(vrtBalance)} VY`);
  console.log(`  CapOfficer (VCO):     ${fmt(vcoBalance)} VY`);
  console.log(`  Portal:               ${fmt(portalBalance)} VY`);
  console.log(`  DAX:                  ${fmt(daxBalance)} VY`);
  console.log(`  Buyback Officer:      ${fmt(buybackBalance)} VY`);
  console.log(`  Staking Router:       ${fmt(stakingBalance)} VY`);
  console.log(`  VY/USDC Pool:         ${fmt(poolBalance)} VY`);
  console.log(`  Deployer:             ${fmt(deployerBalance)} VY`);
  console.log(`  MEV Bot:              ${fmt(mevBotBalance)} VY`);
  const allKnown = vytBalance + vrtBalance + vcoBalance + portalBalance + daxBalance +
                   buybackBalance + stakingBalance + poolBalance + deployerBalance + mevBotBalance;
  const unaccounted = totalSupply - allKnown;
  console.log(`  ---`);
  console.log(`  Sum of above:         ${fmt(allKnown)} VY`);
  console.log(`  Unaccounted (wallets): ${fmt(unaccounted)} VY`);

  console.log('');
  console.log('=== Per-Asset Detail ===');
  for (const [label, m] of [['WETH', wethMetrics], ['WBTC', wbtcMetrics], ['PAXG', paxgMetrics]]) {
    console.log(`  ${label}:`);
    console.log(`    collateralCap:  ${fmt(m.collateralCap)} VY`);
    console.log(`    utilized:       ${fmt(m.utilized)} VY`);
    console.log(`    available:      ${fmt(m.available)} VY`);
    console.log(`    totalReserve:   ${fmt(m.totalReserve)}`);
    console.log(`    ltvRatio:       ${fmt(m.ltvRatio)}`);
    console.log(`    ltvF:           ${fmt(m.ltvF)}`);
  }
}

main().catch(e => { console.error(e); process.exit(1); });

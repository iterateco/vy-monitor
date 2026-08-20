import { createPublicClient, http, toFunctionSelector, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';

const c = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const ORACLE = '0x6df9a2FA586ff348fc35918dB13c93e52403f070';
const VBSO = '0xDFd145401122d62987c6a363e370F4DB759BE1b4';
const SHEET = toFunctionSelector('function sheet()');
const stub = (px) => '0x7f' + px.toString(16).padStart(64, '0') + '60005260206000f3';
const WAD = 10n ** 18n;

function parse(hex) {
  const w = hex.slice(2).match(/.{64}/g);
  const u = (i) => BigInt('0x' + w[i]);
  return {
    hardAssetsUsd: u(0), coveredLoansUsd: u(1), loansFaceUsd: u(2), stakerDebtUsd: u(3),
    equityUsd: BigInt.asIntN(256, u(4)), mcapUsd: u(10), usdPerVy: u(11),
  };
}
const at = async (R) => parse((await c.call({ to: VBSO, data: SHEET, stateOverride: [{ address: ORACLE, code: stub(R) }] })).data);

// live, no override
const live = parse((await c.call({ to: VBSO, data: SHEET })).data);

// calibrate: usdPerVy is exactly inversely proportional to the oracle return
const R0 = 3n * 10n ** 17n;
const s0 = await at(R0);
const K = s0.usdPerVy * R0;
const Rreal = K / live.usdPerVy;

console.log('CALIBRATION');
console.log('  K                 =', K.toString());
console.log('  implied R_real    =', Rreal.toString());

const check = await at(Rreal);
const near = (a, b) => (a === b ? 'EXACT' : `off by ${formatUnits(a > b ? a - b : b - a, 18)}`);
console.log('\nVALIDATION — override at implied R_real must reproduce the live sheet:');
console.log('  usdPerVy   live', formatUnits(live.usdPerVy, 18), '| sim', formatUnits(check.usdPerVy, 18), '|', near(live.usdPerVy, check.usdPerVy));
console.log('  equity     live', formatUnits(live.equityUsd, 18), '| sim', formatUnits(check.equityUsd, 18), '|', near(live.equityUsd, check.equityUsd));
console.log('  covered    live', formatUnits(live.coveredLoansUsd, 18), '| sim', formatUnits(check.coveredLoansUsd, 18), '|', near(live.coveredLoansUsd, check.coveredLoansUsd));

// circulating VY for the floors
const circ = await c.readContract({
  address: '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C',
  abi: [{ type: 'function', name: 'getTotalCirculatingVY', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] }],
  functionName: 'getTotalCirculatingVY',
});

/** R is exactly inversely proportional to the reported price, so target a price directly. */
const Rfor = (mult) => K / ((live.usdPerVy * BigInt(Math.round(mult * 1e9))) / 1000000000n);

console.log('\nSENSITIVITY — VY price move vs balance-sheet equity (contract-computed)');
console.log('  move     VY price   hard assets   covered loans      equity      floor_full   floor_hard   cover%');
const moves = [-20, -10, -6, -5, -4, -3.7, -3, -2, -1, 0, 1, 2, 5, 10, 20];
const rows = [];
for (const m of moves) {
  const s = await at(Rfor(1 + m / 100));
  const hardEq = s.hardAssetsUsd - s.stakerDebtUsd;
  const ff = (s.equityUsd * WAD) / circ, fh = (hardEq * WAD) / circ;
  const coverPct = Number((s.coveredLoansUsd * 10000n) / s.loansFaceUsd) / 100;
  rows.push({ m, px: Number(formatUnits(s.usdPerVy, 18)), hard: Number(formatUnits(s.hardAssetsUsd, 18)), covered: Number(formatUnits(s.coveredLoansUsd, 18)), equity: Number(formatUnits(s.equityUsd, 18)), ff: Number(formatUnits(ff, 18)), fh: Number(formatUnits(fh, 18)), coverPct });
  const r = rows.at(-1);
  console.log(`  ${String(m).padStart(5)}%  $${r.px.toFixed(4).padStart(8)}  $${r.hard.toLocaleString('en-US',{maximumFractionDigits:0}).padStart(9)}  $${r.covered.toLocaleString('en-US',{maximumFractionDigits:0}).padStart(11)}  $${r.equity.toLocaleString('en-US',{maximumFractionDigits:0}).padStart(9)}  $${r.ff.toFixed(4).padStart(9)}  $${r.fh.toFixed(4).padStart(8)}  ${r.coverPct.toFixed(2)}%`);
}

// locate the cliff precisely: largest downward move that keeps coverage alive
console.log('\nCLIFF SEARCH (bisect on the downward move where covered loans -> 0):');
let lo = -90, hi = 0; // lo = dead, hi = alive
for (let i = 0; i < 40; i++) {
  const mid = (lo + hi) / 2;
  const s = await at(Rfor(1 + mid / 100));
  if (s.coveredLoansUsd === 0n) lo = mid; else hi = mid;
}
console.log(`  coverage survives down to ${hi.toFixed(4)}%, collapses to ZERO by ${lo.toFixed(4)}%`);
for (const m of [hi, lo]) {
  const s = await at(Rfor(1 + m / 100));
  const hardEq = s.hardAssetsUsd - s.stakerDebtUsd;
  console.log(`  at ${m.toFixed(4).padStart(9)}%: price $${formatUnits(s.usdPerVy,18).slice(0,8)}  covered $${Number(formatUnits(s.coveredLoansUsd,18)).toLocaleString('en-US',{maximumFractionDigits:0}).padStart(9)}  equity $${Number(formatUnits(s.equityUsd,18)).toLocaleString('en-US',{maximumFractionDigits:0}).padStart(8)}  floor_full $${formatUnits(s.equityUsd*WAD/circ,18).slice(0,6)}  floor_hard $${formatUnits(hardEq*WAD/circ,18).slice(0,6)}`);
}

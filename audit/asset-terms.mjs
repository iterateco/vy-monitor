// Asset-denominated staking P&L (numbers from staking-pnl.mjs, all on-chain)
const consumed = { WETH: 8.774457, WBTC: 0.187441, PAXG: 0.486976, USDC: 0 };       // net pulled from VRT (in - out)
const held     = { WETH: 5.937884, WBTC: 0.101615, PAXG: 0.362213, USDC: 694.789793 }; // LP + residual now
const px       = { WETH: 1561.24, WBTC: 60648.48, PAXG: 4301.78, USDC: 1 };           // current VAO prices

console.log('=== ASSET-TERMS P&L (units only, ignore USD) ===');
for (const a of ['WETH','WBTC','PAXG','USDC']) {
  const d = held[a] - consumed[a];
  const pct = consumed[a] ? (d/consumed[a]*100).toFixed(1)+'%' : 'n/a';
  console.log(`${a.padEnd(5)} consumed ${consumed[a].toFixed(6).padStart(12)}  held ${held[a].toFixed(6).padStart(12)}  delta ${(d>=0?'+':'')+d.toFixed(6)}  (${pct})`);
}

console.log('\n=== WETH/WBTC pool, in asset units (no stable leg to hide behind) ===');
console.log('Deployed (net):  8.774 WETH + 0.187 WBTC');
console.log('Holds now:       5.938 WETH + 0.102 WBTC');
console.log('=> FEWER OF BOTH: -2.836 WETH (-32%) AND -0.086 WBTC (-46%)');

console.log('\n=== PAXG/USDC pool (has stable anchor) ===');
const paxgGiven = consumed.PAXG - held.PAXG;            // 0.1248 PAXG given up
const usdcGot   = held.USDC;                            // 694.79 USDC gained
const usdcInPaxg= usdcGot / px.PAXG;                    // value that USDC in PAXG
console.log(`Gave up ${paxgGiven.toFixed(4)} PAXG, received ${usdcGot.toFixed(2)} USDC (= ${usdcInPaxg.toFixed(4)} PAXG-equiv)`);
console.log(`Net in PAXG terms: ${((held.PAXG + usdcInPaxg) - consumed.PAXG >=0?'+':'')}${((held.PAXG + usdcInPaxg) - consumed.PAXG).toFixed(4)} PAXG  => roughly flat/slightly accretive`);

console.log('\n=== Numeraire-invariance proof (vs HODL) ===');
const consUSD = Object.keys(consumed).reduce((s,a)=>s+consumed[a]*px[a],0);
const heldUSD = Object.keys(held).reduce((s,a)=>s+held[a]*px[a],0);
const pnlUSD = heldUSD - consUSD;
console.log(`In USD : held $${heldUSD.toFixed(0)} - consumed $${consUSD.toFixed(0)} = ${pnlUSD.toFixed(0)}  (${(pnlUSD/consUSD*100).toFixed(1)}%)`);
console.log(`In WETH: ${(pnlUSD/px.WETH).toFixed(2)} WETH-equiv lost      (${(pnlUSD/consUSD*100).toFixed(1)}%)  <- same %`);
console.log(`In WBTC: ${(pnlUSD/px.WBTC).toFixed(4)} WBTC-equiv lost    (${(pnlUSD/consUSD*100).toFixed(1)}%)  <- same %`);
console.log(`In PAXG: ${(pnlUSD/px.PAXG).toFixed(3)} PAXG-equiv lost     (${(pnlUSD/consUSD*100).toFixed(1)}%)  <- same %`);
console.log('\nThe % loss vs holding is identical in every unit because the price level cancels.');
console.log('This is impermanent loss = a real loss of ASSETS vs holding, not a USD effect.');

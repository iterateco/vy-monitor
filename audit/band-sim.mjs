// Simulate WETH/WBTC LP over the ACTUAL reconstructed center-price path.
// price p = WETH per WBTC (token0=WBTC, token1=WETH). Normalize start value=1 (token1 units).
// Compares: (A) tight +/-2% with re-center at each step, (B) wide static no-rebalance, (C) HODL.
const path = [33.593,33.728,34.237,34.272,34.512,34.512,34.547,34.859,34.824,34.444,34.651,
 35.245,36.246,36.173,36.300,36.318,36.904,36.318,36.209,36.173,35.563,34.964,35.706,35.706,
 35.670,37.537,38.142,38.680]; // from price-path.mjs (WETH per WBTC at each re-center)

const sq=Math.sqrt;
// concentrated position value (in token1) at price p, liquidity L, range [pa,pb]
function posVal(p,L,pa,pb){
 if(p<=pa) return p*L*(1/sq(pa)-1/sq(pb));        // all token0(WBTC)
 if(p>=pb) return L*(sq(pb)-sq(pa));              // all token1(WETH)
 return L*(sq(p)-sq(pa)) + p*L*(1/sq(p)-1/sq(pb));
}
function Lfor(V,p,pa,pb){ return V/(2*sq(p)-sq(pa)-p/sq(pb)); } // L for 50/50 value V at p

function recenter(delta){ // +/- delta band, re-center each step
 let V=1, p0=path[0];
 for(let i=0;i<path.length-1;i++){
  const p=path[i], pa=p/(1+delta), pb=p*(1+delta);
  const L=Lfor(V,p,pa,pb);
  V=posVal(path[i+1],L,pa,pb);   // price moves to next center, NO rebalance during move
 }
 return V;
}
function staticWide(delta){ // one position at start, never rebalance
 const p0=path[0], pa=p0/(1+delta), pb=p0*(1+delta);
 const L=Lfor(1,p0,pa,pb);
 return posVal(path[path.length-1],L,pa,pb);
}
const pF=path[path.length-1], p0=path[0];
const hodl=0.5*(1+pF/p0); // 50/50 held

const fmt=x=>((x/hodl-1)*100).toFixed(2)+'% vs HODL';
console.log(`Path: ${p0.toFixed(2)} -> ${pF.toFixed(2)} WETH/WBTC (ratio move +${((pF/p0-1)*100).toFixed(1)}%), ${path.length-1} re-center steps`);
console.log(`HODL end value (norm): ${hodl.toFixed(4)}\n`);
console.log('STRATEGY                         end value   loss vs HODL');
console.log(`A) +/-2% re-center (ACTUAL-like): ${recenter(0.02).toFixed(4)}     ${fmt(recenter(0.02))}`);
console.log(`   +/-5% re-center:              ${recenter(0.05).toFixed(4)}     ${fmt(recenter(0.05))}`);
console.log(`   +/-10% re-center:             ${recenter(0.10).toFixed(4)}     ${fmt(recenter(0.10))}`);
console.log(`   +/-20% re-center:             ${recenter(0.20).toFixed(4)}     ${fmt(recenter(0.20))}`);
console.log(`B) static +/-50% no-rebalance:   ${staticWide(0.50).toFixed(4)}     ${fmt(staticWide(0.50))}`);
console.log(`   static full-range (+/-1000%):  ${staticWide(10).toFixed(4)}     ${fmt(staticWide(10))}`);
console.log('\nNote: sim uses recorded re-center prices as the path => LOWER BOUND on churn');
console.log('(real intra-step wandering to band edges adds more tight-band loss).');

import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });

const VCO='0x2f02415989C3e02061a8e451EF64Dc59e5c0051C';
const VAO='0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const VRYO='0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const VYTOKEN='0x597b29520098d6aaca3B2e0D1a380315c9240454';
const VYT='0xe58E29c947013B4CBCdb67f90d659c3894BE2974'; // YieldTreasury
const VRT='0x06087789B7122fA92E7F9868B10A286Dd4e4C832'; // ReserveTreasury
const assets = {
  WETH:'0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  WBTC:'0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',
  PAXG:'0x45804880de22913dafe09f4980848ece6ecbaf78',
};
const decimalsOf = { WETH:18, WBTC:8, PAXG:18 };

const vcoAbi=[
 {inputs:[{type:'address'}],name:'getAssetCap',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'address'}],name:'getAssetMetrics',outputs:[{components:[
   {name:'totalReserve',type:'uint256'},{name:'collateralCap',type:'uint256'},{name:'ltvRatio',type:'uint256'},
   {name:'ltvF',type:'uint256'},{name:'utilized',type:'uint256'},{name:'available',type:'uint256'}],type:'tuple'}],stateMutability:'view',type:'function'},
];
const vaoAbi=[{inputs:[{type:'address'}],name:'getAssetTwapPrice',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];
const vryoAbi=[{inputs:[],name:'capVRYO_total',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];
const erc20=[
 {inputs:[{type:'address'}],name:'balanceOf',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'totalSupply',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
];

const WAD=10n**18n;
const fmt=(x,d=18)=>Number(formatUnits(x,d));

let totalReserveUSD=0n, totalCap=0n;
console.log('=== VCO collateral leg (per asset) ===');
for (const [sym,addr] of Object.entries(assets)) {
  const dec=decimalsOf[sym];
  const cap = await client.readContract({address:VCO,abi:vcoAbi,functionName:'getAssetCap',args:[addr]});
  let price=0n, ltvF=0n, reserve=0n;
  try { price = await client.readContract({address:VAO,abi:vaoAbi,functionName:'getAssetTwapPrice',args:[addr]}); } catch(e){ price=-1n; }
  try { const m = await client.readContract({address:VCO,abi:vcoAbi,functionName:'getAssetMetrics',args:[addr]}); ltvF=m.ltvF; reserve=m.totalReserve; }
  catch(e){ // metrics reverted (stale oracle) -> fall back to raw balance
    reserve = await client.readContract({address:addr,abi:erc20,functionName:'balanceOf',args:[VRT]}); ltvF=-1n; }
  const reserveNorm = dec===18 ? reserve : (dec<18 ? reserve*(10n**BigInt(18-dec)) : reserve/(10n**BigInt(dec-18)));
  const usd = price>0n ? (reserveNorm*price)/WAD : 0n;
  totalReserveUSD += usd; totalCap += cap;
  console.log(`${sym}: cap=${fmt(cap).toFixed(2)} VY  reserve=${fmt(reserve,dec).toFixed(6)} ${sym}  price=$${price>0n?fmt(price).toFixed(2):(price===-1n?'TWAP REVERT':'0')}  reserveUSD=$${fmt(usd).toFixed(2)}  LTVF=${ltvF>=0n?fmt(ltvF).toFixed(5):'METRICS REVERT'}`);
}
const vcoLeg = totalCap>0n ? Number(totalReserveUSD*WAD/totalCap)/1e18 : 0;
console.log(`\nVCO totals: reserveUSD=$${fmt(totalReserveUSD).toFixed(2)}  cap=${fmt(totalCap).toFixed(2)} VY`);
console.log(`VCO-only floor (reserveUSD/cap) = $${vcoLeg.toFixed(5)} per VY`);

console.log('\n=== VRYO leg ===');
const deployed = await client.readContract({address:VRYO,abi:vryoAbi,functionName:'capVRYO_total'});
console.log(`capVRYO_total (deployed VY) = ${fmt(deployed).toFixed(2)} VY`);

const totalSupply = await client.readContract({address:VYTOKEN,abi:erc20,functionName:'totalSupply'});
const inVyt = await client.readContract({address:VYTOKEN,abi:erc20,functionName:'balanceOf',args:[VYT]});
const inVrt = await client.readContract({address:VYTOKEN,abi:erc20,functionName:'balanceOf',args:[VRT]});
const circulating = totalSupply - inVyt - inVrt;
console.log(`circulating VY = ${fmt(circulating).toFixed(2)}  (totalSupply ${fmt(totalSupply).toFixed(2)} - VYT ${fmt(inVyt).toFixed(2)} - VRT ${fmt(inVrt).toFixed(2)})`);

console.log('\n=== Imply VRYO leg from displayed Round Floor 0.057 ===');
const RF = 0.057;
const denom = totalCap + deployed;
const numeratorUSD = RF * fmt(denom);
const lpUSD_implied = numeratorUSD - fmt(totalReserveUSD);
const vryoLeg = fmt(deployed)>0 ? lpUSD_implied/fmt(deployed) : 0;
console.log(`denom (VCO cap + deployed) = ${fmt(denom).toFixed(2)} VY`);
console.log(`implied total backing USD @0.057 = $${numeratorUSD.toFixed(2)}`);
console.log(`implied LP holdings USD = $${lpUSD_implied.toFixed(2)}`);
console.log(`implied VRYO-leg floor = $${vryoLeg.toFixed(5)} per deployed VY`);

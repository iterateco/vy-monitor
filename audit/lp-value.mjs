import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });

const VRYO='0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const VLM='0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0';
const VAO='0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const NPM='0xC36442b4a4522E871399CD717aBDD847Ab11FE88';
const USDC='0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const decByAddr={
 '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2':18,//WETH
 '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599':8, //WBTC
 '0x45804880de22913dafe09f4980848ece6ecbaf78':18,//PAXG
 '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48':6, //USDC
};
const vryoAbi=[
 {inputs:[],name:'PAIR_PAXG_USDC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'PAIR_WETH_WBTC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'capVRYO_total',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'bytes32'}],name:'pairPrincipal',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
];
const vlmAbi=[
 {inputs:[{type:'bytes32'}],name:'pairConfig',outputs:[{components:[
  {name:'pool',type:'address'},{name:'fee',type:'uint24'},{name:'tickSpacing',type:'int24'},{name:'lowerRangeBps',type:'uint32'},{name:'upperRangeBps',type:'uint32'},
  {name:'token0',type:'address'},{name:'a',type:'uint32'},{name:'b',type:'uint32'},{name:'c',type:'uint32'},{name:'d',type:'uint32'},
  {name:'token1',type:'address'},{name:'e',type:'uint256'},{name:'f',type:'uint256'},{name:'g',type:'address'},{name:'h',type:'bool'},{name:'i',type:'uint16'}],type:'tuple'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'bytes32'}],name:'activeTokenId',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
];
const poolAbi=[{inputs:[],name:'slot0',outputs:[{name:'sqrtPriceX96',type:'uint160'},{name:'tick',type:'int24'},{type:'uint16'},{type:'uint16'},{type:'uint16'},{type:'uint8'},{type:'bool'}],stateMutability:'view',type:'function'}];
const npmAbi=[{inputs:[{type:'uint256'}],name:'positions',outputs:[
 {type:'uint96'},{type:'address'},{name:'token0',type:'address'},{name:'token1',type:'address'},{name:'fee',type:'uint24'},
 {name:'tickLower',type:'int24'},{name:'tickUpper',type:'int24'},{name:'liquidity',type:'uint128'},{type:'uint256'},{type:'uint256'},
 {name:'tokensOwed0',type:'uint128'},{name:'tokensOwed1',type:'uint128'}],stateMutability:'view',type:'function'}];
const vaoAbi=[{inputs:[{type:'address'}],name:'getAssetTwapPrice',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];

const WAD=10n**18n, Q96=2n**96n;
const tickToSqrtX96=(t)=>BigInt(Math.floor(Math.sqrt(Math.pow(1.0001,t))*Number(Q96)));
function amountsFor(sqrtP,sqrtA,sqrtB,L){
 if(sqrtA>sqrtB){const t=sqrtA;sqrtA=sqrtB;sqrtB=t;}
 if(sqrtP<=sqrtA) return {a0:(L*(sqrtB-sqrtA)*Q96)/(sqrtB*sqrtA),a1:0n};
 if(sqrtP>=sqrtB) return {a0:0n,a1:(L*(sqrtB-sqrtA))/Q96};
 return {a0:(L*(sqrtB-sqrtP)*Q96)/(sqrtB*sqrtP),a1:(L*(sqrtP-sqrtA))/Q96};
}
const priceCache={};
async function priceUSD(addr){
 addr=addr.toLowerCase();
 if(addr===USDC.toLowerCase()) return WAD;
 if(priceCache[addr]!==undefined) return priceCache[addr];
 let p=0n; try{p=await client.readContract({address:VAO,abi:vaoAbi,functionName:'getAssetTwapPrice',args:[addr]});}catch(e){p=0n;}
 priceCache[addr]=p; return p;
}
function toUsd(raw,dec,price){const scale=10n**BigInt(18-dec);return (raw*scale*price)/WAD;}
const fmt=(x,d=18)=>Number(formatUnits(x,d));

const pk_pu=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_PAXG_USDC'});
const pk_ww=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_WETH_WBTC'});
const pairs=[{name:'PAXG/USDC',key:pk_pu},{name:'WETH/WBTC',key:pk_ww}];

let lpHoldingsUSD=0n;
console.log('=== LP positions (live mark-to-market) ===');
for(const pr of pairs){
 const cfg=await client.readContract({address:VLM,abi:vlmAbi,functionName:'pairConfig',args:[pr.key]});
 const tokenId=await client.readContract({address:VLM,abi:vlmAbi,functionName:'activeTokenId',args:[pr.key]});
 const principalVY=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'pairPrincipal',args:[pr.key]});
 if(tokenId===0n){console.log(`${pr.name}: no active position (principalVY=${fmt(principalVY).toFixed(2)})`);continue;}
 const slot0=await client.readContract({address:cfg.pool,abi:poolAbi,functionName:'slot0'});
 const pos=await client.readContract({address:NPM,abi:npmAbi,functionName:'positions',args:[tokenId]});
 const sqrtP=slot0[0];
 const tickLower=Number(pos[5]),tickUpper=Number(pos[6]),liquidity=pos[7],owed0=pos[10],owed1=pos[11];
 const sqrtA=tickToSqrtX96(tickLower), sqrtB=tickToSqrtX96(tickUpper);
 const {a0,a1}=amountsFor(sqrtP,sqrtA,sqrtB,liquidity);
 const t0=cfg.token0.toLowerCase(), t1=cfg.token1.toLowerCase();
 const d0=decByAddr[t0]??18, d1=decByAddr[t1]??18;
 const p0=await priceUSD(t0), p1=await priceUSD(t1);
 const tot0=a0+owed0, tot1=a1+owed1;
 const usd0=toUsd(tot0,d0,p0), usd1=toUsd(tot1,d1,p1);
 lpHoldingsUSD+=usd0+usd1;
 const inRange = Number(slot0[1])>=tickLower && Number(slot0[1])<=tickUpper;
 console.log(`${pr.name}: tokenId=${tokenId} inRange=${inRange} principalVY=${fmt(principalVY).toFixed(2)}`);
 console.log(`   token0 amt=${fmt(tot0,d0).toFixed(6)} ($${fmt(usd0).toFixed(2)})  token1 amt=${fmt(tot1,d1).toFixed(6)} ($${fmt(usd1).toFixed(2)})  => $${fmt(usd0+usd1).toFixed(2)}`);
 console.log(`   LP value per principalVY = $${(fmt(usd0+usd1)/fmt(principalVY)).toFixed(5)} / VY`);
}
console.log(`\nlpHoldingsUSD (total) = $${fmt(lpHoldingsUSD).toFixed(2)}`);

const deployed=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'capVRYO_total'});
console.log(`capVRYO_total = ${fmt(deployed).toFixed(2)} VY`);
console.log(`VRYO-leg floor = $${(fmt(lpHoldingsUSD)/fmt(deployed)).toFixed(5)} / deployed VY`);

// round floor recompute (VCO leg from prior script: reserveUSD 4290.35, cap 64523.74)
const vrtUSD=4290.35, vcoCap=64523.74;
const rf=(vrtUSD+fmt(lpHoldingsUSD))/(vcoCap+fmt(deployed));
console.log(`\nRound Floor (recomputed) = ($${vrtUSD.toFixed(2)} + $${fmt(lpHoldingsUSD).toFixed(2)}) / (${vcoCap.toFixed(0)} + ${fmt(deployed).toFixed(0)}) VY = $${rf.toFixed(5)} / VY`);

import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });

const VRYO='0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const VLM='0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0';
const VAO='0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const NPM='0xC36442b4a4522E871399CD717aBDD847Ab11FE88';
const USDC='0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const decByAddr={'0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2':18,'0x2260fac5e5542a773aa44fbcfedf7c193bc2c599':8,'0x45804880de22913dafe09f4980848ece6ecbaf78':18,'0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48':6};
const symByAddr={'0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2':'WETH','0x2260fac5e5542a773aa44fbcfedf7c193bc2c599':'WBTC','0x45804880de22913dafe09f4980848ece6ecbaf78':'PAXG','0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48':'USDC'};

const vryoAbi=[{inputs:[],name:'PAIR_PAXG_USDC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},{inputs:[],name:'PAIR_WETH_WBTC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'}];
const vlmAbi=[
 {inputs:[{type:'bytes32'}],name:'pairConfig',outputs:[{components:[{name:'pool',type:'address'},{name:'fee',type:'uint24'},{name:'tickSpacing',type:'int24'},{name:'l',type:'uint32'},{name:'u',type:'uint32'},{name:'token0',type:'address'},{name:'a',type:'uint32'},{name:'b',type:'uint32'},{name:'c',type:'uint32'},{name:'d',type:'uint32'},{name:'token1',type:'address'},{name:'e',type:'uint256'},{name:'f',type:'uint256'},{name:'g',type:'address'},{name:'h',type:'bool'},{name:'i',type:'uint16'}],type:'tuple'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'bytes32'}],name:'activeTokenId',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'bytes32'}],name:'lastRebalanceAt',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
];
const poolAbi=[
 {inputs:[],name:'slot0',outputs:[{name:'sqrtPriceX96',type:'uint160'},{name:'tick',type:'int24'},{type:'uint16'},{type:'uint16'},{type:'uint16'},{type:'uint8'},{type:'bool'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'feeGrowthGlobal0X128',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'feeGrowthGlobal1X128',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'int24'}],name:'ticks',outputs:[{type:'uint128'},{type:'int128'},{name:'fg0',type:'uint256'},{name:'fg1',type:'uint256'},{type:'int56'},{type:'uint160'},{type:'uint32'},{type:'bool'}],stateMutability:'view',type:'function'},
];
const npmAbi=[{inputs:[{type:'uint256'}],name:'positions',outputs:[{type:'uint96'},{type:'address'},{type:'address'},{type:'address'},{type:'uint24'},{type:'int24'},{type:'int24'},{type:'uint128'},{type:'uint256'},{type:'uint256'},{type:'uint128'},{type:'uint128'}],stateMutability:'view',type:'function'}];
const vaoAbi=[{inputs:[{type:'address'}],name:'getAssetTwapPrice',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];

const WAD=10n**18n, Q96=2n**96n, Q128=2n**128n;
const U256=(x)=>BigInt.asUintN(256,x);
const tickToSqrtX96=(t)=>BigInt(Math.floor(Math.sqrt(Math.pow(1.0001,t))*Number(Q96)));
function amountsFor(sqrtP,sqrtA,sqrtB,L){if(sqrtA>sqrtB){const t=sqrtA;sqrtA=sqrtB;sqrtB=t;}if(sqrtP<=sqrtA)return{a0:(L*(sqrtB-sqrtA)*Q96)/(sqrtB*sqrtA),a1:0n};if(sqrtP>=sqrtB)return{a0:0n,a1:(L*(sqrtB-sqrtA))/Q96};return{a0:(L*(sqrtB-sqrtP)*Q96)/(sqrtB*sqrtP),a1:(L*(sqrtP-sqrtA))/Q96};}
const pc={};
async function priceUSD(a){a=a.toLowerCase();if(a===USDC.toLowerCase())return WAD;if(pc[a]!==undefined)return pc[a];let p=0n;try{p=await client.readContract({address:VAO,abi:vaoAbi,functionName:'getAssetTwapPrice',args:[a]});}catch(e){}pc[a]=p;return p;}
const toUsd=(raw,d,p)=>(raw*(10n**BigInt(18-d))*p)/WAD;
const fmt=(x,d=18)=>Number(formatUnits(x,d));

const pk_pu=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_PAXG_USDC'});
const pk_ww=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_WETH_WBTC'});
const block=await client.getBlock();
const now=Number(block.timestamp);

for(const pr of [{name:'PAXG/USDC',key:pk_pu},{name:'WETH/WBTC',key:pk_ww}]){
 const cfg=await client.readContract({address:VLM,abi:vlmAbi,functionName:'pairConfig',args:[pr.key]});
 const tokenId=await client.readContract({address:VLM,abi:vlmAbi,functionName:'activeTokenId',args:[pr.key]});
 const lastReb=await client.readContract({address:VLM,abi:vlmAbi,functionName:'lastRebalanceAt',args:[pr.key]});
 if(tokenId===0n){console.log(`${pr.name}: no position`);continue;}
 const [slot0,fg0g,fg1g,pos]=await Promise.all([
  client.readContract({address:cfg.pool,abi:poolAbi,functionName:'slot0'}),
  client.readContract({address:cfg.pool,abi:poolAbi,functionName:'feeGrowthGlobal0X128'}),
  client.readContract({address:cfg.pool,abi:poolAbi,functionName:'feeGrowthGlobal1X128'}),
  client.readContract({address:NPM,abi:npmAbi,functionName:'positions',args:[tokenId]}),
 ]);
 const tickCur=Number(slot0[1]);
 const tickLower=Number(pos[5]),tickUpper=Number(pos[6]),L=pos[7];
 const fgInside0Last=pos[8],fgInside1Last=pos[9],owed0=pos[10],owed1=pos[11];
 const [tl,tu]=await Promise.all([
  client.readContract({address:cfg.pool,abi:poolAbi,functionName:'ticks',args:[tickLower]}),
  client.readContract({address:cfg.pool,abi:poolAbi,functionName:'ticks',args:[tickUpper]}),
 ]);
 const lo0=tl[2],lo1=tl[3],up0=tu[2],up1=tu[3];
 // feeGrowthInside per Uniswap V3 core
 function inside(fgG,loOut,upOut){
  const below = tickCur>=tickLower ? loOut : U256(fgG-loOut);
  const above = tickCur<tickUpper ? upOut : U256(fgG-upOut);
  return U256(fgG-below-above);
 }
 const in0=inside(fg0g,lo0,up0), in1=inside(fg1g,lo1,up1);
 const accrued0 = (L*U256(in0-fgInside0Last))/Q128;
 const accrued1 = (L*U256(in1-fgInside1Last))/Q128;
 const liveFee0 = owed0+accrued0, liveFee1=owed1+accrued1;

 const t0=cfg.token0.toLowerCase(),t1=cfg.token1.toLowerCase();
 const d0=decByAddr[t0]??18,d1=decByAddr[t1]??18;
 const p0=await priceUSD(t0),p1=await priceUSD(t1);

 const owedUSD = fmt(toUsd(owed0,d0,p0))+fmt(toUsd(owed1,d1,p1));
 const accruedUSD = fmt(toUsd(accrued0,d0,p0))+fmt(toUsd(accrued1,d1,p1));
 const liveUSD = fmt(toUsd(liveFee0,d0,p0))+fmt(toUsd(liveFee1,d1,p1));

 const sqrtA=tickToSqrtX96(tickLower),sqrtB=tickToSqrtX96(tickUpper);
 const {a0,a1}=amountsFor(slot0[0],sqrtA,sqrtB,L);
 const princUSD = fmt(toUsd(a0,d0,p0))+fmt(toUsd(a1,d1,p1));

 console.log(`\n=== ${pr.name} (token0=${symByAddr[t0]}, token1=${symByAddr[t1]}) ===`);
 console.log(`last rebalance: ${lastReb>0n?((now-Number(lastReb))/86400).toFixed(1)+' days ago':'never'}`);
 console.log(`principal (liquidity MTM):           $${princUSD.toFixed(2)}`);
 console.log(`tokensOwed (checkpointed, COUNTED):  $${owedUSD.toFixed(4)}   [${symByAddr[t0]} ${fmt(owed0,d0).toFixed(6)} / ${symByAddr[t1]} ${fmt(owed1,d1).toFixed(6)}]`);
 console.log(`accrued since last poke (MISSING):   $${accruedUSD.toFixed(4)}   [${symByAddr[t0]} ${fmt(accrued0,d0).toFixed(6)} / ${symByAddr[t1]} ${fmt(accrued1,d1).toFixed(6)}]`);
 console.log(`live uncollected total:              $${liveUSD.toFixed(4)}`);
 console.log(`=> floor undercount for this pair:   $${accruedUSD.toFixed(4)} (${(princUSD>0?accruedUSD/princUSD*100:0).toFixed(3)}% of principal)`);
}

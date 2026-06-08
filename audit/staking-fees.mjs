import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const VRYO='0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const VLM='0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0', VLM_OLD='0xfd2D528afAA5e7D58811ae859080E5e974Aa7392';
const VRT='0x06087789B7122fA92E7F9868B10A286Dd4e4C832', NPM='0xC36442b4a4522E871399CD717aBDD847Ab11FE88', VAO='0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const A={WETH:'0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',WBTC:'0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',PAXG:'0x45804880de22913dafe09f4980848ece6ecbaf78',USDC:'0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'};
const sym=a=>Object.keys(A).find(k=>A[k].toLowerCase()===a.toLowerCase())||a.slice(0,8);
const dec={WETH:18,WBTC:8,PAXG:18,USDC:6}; const WAD=10n**18n; const fmt=(x,d=18)=>Number(formatUnits(x,d));
const pc={}; async function price(a){a=a.toLowerCase();if(a===A.USDC.toLowerCase())return WAD;if(pc[a]!==undefined)return pc[a];let p=0n;try{p=await client.readContract({address:VAO,abi:[{inputs:[{type:'address'}],name:'getAssetTwapPrice',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}],functionName:'getAssetTwapPrice',args:[a]});}catch(e){}pc[a]=p;return p;}
const toUsd=(raw,d,p)=>(raw*(10n**BigInt(18-d))*p)/WAD;

const mintedEv=parseAbiItem('event PositionMinted(bytes32 indexed pairKey, uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1)');
const rebalEv=parseAbiItem('event PositionRebalanced(bytes32 indexed pairKey, uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity)');
const collectEv=parseAbiItem('event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1)');
const decEv=parseAbiItem('event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)');

// gather managed tokenIds + their pair + token0/token1
const tokIds=new Set(), tokPair=new Map(), tokTokens=new Map();
for(const addr of [VLM,VLM_OLD]){
 const [mints,rebs]=await Promise.all([
  client.getLogs({address:addr,event:mintedEv,fromBlock:0n,toBlock:'latest'}),
  client.getLogs({address:addr,event:rebalEv,fromBlock:0n,toBlock:'latest'}),
 ]);
 for(const l of mints){tokIds.add(l.args.tokenId);tokPair.set(l.args.tokenId,l.args.pairKey);}
 for(const l of rebs){tokIds.add(l.args.oldTokenId);tokIds.add(l.args.newTokenId);tokPair.set(l.args.oldTokenId,l.args.pairKey);tokPair.set(l.args.newTokenId,l.args.pairKey);}
 console.log(`${addr===VLM?'VLM':'VLM_OLD'}: ${mints.length} mints, ${rebs.length} rebalances`);
}
const ids=[...tokIds];
const npmAbi=[{inputs:[{type:'uint256'}],name:'positions',outputs:[{type:'uint96'},{type:'address'},{type:'address'},{type:'address'},{type:'uint24'},{type:'int24'},{type:'int24'},{type:'uint128'},{type:'uint256'},{type:'uint256'},{type:'uint128'},{type:'uint128'}],stateMutability:'view',type:'function'}];
const posR=await client.multicall({contracts:ids.map(id=>({address:NPM,abi:npmAbi,functionName:'positions',args:[id]})),allowFailure:true});
ids.forEach((id,i)=>{if(posR[i].status==='success'){const p=posR[i].result;tokTokens.set(id,{t0:p[2],t1:p[3]});}});

// fees = Collect - DecreaseLiquidity, with recipient breakdown
const [cols,decs]=await Promise.all([
 client.getLogs({address:NPM,event:collectEv,args:{tokenId:ids},fromBlock:0n,toBlock:'latest'}),
 client.getLogs({address:NPM,event:decEv,args:{tokenId:ids},fromBlock:0n,toBlock:'latest'}),
]);
const decById=new Map();
for(const l of decs){const e=decById.get(l.args.tokenId)||{d0:0n,d1:0n};e.d0+=l.args.amount0;e.d1+=l.args.amount1;decById.set(l.args.tokenId,e);}
const recipients={};
const colById=new Map();
for(const l of cols){const e=colById.get(l.args.tokenId)||{c0:0n,c1:0n};e.c0+=l.args.amount0;e.c1+=l.args.amount1;colById.set(l.args.tokenId,e);recipients[l.args.recipient]=(recipients[l.args.recipient]||0)+1;}
console.log('\nCollect recipients:',Object.fromEntries(Object.entries(recipients).map(([k,v])=>[k===VRT?'VRT':k===VLM?'VLM':k===VLM_OLD?'VLM_OLD':k,v])));

let feeUSD=0n;
console.log('\n=== Fees earned per tokenId (Collect - Decrease) ===');
for(const id of ids){
 const c=colById.get(id)||{c0:0n,c1:0n}; const d=decById.get(id)||{d0:0n,d1:0n};
 const f0=c.c0-d.d0, f1=c.c1-d.d1; const tk=tokTokens.get(id);
 if(!tk) continue;
 const v=toUsd(f0>0n?f0:0n,dec[sym(tk.t0)],await price(tk.t0))+toUsd(f1>0n?f1:0n,dec[sym(tk.t1)],await price(tk.t1));
 feeUSD+=v;
 if(f0>0n||f1>0n) console.log(`#${id} ${sym(tk.t0)}/${sym(tk.t1)}: fee0=${fmt(f0,dec[sym(tk.t0)]).toFixed(6)} fee1=${fmt(f1,dec[sym(tk.t1)]).toFixed(6)} ($${fmt(v).toFixed(2)})`);
}
console.log(`\nTotal LP fees earned (lifetime, all positions) = $${fmt(feeUSD).toFixed(2)}`);
console.log('(If recipient=VRT, these are already credited in net-consumed via VRYO->VRT? NO - direct pool->VRT. Must add as credit.)');

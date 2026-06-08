import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const VRYO='0xA95749f52031dA2c4baB7cf38323B69A9E3415d3', VLM='0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0';
const VAO='0x7a0E582479579e1423bc4f1DFD0750feA9282B01', NPM='0xC36442b4a4522E871399CD717aBDD847Ab11FE88';
const FACTORY='0x1F98431c8aD98523631AE4a59f267346ea31F984';
const A={WETH:'0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',WBTC:'0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',PAXG:'0x45804880de22913dafe09f4980848ece6ecbaf78',USDC:'0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'};
const sym=a=>Object.keys(A).find(k=>A[k].toLowerCase()===a.toLowerCase())||a.slice(0,8);
const dec={WETH:18,WBTC:8,PAXG:18,USDC:6}; const WAD=10n**18n; const fmt=(x,d=18)=>Number(formatUnits(x,d));
const pc={}; async function price(a){a=a.toLowerCase();if(a===A.USDC.toLowerCase())return WAD;if(pc[a]!==undefined)return pc[a];let p=0n;try{p=await client.readContract({address:VAO,abi:[{inputs:[{type:'address'}],name:'getAssetTwapPrice',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}],functionName:'getAssetTwapPrice',args:[a]});}catch(e){}pc[a]=p;return p;}
const toUsd=(raw,d,p)=>(raw*(10n**BigInt(18-d))*p)/WAD;
const facAbi=[{inputs:[{type:'address'},{type:'address'},{type:'uint24'}],name:'getPool',outputs:[{type:'address'}],stateMutability:'view',type:'function'}];
const erc=[{inputs:[{type:'address'}],name:'balanceOf',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];

console.log('========== POOL / FEE-TIER OPTIONS (TVL = pool token balances in USD) ==========');
for(const [pair,t0,t1] of [['WETH/WBTC',A.WETH,A.WBTC],['PAXG/USDC',A.PAXG,A.USDC]]){
 for(const fee of [500,3000]){
  const pool=await client.readContract({address:FACTORY,abi:facAbi,functionName:'getPool',args:[t0,t1,fee]});
  if(pool==='0x0000000000000000000000000000000000000000'){console.log(`${pair} ${fee/1e4}%: NO POOL`);continue;}
  const [b0,b1]=await Promise.all([client.readContract({address:t0,abi:erc,functionName:'balanceOf',args:[pool]}),client.readContract({address:t1,abi:erc,functionName:'balanceOf',args:[pool]})]);
  const tvl=fmt(toUsd(b0,dec[sym(t0)],await price(t0)))+fmt(toUsd(b1,dec[sym(t1)],await price(t1)));
  console.log(`${pair} ${fee/1e4}%: pool=${pool}  TVL~$${tvl.toFixed(0)}  (${sym(t0)} ${fmt(b0,dec[sym(t0)]).toFixed(4)} / ${sym(t1)} ${fmt(b1,dec[sym(t1)]).toFixed(4)})`);
 }
}

const vryoAbi=[{inputs:[],name:'PAIR_PAXG_USDC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},{inputs:[],name:'PAIR_WETH_WBTC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},{inputs:[],name:'slippageBps',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];
const vlmAbi=[
 {inputs:[{type:'bytes32'}],name:'pairConfig',outputs:[{components:[{name:'pool',type:'address'},{name:'fee',type:'uint24'},{name:'tickSpacing',type:'int24'},{name:'lowerRangeBps',type:'uint16'},{name:'upperRangeBps',type:'uint16'},{name:'token0',type:'address'},{name:'minRefreshInterval',type:'uint32'},{name:'minRebalanceInterval',type:'uint32'},{name:'mintSlippageBps',type:'uint16'},{name:'closeSlippageBps',type:'uint16'},{name:'token1',type:'address'},{name:'seedAmount0',type:'uint256'},{name:'seedAmount1',type:'uint256'},{name:'managedReserve',type:'address'},{name:'needsZap',type:'bool'},{name:'zapSlippageBps',type:'uint16'}],type:'tuple'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'nearBandBps',outputs:[{type:'uint16'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'snapbackConfig',outputs:[{type:'bytes32'},{type:'bytes32'},{type:'uint16'},{type:'uint32'}],stateMutability:'view',type:'function'},
];
const pk_pu=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_PAXG_USDC'});
const pk_ww=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_WETH_WBTC'});
let nbb=0,sc=null,vslip=0n;
try{nbb=await client.readContract({address:VLM,abi:vlmAbi,functionName:'nearBandBps'});}catch(e){}
try{sc=await client.readContract({address:VLM,abi:vlmAbi,functionName:'snapbackConfig'});}catch(e){}
try{vslip=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'slippageBps'});}catch(e){}
console.log('\n========== LIVE CONFIG ==========');
let cfgWW;
for(const [name,pk] of [['WETH/WBTC',pk_ww],['PAXG/USDC',pk_pu]]){
 const c=await client.readContract({address:VLM,abi:vlmAbi,functionName:'pairConfig',args:[pk]});
 if(name==='WETH/WBTC') cfgWW=c;
 console.log(`${name}: feeTier=${c.fee/1e4}% band=[+${c.lowerRangeBps/100}%,-${c.upperRangeBps/100}%] tickSpacing=${c.tickSpacing} mintSlip=${c.mintSlippageBps/100}% closeSlip=${c.closeSlippageBps/100}% zapSlip=${c.zapSlippageBps/100}% minRebalInterval=${c.minRebalanceInterval}s needsZap=${c.needsZap} managedReserve=${c.managedReserve==='0x0000000000000000000000000000000000000000'?'BOTH managed':sym(c.managedReserve)}`);
}
console.log(`VLM nearBandBps=${nbb} (=${nbb/100}% of half-width) ; snapback defaultBps=${sc?Number(sc[2]):'?'} cooldown=${sc?Number(sc[3]):'?'}s ; VRYO deploy slippageBps=${Number(vslip)} (=${Number(vslip)/100}%)`);
console.log(`Re-center rule: allow = (out-of-range) OR (within ${nbb/100}% of a band edge) OR (accrued fees >= swap cost), throttled by cooldown.`);

const rebalEv=parseAbiItem('event PositionRebalanced(bytes32 indexed pairKey, uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity)');
const depEv=parseAbiItem('event Deployed(address indexed asset, uint256 vyTake, bytes32 indexed pairKey, uint256 pullAmount, uint128 liquidityMinted)');
const rebsWW=await client.getLogs({address:VLM,event:rebalEv,args:{pairKey:pk_ww},fromBlock:0n,toBlock:'latest'});
const rebsPU=await client.getLogs({address:VLM,event:rebalEv,args:{pairKey:pk_pu},fromBlock:0n,toBlock:'latest'});
const deps=await client.getLogs({address:VRYO,event:depEv,fromBlock:0n,toBlock:'latest'});
const bf=await client.getBlock({blockNumber:deps[0].blockNumber}); const bn=await client.getBlock();
const days=(Number(bn.timestamp)-Number(bf.timestamp))/86400;
console.log(`\n========== CADENCE (over ${days.toFixed(1)} days) ==========`);
console.log(`WETH/WBTC rebalances: ${rebsWW.length} (${(rebsWW.length/days*7).toFixed(1)}/week)`);
console.log(`PAXG/USDC rebalances: ${rebsPU.length} (${(rebsPU.length/days*7).toFixed(1)}/week)`);

const swapEv=parseAbiItem('event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)');
const d0=dec[sym(cfgWW.token0)],d1=dec[sym(cfgWW.token1)];
console.log(`\n========== PER-REBALANCE SWAP COST (last 6 WETH/WBTC, token0=${sym(cfgWW.token0)} token1=${sym(cfgWW.token1)}) ==========`);
for(const r of rebsWW.slice(-6)){
 const sw=await client.getLogs({address:cfgWW.pool,event:swapEv,fromBlock:r.blockNumber,toBlock:r.blockNumber});
 for(const s of sw){
  const a0=s.args.amount0,a1=s.args.amount1; const sp=Number(s.args.sqrtPriceX96)/2**96; const mid=sp*sp*Math.pow(10,d0-d1);
  const exec=Math.abs(fmt(a1<0n?-a1:a1,d1)/fmt(a0<0n?-a0:a0,d0));
  const inUSD=fmt(toUsd(a0>0n?a0:0n,d0,await price(cfgWW.token0)))+fmt(toUsd(a1>0n?a1:0n,d1,await price(cfgWW.token1)));
  console.log(`tx ${s.transactionHash.slice(0,18)}.. blk ${r.blockNumber}: swapIn~$${inUSD.toFixed(0)}  exec=${exec.toFixed(4)} postMid=${mid.toFixed(4)}  cost~${Math.abs((exec/mid-1)*100).toFixed(3)}% (fee+impact)`);
 }
}

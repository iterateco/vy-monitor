import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const VRYO='0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const VLM='0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0', VLM_OLD='0xfd2D528afAA5e7D58811ae859080E5e974Aa7392';
const VAO='0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const A={WETH:'0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',WBTC:'0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',PAXG:'0x45804880de22913dafe09f4980848ece6ecbaf78',USDC:'0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'};
const sym=a=>Object.keys(A).find(k=>A[k].toLowerCase()===a.toLowerCase())||a.slice(0,8);
const dec={WETH:18,WBTC:8,PAXG:18,USDC:6}; const WAD=10n**18n; const fmt=(x,d=18)=>Number(formatUnits(x,d));
const pc={}; async function price(a){a=a.toLowerCase();if(a===A.USDC.toLowerCase())return WAD;if(pc[a]!==undefined)return pc[a];let p=0n;try{p=await client.readContract({address:VAO,abi:[{inputs:[{type:'address'}],name:'getAssetTwapPrice',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}],functionName:'getAssetTwapPrice',args:[a]});}catch(e){}pc[a]=p;return p;}
const toUsd=(raw,d,p)=>(raw*(10n**BigInt(18-d))*p)/WAD;
const absB=x=>x<0n?-x:x;

const vryoAbi=[{inputs:[],name:'PAIR_PAXG_USDC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},{inputs:[],name:'PAIR_WETH_WBTC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},{inputs:[],name:'slippageBps',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},{inputs:[],name:'deployRatioBps',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'},{inputs:[],name:'keeperThresholdBps',outputs:[{type:'uint16'}],stateMutability:'view',type:'function'}];
const vlmAbi=[{inputs:[{type:'bytes32'}],name:'pairConfig',outputs:[{components:[{name:'pool',type:'address'},{name:'fee',type:'uint24'},{name:'tickSpacing',type:'int24'},{name:'lowerRangeBps',type:'uint32'},{name:'upperRangeBps',type:'uint32'},{name:'token0',type:'address'},{name:'a',type:'uint32'},{name:'b',type:'uint32'},{name:'c',type:'uint32'},{name:'d',type:'uint32'},{name:'token1',type:'address'},{name:'e',type:'uint256'},{name:'f',type:'uint256'},{name:'g',type:'address'},{name:'h',type:'bool'},{name:'cooldown',type:'uint16'}],type:'tuple'}],stateMutability:'view',type:'function'}];

const pk_pu=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_PAXG_USDC'});
const pk_ww=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_WETH_WBTC'});
const cfgWW=await client.readContract({address:VLM,abi:vlmAbi,functionName:'pairConfig',args:[pk_ww]});
const cfgPU=await client.readContract({address:VLM,abi:vlmAbi,functionName:'pairConfig',args:[pk_pu]});
let slip=0n,dr=0n,kt=0;
try{slip=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'slippageBps'});}catch(e){}
try{dr=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'deployRatioBps'});}catch(e){}
try{kt=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'keeperThresholdBps'});}catch(e){}

console.log('=== CONFIG ===');
console.log(`WETH/WBTC: pool=${cfgWW.pool} feeTier=${cfgWW.fee/10000}% rangeBps=[${cfgWW.lowerRangeBps},${cfgWW.upperRangeBps}] tickSpacing=${cfgWW.tickSpacing} cooldown=${cfgWW.cooldown}s`);
console.log(`PAXG/USDC: pool=${cfgPU.pool} feeTier=${cfgPU.fee/10000}% rangeBps=[${cfgPU.lowerRangeBps},${cfgPU.upperRangeBps}] tickSpacing=${cfgPU.tickSpacing} cooldown=${cfgPU.cooldown}s`);
console.log(`VRYO: deployRatio=${Number(dr)/100}% slippage=${Number(slip)/100}% keeperThreshold=${kt/100}%`);
console.log(`Range width WETH/WBTC = ${(cfgWW.lowerRangeBps+cfgWW.upperRangeBps)/100}% total`);

// timeline + cadence
const depEv=parseAbiItem('event Deployed(address indexed asset, uint256 vyTake, bytes32 indexed pairKey, uint256 pullAmount, uint128 liquidityMinted)');
const rebalEv=parseAbiItem('event PositionRebalanced(bytes32 indexed pairKey, uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity)');
const deps=await client.getLogs({address:VRYO,event:depEv,fromBlock:0n,toBlock:'latest'});
const rebsWW=(await client.getLogs({address:VLM,event:rebalEv,args:{pairKey:pk_ww},fromBlock:0n,toBlock:'latest'}));
const rebsPU=(await client.getLogs({address:VLM,event:rebalEv,args:{pairKey:pk_pu},fromBlock:0n,toBlock:'latest'}));
const firstBlk=deps[0].blockNumber, lastBlk=(await client.getBlock()).number;
const [bf,bl]=await Promise.all([client.getBlock({blockNumber:firstBlk}),client.getBlock({blockNumber:lastBlk})]);
const days=(Number(bl.timestamp)-Number(bf.timestamp))/86400;
console.log(`\n=== TIMELINE ===`);
console.log(`First deploy: block ${firstBlk}  (${new Date(Number(bf.timestamp)*1000).toISOString().slice(0,10)})`);
console.log(`Now:          block ${lastBlk}`);
console.log(`Active period: ${days.toFixed(1)} days`);
console.log(`Rebalances: WETH/WBTC=${rebsWW.length}  PAXG/USDC=${rebsPU.length}  => WETH/WBTC ${(rebsWW.length/days).toFixed(1)}/day`);

// swap fees paid by the system on each pool (recipient = VRYO or VLM)
const swapEv=parseAbiItem('event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)');
async function swapCost(pool,cfg,label){
 let logs=[];
 for(const r of [VRYO,VLM,VLM_OLD]){
  try{ logs=logs.concat(await client.getLogs({address:pool,event:swapEv,args:{recipient:r},fromBlock:0n,toBlock:'latest'})); }catch(e){}
 }
 const t0=cfg.token0,t1=cfg.token1,d0=dec[sym(t0)],d1=dec[sym(t1)],p0=await price(t0),p1=await price(t1);
 let vol0=0n,vol1=0n;
 for(const l of logs){ // amountIn is the positive side into the pool
  const a0=l.args.amount0,a1=l.args.amount1;
  if(a0>0n) vol0+=a0; if(a1>0n) vol1+=a1; // positive = token into pool (the input being swapped)
 }
 const volUSD=fmt(toUsd(vol0,d0,p0))+fmt(toUsd(vol1,d1,p1));
 const feePaid=volUSD*(cfg.fee/1e6);
 console.log(`${label}: ${logs.length} system swaps  inputVolume=$${volUSD.toFixed(2)}  feeTier=${cfg.fee/1e4}%  => swapFees~$${feePaid.toFixed(2)}`);
 return feePaid;
}
console.log(`\n=== SWAP COSTS (zap on deploys + rebalances) ===`);
const fWW=await swapCost(cfgWW.pool,cfgWW,'WETH/WBTC');
const fPU=await swapCost(cfgPU.pool,cfgPU,'PAXG/USDC');
const totalSwapFees=fWW+fPU;

console.log(`\n=== ATTRIBUTION of the -$9,463 total loss ===`);
console.log(`Explicit swap fees paid (pool fee tier x volume): ~$${totalSwapFees.toFixed(2)}`);
console.log(`Realized IL + slippage (remainder):               ~$${(9463-totalSwapFees).toFixed(2)}`);
console.log(`Annualized loss rate: ${(35/days*365).toFixed(0)}% /yr (35% over ${days.toFixed(1)} days)`);

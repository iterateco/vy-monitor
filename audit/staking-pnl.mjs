import { createPublicClient, http, formatUnits, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });

const VRYO='0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const VLM='0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0';
const VLM_OLD='0xfd2D528afAA5e7D58811ae859080E5e974Aa7392';
const VRT='0x06087789B7122fA92E7F9868B10A286Dd4e4C832';
const VAO='0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const NPM='0xC36442b4a4522E871399CD717aBDD847Ab11FE88';
const A={WETH:'0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',WBTC:'0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',PAXG:'0x45804880de22913dafe09f4980848ece6ecbaf78',USDC:'0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'};
const sym=a=>Object.keys(A).find(k=>A[k].toLowerCase()===a.toLowerCase())||a.slice(0,8);
const dec={WETH:18,WBTC:8,PAXG:18,USDC:6};
const WAD=10n**18n,Q96=2n**96n,Q128=2n**128n;
const fmt=(x,d=18)=>Number(formatUnits(x,d));

// exact Uniswap TickMath.getSqrtRatioAtTick
function getSqrtRatioAtTick(tick){
 const abs=BigInt(Math.abs(tick));
 let r=(abs & 1n)!==0n ? 0xfffcb933bd6fad37aa2d162d1a594001n : 0x100000000000000000000000000000000n;
 const m=[[0x2n,0xfff97272373d413259a46990580e213an],[0x4n,0xfff2e50f5f656932ef12357cf3c7fdccn],[0x8n,0xffe5caca7e10e4e61c3624eaa0941cd0n],[0x10n,0xffcb9843d60f6159c9db58835c926644n],[0x20n,0xff973b41fa98c081472e6896dfb254c0n],[0x40n,0xff2ea16466c96a3843ec78b326b52861n],[0x80n,0xfe5dee046a99a2a811c461f1969c3053n],[0x100n,0xfcbe86c7900a88aedcffc83b479aa3a4n],[0x200n,0xf987a7253ac413176f2b074cf7815e54n],[0x400n,0xf3392b0822b70005940c7a398e4b70f3n],[0x800n,0xe7159475a2c29b7443b29c7fa6e889d9n],[0x1000n,0xd097f3bdfd2022b8845ad8f792aa5825n],[0x2000n,0xa9f746462d870fdf8a65dc1f90e061e5n],[0x4000n,0x70d869a156d2a1b890bb3df62baf32f7n],[0x8000n,0x31be135f97d08fd981231505542fcfa6n],[0x10000n,0x9aa508b5b7a84e1c677de54f3e99bc9n],[0x20000n,0x5d6af8dedb81196699c329225ee604n],[0x40000n,0x2216e584f5fa1ea926041bedfe98n],[0x80000n,0x48a170391f7dc42444e8fa2n]];
 for(const [bit,mul] of m){ if((abs & bit)!==0n) r=(r*mul)>>128n; }
 if(tick>0) r=(2n**256n-1n)/r;
 // round up div by 2^32 to Q96
 return (r>>32n) + ((r % (1n<<32n))===0n?0n:1n);
}
function amountsFor(sqrtP,tl,tu,L){
 let sa=getSqrtRatioAtTick(tl), sb=getSqrtRatioAtTick(tu);
 if(sa>sb){const t=sa;sa=sb;sb=t;}
 if(sqrtP<=sa) return {a0:(L*(sb-sa)*Q96)/(sb*sa),a1:0n};
 if(sqrtP>=sb) return {a0:0n,a1:(L*(sb-sa))/Q96};
 return {a0:(L*(sb-sqrtP)*Q96)/(sb*sqrtP),a1:(L*(sqrtP-sa))/Q96};
}
const pc={};
async function price(a){a=a.toLowerCase();if(a===A.USDC.toLowerCase())return WAD;if(pc[a]!==undefined)return pc[a];let p=0n;try{p=await client.readContract({address:VAO,abi:[{inputs:[{type:'address'}],name:'getAssetTwapPrice',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}],functionName:'getAssetTwapPrice',args:[a]});}catch(e){}pc[a]=p;return p;}
const toUsd=(raw,d,p)=>(raw*(10n**BigInt(18-d))*p)/WAD;

const depEv=parseAbiItem('event Deployed(address indexed asset, uint256 vyTake, bytes32 indexed pairKey, uint256 pullAmount, uint128 liquidityMinted)');
const recEv=parseAbiItem('event Recalled(address indexed asset, uint256 vyReduced, bytes32 indexed pairKey, uint128 liquidityBurned, uint256 amount0Out, uint256 amount1Out)');
const xfer=parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)');
const collectEv=parseAbiItem('event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1)');
const decEv=parseAbiItem('event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)');
const mintedEv=parseAbiItem('event PositionMinted(bytes32 indexed pairKey, uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1)');
const rebalEv=parseAbiItem('event PositionRebalanced(bytes32 indexed pairKey, uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity)');

const [deps,recs]=await Promise.all([
 client.getLogs({address:VRYO,event:depEv,fromBlock:0n,toBlock:'latest'}),
 client.getLogs({address:VRYO,event:recEv,fromBlock:0n,toBlock:'latest'}),
]);
console.log(`Deployed events: ${deps.length}   Recalled events: ${recs.length}`);

// net assets pulled from VRT by VRYO (covers deploys, recalls, fee sweeps, dust — everything)
const flow={}; for(const k of Object.keys(A)) flow[k]={in:0n,out:0n};
for(const [k,addr] of Object.entries(A)){
 const [inL,outL]=await Promise.all([
  client.getLogs({address:addr,event:xfer,args:{from:VRT,to:VRYO},fromBlock:0n,toBlock:'latest'}),
  client.getLogs({address:addr,event:xfer,args:{from:VRYO,to:VRT},fromBlock:0n,toBlock:'latest'}),
 ]);
 for(const l of inL) flow[k].in+=l.args.value;
 for(const l of outL) flow[k].out+=l.args.value;
}
// also fees collected directly to VRT from the pool (NPM Collect recipient=VRT won't show as VRYO transfer)
// capture via NPM Transfer? fees are ERC20 from pool to recipient; recipient could be VRT or VLM. Scan token transfers pool->VRT? hard. Use Collect events on managed tokenIds below.

console.log('\n=== Net assets consumed from VRT (in - out), valued at CURRENT price ===');
let netConsumedUSD=0n;
for(const [k,addr] of Object.entries(A)){
 const net=flow[k].in-flow[k].out;
 const p=await price(addr);
 const usd=net>0n?toUsd(net,dec[k],p):-toUsd(-net,dec[k],p);
 netConsumedUSD+=usd;
 console.log(`${k}: in=${fmt(flow[k].in,dec[k]).toFixed(6)} out=${fmt(flow[k].out,dec[k]).toFixed(6)} net=${fmt(net,dec[k]).toFixed(6)} ($${fmt(usd).toFixed(2)})`);
}
console.log(`Net consumed from VRT (current-price basis) = $${fmt(netConsumedUSD).toFixed(2)}`);

// current value still inside staking: LP positions + VRYO + VLM balances
const vlmAbi=[{inputs:[{type:'bytes32'}],name:'pairConfig',outputs:[{components:[{name:'pool',type:'address'},{name:'fee',type:'uint24'},{name:'ts',type:'int24'},{name:'l',type:'uint32'},{name:'u',type:'uint32'},{name:'token0',type:'address'},{name:'a',type:'uint32'},{name:'b',type:'uint32'},{name:'c',type:'uint32'},{name:'d',type:'uint32'},{name:'token1',type:'address'},{name:'e',type:'uint256'},{name:'f',type:'uint256'},{name:'g',type:'address'},{name:'h',type:'bool'},{name:'i',type:'uint16'}],type:'tuple'}],stateMutability:'view',type:'function'},{inputs:[{type:'bytes32'}],name:'activeTokenId',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];
const poolAbi=[{inputs:[],name:'slot0',outputs:[{name:'s',type:'uint160'},{name:'t',type:'int24'},{type:'uint16'},{type:'uint16'},{type:'uint16'},{type:'uint8'},{type:'bool'}],stateMutability:'view',type:'function'}];
const npmAbi=[{inputs:[{type:'uint256'}],name:'positions',outputs:[{type:'uint96'},{type:'address'},{type:'address'},{type:'address'},{type:'uint24'},{type:'int24'},{type:'int24'},{type:'uint128'},{type:'uint256'},{type:'uint256'},{type:'uint128'},{type:'uint128'}],stateMutability:'view',type:'function'}];
const vryoAbi=[{inputs:[],name:'PAIR_PAXG_USDC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},{inputs:[],name:'PAIR_WETH_WBTC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'},{inputs:[],name:'capVRYO_total',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];
const erc=[{inputs:[{type:'address'}],name:'balanceOf',outputs:[{type:'uint256'}],stateMutability:'view',type:'function'}];

const pk_pu=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_PAXG_USDC'});
const pk_ww=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_WETH_WBTC'});
let lpUSD=0n;
console.log('\n=== Current LP value (exact integer tick math) ===');
for(const pr of [{name:'PAXG/USDC',key:pk_pu},{name:'WETH/WBTC',key:pk_ww}]){
 const cfg=await client.readContract({address:VLM,abi:vlmAbi,functionName:'pairConfig',args:[pr.key]});
 const tid=await client.readContract({address:VLM,abi:vlmAbi,functionName:'activeTokenId',args:[pr.key]});
 if(tid===0n){console.log(`${pr.name}: none`);continue;}
 const s0=await client.readContract({address:cfg.pool,abi:poolAbi,functionName:'slot0'});
 const pos=await client.readContract({address:NPM,abi:npmAbi,functionName:'positions',args:[tid]});
 const tl=Number(pos[5]),tu=Number(pos[6]),L=pos[7];
 const {a0,a1}=amountsFor(s0[0],tl,tu,L);
 const t0=cfg.token0,t1=cfg.token1,d0=dec[sym(t0)],d1=dec[sym(t1)];
 const v0=toUsd(a0+pos[10],d0,await price(t0)),v1=toUsd(a1+pos[11],d1,await price(t1));
 lpUSD+=v0+v1;
 console.log(`${pr.name}: ticks[${tl},${tu}] cur=${Number(s0[1])} ${sym(t0)} ${fmt(a0,d0).toFixed(6)} + ${sym(t1)} ${fmt(a1,d1).toFixed(6)} = $${fmt(v0+v1).toFixed(2)}`);
}
let residUSD=0n;
for(const [k,addr] of Object.entries(A)){
 const [bV,bL]=await Promise.all([client.readContract({address:addr,abi:erc,functionName:'balanceOf',args:[VRYO]}),client.readContract({address:addr,abi:erc,functionName:'balanceOf',args:[VLM]})]);
 const p=await price(addr); residUSD+=toUsd(bV+bL,dec[k],p);
 if(bV+bL>0n) console.log(`residual ${k}: VRYO ${fmt(bV,dec[k])} + VLM ${fmt(bL,dec[k])}`);
}
const curValue=lpUSD+residUSD;
console.log(`\nCurrent value inside staking = LP $${fmt(lpUSD).toFixed(2)} + residual $${fmt(residUSD).toFixed(2)} = $${fmt(curValue).toFixed(2)}`);

console.log('\n========== STAKING P&L (all at current prices) ==========');
console.log(`Value still in staking : $${fmt(curValue).toFixed(2)}`);
console.log(`Net consumed from VRT  : $${fmt(netConsumedUSD).toFixed(2)}`);
const pnl=curValue-netConsumedUSD;
console.log(`Net staking P&L        : $${fmt(pnl).toFixed(2)}  (${(fmt(pnl)/fmt(netConsumedUSD)*100).toFixed(2)}%)`);
console.log(`\nNote: fees swept to VRT are counted as 'out' (returns), so this P&L = IL+swap-loss net of ALL fees, with realized returns credited.`);

const cap=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'capVRYO_total'});
console.log(`\ncapVRYO_total=${fmt(cap).toFixed(2)} VY  => current LP backs each deployed VY at $${(fmt(lpUSD)/fmt(cap)).toFixed(5)}`);

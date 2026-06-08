import { createPublicClient, http, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const VLM='0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0', VRYO='0xA95749f52031dA2c4baB7cf38323B69A9E3415d3';
const vryoAbi=[{inputs:[],name:'PAIR_WETH_WBTC',outputs:[{type:'bytes32'}],stateMutability:'view',type:'function'}];
const pk_ww=await client.readContract({address:VRYO,abi:vryoAbi,functionName:'PAIR_WETH_WBTC'});
const rebalEv=parseAbiItem('event PositionRebalanced(bytes32 indexed pairKey, uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity)');
const mintedEv=parseAbiItem('event PositionMinted(bytes32 indexed pairKey, uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1)');
const mints=await client.getLogs({address:VLM,event:mintedEv,args:{pairKey:pk_ww},fromBlock:0n,toBlock:'latest'});
const rebs=await client.getLogs({address:VLM,event:rebalEv,args:{pairKey:pk_ww},fromBlock:0n,toBlock:'latest'});
// token0=WBTC(8), token1=WETH(18). price token1 per token0 in raw = 1.0001^tick; human WETH per WBTC = 1.0001^tick * 10^(8-18)... actually price1/0 native; adjust decimals: WETHperWBTC = 1.0001^tick * 10^(dec0-dec1)=*10^(8-18)
const midToRatio=(tick)=>Math.pow(1.0001,tick)*Math.pow(10,8-18); // WETH per WBTC
const evs=[...mints.map(m=>({blk:m.blockNumber,tl:m.args.tickLower,tu:m.args.tickUpper,kind:'MINT'})),
          ...rebs.map(r=>({blk:r.blockNumber,tl:r.args.newTickLower,tu:r.args.newTickUpper,kind:'REBAL'}))]
          .sort((a,b)=>Number(a.blk-b.blk));
console.log('WETH/WBTC center price path (WETH per WBTC) at each (re)center:');
let prev=null,ups=0,downs=0,first=null,last=null;
for(const e of evs){
 const mid=(Number(e.tl)+Number(e.tu))/2;
 const r=midToRatio(mid);
 if(first===null)first=r; last=r;
 const d=prev!==null?((r-prev)/prev*100):0;
 if(prev!==null){if(r>prev)ups++;else downs++;}
 console.log(`${e.kind.padEnd(6)} tick=${mid.toFixed(0)}  WETHperWBTC=${r.toFixed(3)}  ${prev!==null?(d>=0?'+':'')+d.toFixed(2)+'%':''}`);
 prev=r;
}
console.log(`\nStart ratio=${first.toFixed(3)} End ratio=${last.toFixed(3)}  net move=${((last-first)/first*100).toFixed(1)}%`);
console.log(`Re-center steps up=${ups} down=${downs}  (trend if lopsided, whipsaw if ~balanced)`);

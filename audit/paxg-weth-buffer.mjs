import { createPublicClient, http } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const POOL='0x8A7e585048bdA875e64024118c506B14f78166dd'; // PAXG/WETH 0.3%
const poolAbi=[
 {inputs:[],name:'slot0',outputs:[{name:'sqrtPriceX96',type:'uint160'},{name:'tick',type:'int24'},{name:'observationIndex',type:'uint16'},{name:'observationCardinality',type:'uint16'},{name:'observationCardinalityNext',type:'uint16'},{name:'feeProtocol',type:'uint8'},{name:'unlocked',type:'bool'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'uint256'}],name:'observations',outputs:[{name:'blockTimestamp',type:'uint32'},{name:'tickCumulative',type:'int56'},{name:'secondsPerLiquidityCumulativeX128',type:'uint160'},{name:'initialized',type:'bool'}],stateMutability:'view',type:'function'},
];
const blk=await client.getBlock(); const now=Number(blk.timestamp);
const s0=await client.readContract({address:POOL,abi:poolAbi,functionName:'slot0'});
const card=Number(s0[3]);
const obs=[];
for(let i=0;i<card;i++){const o=await client.readContract({address:POOL,abi:poolAbi,functionName:'observations',args:[BigInt(i)]});obs.push({i,ts:Number(o[0]),init:o[3]});}
const sorted=obs.filter(o=>o.init).sort((a,b)=>a.ts-b.ts);
console.log(`now=${now}  cardinality=${card}\n`);
console.log('observations (oldest → newest), gap to next:');
for(let k=0;k<sorted.length;k++){
  const o=sorted[k]; const age=now-o.ts; const gap=k<sorted.length-1?sorted[k+1].ts-o.ts:null;
  console.log(`  slot${String(o.i).padStart(2)}  age=${String(age).padStart(5)}s  ${gap!==null?`gap=+${gap}s`:'(newest)'}`);
}
const span=sorted[sorted.length-1].ts-sorted[0].ts;
const avgGap=span/(sorted.length-1);
console.log(`\nbuffer span (oldest→newest) = ${span}s (~${(span/60).toFixed(1)} min)`);
console.log(`avg gap between observations = ${avgGap.toFixed(0)}s`);
console.log(`threshold to serve a 1800s TWAP with cardinality ${card}: need avg gap > ${(1800/(card-1)).toFixed(0)}s`);
console.log(`=> ${avgGap > 1800/(card-1) ? 'WOULD WORK' : 'TOO FREQUENT → buffer < 30min → "OLD"'}`);

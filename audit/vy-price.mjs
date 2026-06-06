import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const POOL='0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705';
const VY='0x597b29520098d6aaca3B2e0D1a380315c9240454';
const poolAbi=[
 {inputs:[],name:'getReserves',outputs:[{name:'r0',type:'uint112'},{name:'r1',type:'uint112'},{name:'t',type:'uint32'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'token0',outputs:[{type:'address'}],stateMutability:'view',type:'function'},
];
const [r,t0]=await Promise.all([
 client.readContract({address:POOL,abi:poolAbi,functionName:'getReserves'}),
 client.readContract({address:POOL,abi:poolAbi,functionName:'token0'}),
]);
const vyIs0 = t0.toLowerCase()===VY.toLowerCase();
const vyRes = vyIs0?r[0]:r[1];
const usdcRes = vyIs0?r[1]:r[0];
const price = Number(usdcRes)/1e6 / (Number(vyRes)/1e18);
console.log(`VY/USDC pool: VY reserve=${(Number(vyRes)/1e18).toFixed(2)}  USDC reserve=${(Number(usdcRes)/1e6).toFixed(2)}`);
console.log(`VY spot market price = $${price.toFixed(5)}`);
try{
 const md=await fetch('https://api.valinity.io/market-data?count=1').then(r=>r.json());
 console.log('MTP (market_trigger_price) =', md?.data?.[0]?.market_trigger_price);
}catch(e){console.log('MTP fetch failed',e.message);}

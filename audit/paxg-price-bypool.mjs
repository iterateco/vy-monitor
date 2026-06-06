import { createPublicClient, http } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const poolAbi=[
 {inputs:[],name:'slot0',outputs:[{name:'sqrtPriceX96',type:'uint160'},{name:'tick',type:'int24'},{name:'observationIndex',type:'uint16'},{name:'observationCardinality',type:'uint16'},{name:'observationCardinalityNext',type:'uint16'},{name:'feeProtocol',type:'uint8'},{name:'unlocked',type:'bool'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'uint32[]'}],name:'observe',outputs:[{type:'int56[]'},{type:'uint160[]'}],stateMutability:'view',type:'function'},
];
// PAXG=token0 vs USDC: human PAXG price in USD = 1.0001^tick * 10^(18-6)
async function priceUSDC(label,pool){
  const s0=await client.readContract({address:pool,abi:poolAbi,functionName:'slot0'});
  const spotTick=Number(s0[1]);
  const spot=Math.pow(1.0001,spotTick)*1e12;
  let twap='n/a';
  try{const [tc]=await client.readContract({address:pool,abi:poolAbi,functionName:'observe',args:[[0,1800]]});
      const avg=Number(tc[0]-tc[1])/1800; twap=(Math.pow(1.0001,avg)*1e12).toFixed(2);}catch(e){twap='OLD';}
  console.log(`${label}: spotTick=${spotTick}  spot=$${spot.toFixed(2)}  30m-TWAP=$${twap}`);
}
await priceUSDC('PAXG/USDC 0.05% (0x5aE1)','0x5aE13BAAEF0620FdaE1D355495Dc51a17adb4082');
await priceUSDC('PAXG/USDC 0.3%  (0xB431)','0xB431c70f800100D87554ac1142c4A94C5Fe4C0C4');
console.log('\nFor reference, current monitor value via PAXG->WETH->USDC two-hop = $4,469.28');

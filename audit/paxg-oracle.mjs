import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const VCO='0x2f02415989C3e02061a8e451EF64Dc59e5c0051C', VAO='0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const PAXG='0x45804880de22913dafe09f4980848ece6ecbaf78', USDC='0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', WETH='0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const FACTORY='0x1F98431c8aD98523631AE4a59f267346ea31F984';
const vcoAbi=[{inputs:[],name:'vao',outputs:[{type:'address'}],stateMutability:'view',type:'function'}];
const vaoAbi=[
 {inputs:[{type:'address'}],name:'assetTwapQuoteToken',outputs:[{type:'address'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'address'}],name:'assetTwapFeeTier',outputs:[{type:'uint24'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'wethUsdcTwapFeeTier',outputs:[{type:'uint24'}],stateMutability:'view',type:'function'},
];
const facAbi=[{inputs:[{type:'address'},{type:'address'},{type:'uint24'}],name:'getPool',outputs:[{type:'address'}],stateMutability:'view',type:'function'}];
const poolAbi=[
 {inputs:[],name:'slot0',outputs:[{name:'sqrtPriceX96',type:'uint160'},{name:'tick',type:'int24'},{name:'observationIndex',type:'uint16'},{name:'observationCardinality',type:'uint16'},{name:'observationCardinalityNext',type:'uint16'},{name:'feeProtocol',type:'uint8'},{name:'unlocked',type:'bool'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'uint256'}],name:'observations',outputs:[{name:'blockTimestamp',type:'uint32'},{name:'tickCumulative',type:'int56'},{name:'secondsPerLiquidityCumulativeX128',type:'uint160'},{name:'initialized',type:'bool'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'uint32[]'}],name:'observe',outputs:[{type:'int56[]'},{type:'uint160[]'}],stateMutability:'view',type:'function'},
];

const vcoVao = await client.readContract({address:VCO,abi:vcoAbi,functionName:'vao'});
console.log('VCO.vao()              :', vcoVao, vcoVao.toLowerCase()===VAO.toLowerCase()?'(== monitor VAO ✓)':'(!= monitor VAO ✗ DIFFERENT)');

const qt = await client.readContract({address:VAO,abi:vaoAbi,functionName:'assetTwapQuoteToken',args:[PAXG]});
const ft = await client.readContract({address:VAO,abi:vaoAbi,functionName:'assetTwapFeeTier',args:[PAXG]});
console.log('PAXG quoteToken        :', qt, qt==='0x0000000000000000000000000000000000000000'?'(direct→USDC)':qt.toLowerCase()===WETH.toLowerCase()?'(via WETH)':'');
console.log('PAXG feeTier           :', ft || '(0 → DEFAULT 3000)');

const block = await client.getBlock();
const now = Number(block.timestamp);
async function poolInfo(label, t0, t1, fee){
  const pool = await client.readContract({address:FACTORY,abi:facAbi,functionName:'getPool',args:[t0,t1,fee]});
  if (pool==='0x0000000000000000000000000000000000000000'){console.log(`${label} fee=${fee}: NO POOL`);return;}
  const s0 = await client.readContract({address:pool,abi:poolAbi,functionName:'slot0'});
  // oldest observation = at index (observationIndex+1)%cardinality
  const oldestIdx = (Number(s0[2])+1)%Number(s0[3]);
  const oldest = await client.readContract({address:pool,abi:poolAbi,functionName:'observations',args:[BigInt(oldestIdx)]});
  const oldestTs = oldest[3] ? Number(oldest[0]) : 'uninit';
  let observe1800='OK';
  try { await client.readContract({address:pool,abi:poolAbi,functionName:'observe',args:[[0,1800]]}); } catch(e){ observe1800='REVERT "'+(e.cause?.reason||e.shortMessage?.split('\n').pop()?.trim())+'"'; }
  console.log(`${label} fee=${fee} pool=${pool}`);
  console.log(`   cardinality=${s0[3]} cardinalityNext=${s0[4]} obsIndex=${s0[2]}  oldestObsAge=${oldestTs==='uninit'?'uninit':(now-oldestTs)+'s'}  observe([0,1800])=${observe1800}`);
}
const effFee = Number(ft)||3000;
await poolInfo('PAXG/USDC', PAXG, USDC, effFee);
if (qt.toLowerCase()===WETH.toLowerCase()){ await poolInfo('PAXG/WETH', PAXG, WETH, effFee); const wf=await client.readContract({address:VAO,abi:vaoAbi,functionName:'wethUsdcTwapFeeTier'}); await poolInfo('WETH/USDC', WETH, USDC, Number(wf)||3000);}

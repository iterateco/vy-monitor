import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const PAXG='0x45804880de22913dafe09f4980848ece6ecbaf78', USDC='0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', WETH='0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const FACTORY='0x1F98431c8aD98523631AE4a59f267346ea31F984';
const facAbi=[{inputs:[{type:'address'},{type:'address'},{type:'uint24'}],name:'getPool',outputs:[{type:'address'}],stateMutability:'view',type:'function'}];
const poolAbi=[
 {inputs:[],name:'slot0',outputs:[{name:'sqrtPriceX96',type:'uint160'},{name:'tick',type:'int24'},{name:'observationIndex',type:'uint16'},{name:'observationCardinality',type:'uint16'},{name:'observationCardinalityNext',type:'uint16'},{name:'feeProtocol',type:'uint8'},{name:'unlocked',type:'bool'}],stateMutability:'view',type:'function'},
 {inputs:[],name:'liquidity',outputs:[{type:'uint128'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'uint256'}],name:'observations',outputs:[{name:'blockTimestamp',type:'uint32'},{name:'tickCumulative',type:'int56'},{name:'secondsPerLiquidityCumulativeX128',type:'uint160'},{name:'initialized',type:'bool'}],stateMutability:'view',type:'function'},
 {inputs:[{type:'uint32[]'}],name:'observe',outputs:[{type:'int56[]'},{type:'uint160[]'}],stateMutability:'view',type:'function'},
];
const ZERO='0x0000000000000000000000000000000000000000';
const block = await client.getBlock();
const now = Number(block.timestamp);
console.log(`block ${block.number} @ ts ${now}\n`);
async function scan(name, a, b){
  console.log(`### ${name}`);
  for (const fee of [100,500,3000,10000]){
    const pool = await client.readContract({address:FACTORY,abi:facAbi,functionName:'getPool',args:[a,b,fee]});
    if (pool===ZERO){ console.log(`  fee ${String(fee).padStart(5)}: (no pool)`); continue; }
    const [s0, liq] = await Promise.all([
      client.readContract({address:pool,abi:poolAbi,functionName:'slot0'}),
      client.readContract({address:pool,abi:poolAbi,functionName:'liquidity'}),
    ]);
    const card=Number(s0[3]), idx=Number(s0[2]);
    const oldestIdx=(idx+1)%card;
    const newest = await client.readContract({address:pool,abi:poolAbi,functionName:'observations',args:[BigInt(idx)]});
    const oldest = await client.readContract({address:pool,abi:poolAbi,functionName:'observations',args:[BigInt(oldestIdx)]});
    const oldestTs = oldest[3]?Number(oldest[0]):null;
    const newestTs = Number(newest[0]);
    const span = oldestTs!==null ? newestTs-oldestTs : null;
    let obs1800='OK';
    try{ await client.readContract({address:pool,abi:poolAbi,functionName:'observe',args:[[0,1800]]});}catch(e){obs1800='REVERT "'+(e.cause?.reason||'?')+'"';}
    console.log(`  fee ${String(fee).padStart(5)}: pool=${pool}`);
    console.log(`           liquidity=${liq.toString()}  card=${card} next=${Number(s0[4])} idx=${idx}`);
    console.log(`           newestObsAge=${now-newestTs}s  oldestObsAge=${oldestTs!==null?now-oldestTs:'uninit'}s  bufferSpan=${span}s  observe([0,1800])=${obs1800}`);
  }
  console.log();
}
await scan('PAXG / WETH', PAXG, WETH);
await scan('PAXG / USDC', PAXG, USDC);

import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const VCO = '0x2f02415989C3e02061a8e451EF64Dc59e5c0051C';
const COLL = { WETH:'0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', WBTC:'0x2260fac5e5542a773aa44fbcfedf7c193bc2c599', PAXG:'0x45804880de22913dafe09f4980848ece6ecbaf78' };
const abi = [
 { inputs:[{name:'asset',type:'address'}], name:'getAssetCap', outputs:[{type:'uint256'}], stateMutability:'view', type:'function' },
 { inputs:[{name:'asset',type:'address'}], name:'getAssetCollateralized', outputs:[{type:'uint256'}], stateMutability:'view', type:'function' },
];
const f = x => Number(formatUnits(x,18)).toLocaleString('en-US',{maximumFractionDigits:6});
for (const [s,a] of Object.entries(COLL)) {
  let cap='?', col='?';
  try { cap = await client.readContract({address:VCO,abi,functionName:'getAssetCap',args:[a]}); } catch(e){ cap='REVERT:'+(e.cause?.reason||e.shortMessage); }
  try { col = await client.readContract({address:VCO,abi,functionName:'getAssetCollateralized',args:[a]}); } catch(e){ col='REVERT:'+(e.cause?.reason||e.shortMessage); }
  console.log(`${s.padEnd(5)} getAssetCap=${typeof cap==='bigint'?f(cap):cap}   getAssetCollateralized=${typeof col==='bigint'?f(col):col}`);
}

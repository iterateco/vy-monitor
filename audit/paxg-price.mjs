import { createPublicClient, http, formatUnits } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });
const VAO = '0x7a0E582479579e1423bc4f1DFD0750feA9282B01';
const COLL = { WETH:'0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', WBTC:'0x2260fac5e5542a773aa44fbcfedf7c193bc2c599', PAXG:'0x45804880de22913dafe09f4980848ece6ecbaf78' };
const abi = [{ inputs:[{name:'asset',type:'address'}], name:'getAssetTwapPrice', outputs:[{type:'uint256'}], stateMutability:'view', type:'function' }];
const f = x => Number(formatUnits(x,18)).toLocaleString('en-US',{maximumFractionDigits:6});
for (const [s,a] of Object.entries(COLL)) {
  try { const p = await client.readContract({address:VAO,abi,functionName:'getAssetTwapPrice',args:[a]}); console.log(`${s.padEnd(5)} getAssetTwapPrice = $${f(p)}`); }
  catch(e){ console.log(`${s.padEnd(5)} getAssetTwapPrice = REVERT "${e.cause?.reason||e.shortMessage?.split('\n').pop()?.trim()}"`); }
}

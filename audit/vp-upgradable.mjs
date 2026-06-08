import { createPublicClient, http } from 'viem';
import { mainnet } from 'viem/chains';
const client = createPublicClient({ chain: mainnet, transport: http('https://api.valinity.io/rpc-proxy') });

const VP = '0xF612C21161F400AbA27A0ef18b030350898b7628';

// EIP-1967 slots
const SLOT_IMPL    = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'; // impl
const SLOT_ADMIN   = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103'; // admin
const SLOT_BEACON  = '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50'; // beacon
// OZ legacy impl slot (older transparent proxies)
const SLOT_OZ_LEGACY = '0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3';

const zero = '0x0000000000000000000000000000000000000000000000000000000000000000';
const nz = v => v && v !== zero;

const [impl, admin, beacon, ozLegacy, code] = await Promise.all([
  client.getStorageAt({ address: VP, slot: SLOT_IMPL }),
  client.getStorageAt({ address: VP, slot: SLOT_ADMIN }),
  client.getStorageAt({ address: VP, slot: SLOT_BEACON }),
  client.getStorageAt({ address: VP, slot: SLOT_OZ_LEGACY }),
  client.getBytecode({ address: VP }),
]);

console.log('=== ValinityPortal upgradability check ===');
console.log(`Address: ${VP}`);
console.log(`Deployed bytecode size: ${code ? (code.length - 2) / 2 : 0} bytes`);
console.log('');
console.log('EIP-1967 / proxy storage slots:');
console.log(`  implementation slot : ${impl}   ${nz(impl) ? '*** SET (proxy!) ***' : '(empty)'}`);
console.log(`  admin slot          : ${admin}   ${nz(admin) ? '*** SET ***' : '(empty)'}`);
console.log(`  beacon slot         : ${beacon}   ${nz(beacon) ? '*** SET (beacon proxy!) ***' : '(empty)'}`);
console.log(`  OZ legacy impl slot : ${ozLegacy}   ${nz(ozLegacy) ? '*** SET ***' : '(empty)'}`);

// Is the deployed code a minimal proxy (EIP-1167)? pattern 363d3d373d3d3d363d73<impl>5af43d82803e903d91602b57fd5bf3
const isMinimalProxy = code && code.toLowerCase().includes('363d3d373d3d3d363d73');
console.log(`\nMinimal-proxy (EIP-1167) pattern present: ${isMinimalProxy ? 'YES' : 'no'}`);

// Selector presence in deployed code (function dispatch table)
const selectors = {
  'upgradeTo(address)':            '3659cfe6',
  'upgradeToAndCall(address,bytes)':'4f1ef286',
  'proxiableUUID()':               '52d1902d',
  'implementation()':              '5c60da1b',
  'admin()':                       'f851a440',
  'upgrade(address,address)':      '99a88ec4',
};
console.log('\nUpgrade-related selectors found in deployed bytecode:');
let any = false;
for (const [sig, sel] of Object.entries(selectors)) {
  const present = code && code.toLowerCase().includes(sel);
  if (present) any = true;
  console.log(`  ${present ? 'FOUND' : '  -  '}  ${sig}  (0x${sel})`);
}
if (!any) console.log('  (none — no upgrade entrypoints in the deployed code)');

console.log('\n=== Verdict ===');
if (nz(impl) || nz(beacon) || nz(ozLegacy) || isMinimalProxy) {
  console.log('UPGRADEABLE / PROXY — points at a separate implementation.');
} else if (any) {
  console.log('Has upgrade selectors but no 1967 slot — inspect further (could be UUPS uninitialized).');
} else {
  console.log('NON-UPGRADEABLE — logic lives directly at this address, no proxy slots, no upgrade entrypoints.');
}

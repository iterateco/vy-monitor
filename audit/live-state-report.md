# Live-State Report — Step B (on-chain, read-only, self-verified)

chainId 0x1 · block 25217820 · RPC eth-mainnet.g.alchemy.com · 18 contracts · read-only · each impl slot read twice & asserted stable.

| Contract | Proxy | Live impl | Bytecode vs artifact | Manifest | admin∈DEFAULT_ADMIN | paused |
|---|---|---|---|---|:--:|:--:|
| VDAX | `0xD985C0EA5394f9A1acece695885cbD5210d5A1f9` | `0xb6860e90a4da49cd368e45c9a93fedb71eff4aed` | EQUIVALENT-IMMUTABLES(40b) | tracked(505e7106c4,2v) | yes | — |
| ValinityAcquisitionOfficer | `0x7a0E582479579e1423bc4f1DFD0750feA9282B01` | `0xc364f74e0c644dc7ed16b8214d2b613f7725304a` | EQUIVALENT-IMMUTABLES(40b) | tracked(8da543fec0,30v) | yes | — |
| ValinityBuybackOfficer 🔴UNTRACKED | `0x4B97D45d276084c1C5BDBd0aa29B417cE02bE2F6` | `0xf311e729de3796a14c6b6d5875624f01d57c456a` | EQUIVALENT-IMMUTABLES(40b) | UNTRACKED | yes | — |
| ValinityCapOfficer 🔴MISMATCH | `0x2f02415989C3e02061a8e451EF64Dc59e5c0051C` | `0x294841f3763ac285130156d780cbf4b5949aec8b` | MISMATCH(live 10908b vs artifact 10510b) | tracked(2abb87742a,13v) | yes | — |
| ValinityDAX 🔴UNTRACKED 🔴MISMATCH | `0xD256C672616f7c5DEE3e42a8199f121EE08401B7` | `0x0c475be1a69420f305a20b2679e0e3f650867c82` | MISMATCH(live 11597b vs artifact 11410b) | UNTRACKED | yes | — |
| ValinityExchangeOfficer 🔴MISMATCH | `0x48C88B807B13593BAc4a5ea75EbD4fec83F827D7` | `0xd20b0c8be6de08a1235ed75ed814cc1fabbe64a5` | MISMATCH(live 15336b vs artifact 14295b) | tracked(591c23a1c2,24v) | yes | false |
| ValinityFloorOfficer | `0x3d9d78CDc1B67697eeFd84ED02efDeE15BA59D51` | —(non-proxy) | EQUIVALENT-IMMUTABLES(297b) | n/a(non-proxy) | yes | — |
| ValinityGasOfficer 🔴MISMATCH | `0x0a6C21174d039f5D85dA93FCB3FE7ad5F5f5E827` | `0xe7371f5f175b282ffef630596996b6bad2e37677` | MISMATCH(live 8731b vs artifact 8348b) | tracked(39d8bbea42,22v) | yes | — |
| ValinityLiquidityManager 🔴UNTRACKED | `0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0` | `0xcb147742077f512765a7cd1d14c1abe6684323d9` | EQUIVALENT-IMMUTABLES(80b) | UNTRACKED | yes | false |
| ValinityLoanOfficer | `0x8Fd8d5eB23f520D9BF8863364Ed44dbb29769DE4` | `0xfd7f6cb18a386f21e63c134625cc9b2b09764ef2` | EQUIVALENT-IMMUTABLES(40b) | tracked(78064622f2,15v) | yes | — |
| ValinityMEVBotV2 🔴UNTRACKED | `0x6f2F45804E58e3240A2fDE9857c0e4F754CC4941` | `0x16b66a22c79dabeab3d0926937722757544a7589` | EQUIVALENT-IMMUTABLES(40b) | UNTRACKED | yes | — |
| ValinityPortal | `0xF612C21161F400AbA27A0ef18b030350898b7628` | —(non-proxy) | EQUIVALENT-IMMUTABLES(57b) | n/a(non-proxy) | yes | — |
| ValinityReserveTreasury 🔴UNTRACKED | `0x06087789B7122fA92E7F9868B10A286Dd4e4C832` | `0x5a2ce62e46df64c2caabd952b67bf0294e87a1f6` | EQUIVALENT-IMMUTABLES(40b) | UNTRACKED | yes | — |
| ValinityReserveYieldOfficer 🔴UNTRACKED | `0xA95749f52031dA2c4baB7cf38323B69A9E3415d3` | `0x89f256f0035dea79584cbbdec4036dfd5e1fa2b3` | EQUIVALENT-IMMUTABLES(40b) | UNTRACKED | yes | false |
| ValinityStakingRouter 🔴MISMATCH | `0x664b3A81C963F07C1eb06516c560f9b2193698C7` | `0xe00db9e62c16c89f81b7b31d48cf658f30a571d4` | MISMATCH(live 24076b vs artifact 14745b) | tracked(cd24bf11e5,32v) | yes | — |
| ValinityToken | `0x597b29520098d6aaca3B2e0D1a380315c9240454` | —(non-proxy) | EXACT | n/a(non-proxy) | yes | — |
| ValinityYieldOfficer 🔴UNTRACKED 🔴MISMATCH | `0xA245C9D2D375A317DbA3d18bC74BF5921E7892C9` | `0x3cfd40d0e42b8620babed3e99d197741d007ac44` | MISMATCH(live 19733b vs artifact 10967b) | UNTRACKED | yes | — |
| ValinityYieldTreasury | `0xe58E29c947013B4CBCdb67f90d659c3894BE2974` | `0x35a86beb300f2a1ac08a339c50ee46b614cc447d` | EQUIVALENT-IMMUTABLES(40b) | tracked(d98392c2ed,10v) | yes | — |

## Shared implementations (one impl behind multiple proxies)
_none_

## Key
- **EXACT / EQUIVALENT-IMMUTABLES(0b)**: live runtime bytecode (metadata-stripped) == artifact deployedBytecode → the as-deployed `solcInputs` source IS the live code (certified). N>0 = identical except N immutable bytes.
- **MISMATCH**: live impl differs from artifact deployedBytecode → artifact is stale; audit the live impl from Etherscan-verified source. (Impl may still be manifest-tracked — that's fine, it just means a newer upgrade than the recorded artifact.)
- **UNTRACKED**: live impl not in the OZ manifest's impl set → upgrade outside the OZ plugin (storage-layout safety untracked). Investigate.
- admin = 0x8310eA7EC55A7Ad6A4288aF683155A124A524a09 (eth_mainnet Admin.json); does it hold DEFAULT_ADMIN_ROLE.

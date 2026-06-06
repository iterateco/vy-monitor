# Contract Registry — ETH mainnet (authoritative)

> **Source of truth = deploy artifacts (`deployments/eth_mainnet/*.json` `.address`) + OZ manifest (`.openzeppelin/mainnet.json`).**
> ⚠️ `Admin.json` is STALE/WRONG — do not use it (see `findings/system-reconciliation.md`).
> `Live impl` columns are filled by Step B (Alchemy). Until then, "audit source" = as-deployed source recovered from `solcInputs/`.

System shape: **18 UUPS proxies, 42 implementation entries** (per OZ manifest).

## In-scope contracts (real addresses)

| Contract | Proxy address | Type | Reconcile | Audit source | Priority |
|----------|---------------|------|-----------|--------------|----------|
| ValinityToken (VY) | `0x597b29520098d6aaca3B2e0D1a380315c9240454` | standalone | 🟢 EXACT | workspace | **P0** |
| ValinityYieldTreasury (VYT) | `0xe58E29c947013B4CBCdb67f90d659c3894BE2974` | UUPS | 🟢 EXACT | workspace | **P0** |
| ValinityReserveTreasury (VRT) | `0x06087789B7122fA92E7F9868B10A286Dd4e4C832` | UUPS | 🟡 COSMETIC | workspace | **P0** |
| ValinityCapOfficer (VCO) | `0x2f02415989C3e02061a8e451EF64Dc59e5c0051C` | UUPS | 🔴 DRIFT (main) | as-deployed | **P0** |
| ValinityAcquisitionOfficer (VAO) | `0x7a0E582479579e1423bc4f1DFD0750feA9282B01` | UUPS | 🔴 DRIFT | as-deployed | **P0** |
| ValinityLoanOfficer (VLO) | `0x8Fd8d5eB23f520D9BF8863364Ed44dbb29769DE4` | UUPS | 🔴 DRIFT | as-deployed | **P0** |
| ValinityBuybackOfficer (VBBO) | `0x4B97D45d276084c1C5BDBd0aa29B417cE02bE2F6` | standalone | ⚠️ NO-SRC | impl/Etherscan | **P0** |
| ValinityLiquidityManager (VLM) | `0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0` | UUPS | 🔴 DRIFT (main; V4 staged) | as-deployed | **P0** |
| ValinityYieldOfficer (VYO) | `0xA245C9D2D375A317DbA3d18bC74BF5921E7892C9` | UUPS | 🔴 DRIFT (main; V5 staged) | as-deployed | P1 |
| ValinityReserveYieldOfficer | `0xA95749f52031dA2c4baB7cf38323B69A9E3415d3` | UUPS | 🔴 DRIFT | as-deployed | P1 |
| ValinityDAX | `0xD256C672616f7c5DEE3e42a8199f121EE08401B7` | UUPS | 🔴 DRIFT | as-deployed | P1 |
| VDAX | `0xD985C0EA5394f9A1acece695885cbD5210d5A1f9` | UUPS | 🟢 EXACT | workspace | P1 |
| ValinityExchangeOfficer | `0x48C88B807B13593BAc4a5ea75EbD4fec83F827D7` | UUPS | 🔴 DRIFT (main) | as-deployed | P1 |
| ValinityStakingRouter | `0x664b3A81C963F07C1eb06516c560f9b2193698C7` | UUPS | 🔴 DRIFT (main) | as-deployed | P1 |
| ValinityMEVBotV2 | `0x6f2F45804E58e3240A2fDE9857c0e4F754CC4941` | standalone | ⚠️ NO-SRC | impl/Etherscan | P1 |
| ValinityGasOfficer | `0x0a6C21174d039f5D85dA93FCB3FE7ad5F5f5E827` | UUPS | 🟢 EXACT | workspace | P2 |
| ValinityFloorOfficer | `0x3d9d78CDc1B67697eeFd84ED02efDeE15BA59D51` | standalone | 🔴 DRIFT | as-deployed | P2 |
| ValinityPortal | `0xF612C21161F400AbA27A0ef18b030350898b7628` | standalone | 🟢 EXACT | workspace | P2 |

## Not-yet-deployed / staged successors (separate pre-deploy review)
- ValinityLiquidityManager **V4** (`deployments/ValinityLiquidityManager_V4.json`)
- ValinityYieldOfficer **V5** (`deployments/ValinityYieldOfficer_V5_ABI.json`)
- Workspace-only: ValinityVYLoanOfficer, ValinityGasOfficerV3, ValinityDCAOfficer, governance trio (Executor/Committee/Officer — confirm live addrs in Step B), alliance/VDAO, perps suite.

## To resolve in Step B (Alchemy)
- Live impl address for each of the 18 proxies; flag any impl not in the manifest's 42 (= upgrade outside OZ plugin).
- The true top authority (Admin/owner/`DEFAULT_ADMIN_ROLE`) — the real one, since `Admin.json` is wrong.
- Whether governance (Executor/Committee/Officer) is deployed on mainnet and at what addresses (no artifacts in eth_mainnet/ — may be sepolia/localhost only).

## External dependencies (mainnet)
| Name | Address | Notes |
|------|---------|-------|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 dec |
| WBTC | `0x2260fac5e5542a773aa44fbcfedf7c193bc2c599` | 8 dec |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 18 dec |
| PAXG | `0x45804880de22913dafe09f4980848ece6ecbaf78` | reserve asset |
| Uniswap V2 Router02 | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` | VY↔USDC |
| Uniswap V3 SwapRouter | `0xE592427A0AEce92De3Edee1F18E0157C05861564` | USDC↔asset |
| VY/USDC pool | `0xf96cCac0bfd5de8d1F69EA9F9f43ed3B174c2705` | **price-oracle source — manipulation surface** |

---

## Verified live implementations (Step B, block ~25,217,820)
Authoritative live-impl addresses + bytecode/manifest status are in [live-state-report.md](live-state-report.md). Summary:
- **Untracked-by-OZ-manifest live impls (investigate storage layout):** VRT, BuybackOfficer, VLM, ValinityDAX, YieldOfficer, ReserveYieldOfficer, MEVBotV2.
- **Artifact stale vs live (audit from Etherscan):** VCO, ValinityDAX, ExchangeOfficer, GasOfficer, StakingRouter, YieldOfficer.
- **Byte-EXACT (audit from workspace):** ValinityToken.
- **Admin `0x8310eA7EC55A7Ad6A4288aF683155A124A524a09` holds DEFAULT_ADMIN_ROLE on all 18.** Nothing paused.

# Source-truthful match gate (selector coverage: local source fns present in LIVE bytecode)

| Contract | Coverage | src fns | verdict | missing-from-live (sample) |
|---|--:|--:|---|---|
| ValinityFloorOfficer | 11% | 19 | SOURCE≠LIVE | execute() flashLoan(address,address[],uint256[],bytes) receiveFlashLoan(IERC20[],uint256[],uint256[],bytes) swapExactTokensForTokens(uint256,uint256,address[],address,uint256) getPool(address,address,uint24) exactInputSingle(ExactInputSingleParams) quoteExactInputSingle(QuoteExactInputSingleParams) initialize(address,address,address,address,address,address,address,address,address,address,address,address,address) executeFloor(uint256) setBuybackOfficer(address) setVryo(address) setBalancerVault(address) |
| ValinityGasOfficer | 24% | 17 | SOURCE≠LIVE | pullTokens(address,uint256) addToHighestLTVFCap(uint256) getPoolReserves(uint256) swapExactIn(uint256,address,uint256,uint256,address) initialize(address,address,address,address,address,uint256,uint256,uint256,uint256,uint256,address) topUp() getWallets() cooldownRemaining() previewVyNeeded() addWallet(address) removeWallet(address) setThresholds(uint256,uint256) |
| ValinityReserveYieldOfficer | 61% | 31 | PARTIAL-MISMATCH | exactInputSingle(ExactInputSingleParams) increaseLiquidity(IncreaseLiquidityParams) getAssetCap(address) effectiveFloor() increaseAssetCap(address,uint256) decreaseAssetCap(address,uint256) getLTV(address) assertTwapAligned(bytes32) snapbackHome() deployForYield(address[],uint256[],address) getPositionSnapshot(bytes32) decreasePositionLiquidity(bytes32,uint128,uint256,uint256,uint256) |
| ValinityStakingRouter | 64% | 47 | PARTIAL-MISMATCH | getTotalVYReserves() depositVYOnly(uint256,address) withdraw(uint256,address) swapExactIn(uint256,address,uint256,uint256,address) getPoolReserves(uint256) assetToPoolId(address) hasPool(address) execute() onDeposit(address,uint8,uint8,uint256,uint64,uint64) onAssetDeposit(address,uint256,address,uint256,uint8,uint64) onAssetWithdraw(address,uint256) deposit() |
| ValinityLiquidityManager | 68% | 31 | PARTIAL-MISMATCH | getPool(address,address,uint24) fee() tickSpacing() observe(uint32[]) positions(uint256) mint(MintParams) decreaseLiquidity(DecreaseLiquidityParams) collect(CollectParams) burn(uint256) exactInputSingle(ExactInputSingleParams) |
| ValinityReserveTreasury | 79% | 33 | PARTIAL-MISMATCH | decreaseLiquidity(DecreaseLiquidityParams) collect(CollectParams) positions(uint256) ownerOf(uint256) getPool(address,address,uint24) setPositionSnapshot(bytes32,PositionSnapshot) decreasePositionLiquidity(bytes32,uint128,uint256,uint256,uint256) |
| ValinityCapOfficer | 81% | 32 | PARTIAL-MISMATCH | getAssetTwapPrice(address) setAssetConfig(address,AssetConfig) addAsset(address,AssetConfig) migrateToCachedHighestLtvF() setCacheRefreshInterval(uint64) invalidateHighestLtvFCache() |
| ValinityExchangeOfficer | 85% | 26 | PARTIAL-MISMATCH | swapExactIn(uint256,address,uint256,uint256,address) assetToPoolId(address) exactInputSingle(ExactInputSingleParams) exactInput(ExactInputParams) |
| ValinityAcquisitionOfficer | 90% | 21 | PARTIAL-MISMATCH | assetToPoolId(address) execute() |
| ValinityToken | 92% | 13 | PARTIAL-MISMATCH | processTransactionFees(uint256) |
| ValinityLoanOfficer | 93% | 27 | PARTIAL-MISMATCH | execute() migrateLoans(MigrateLoanVars[]) |
| ValinityDAX | 95% | 19 | SOURCE-FNS-PRESENT | withdraw(uint256,address) |
| ValinityYieldTreasury | 100% | 5 | SOURCE-FNS-PRESENT | — |
| VDAX | 100% | 6 | SOURCE-FNS-PRESENT | — |
| ValinityPortal | 100% | 5 | SOURCE-FNS-PRESENT | — |

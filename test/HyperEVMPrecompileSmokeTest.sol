// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title HyperEVM Precompile Smoke Test
/// @notice Deploy this on HyperEVM TESTNET first to verify precompile ABIs and price scaling
///         before deploying the production Oracle contract.
/// @dev Run sequence:
///        1. Deploy this contract on testnet (chain id 998)
///        2. Call testHypePerpOracle() with HYPE perp asset index
///        3. Call testHypeSpotOracle() if spot oracle is desired
///        4. Verify returned prices match expected values from HL info endpoint
///        5. ONLY THEN deploy production Oracle with verified constants
contract HyperEVMPrecompileSmokeTest {
    address public constant PERP_ORACLE_PRECOMPILE = 0x0000000000000000000000000000000000000807;

    /// @notice Returned by precompile is raw uint256; needs scaling per szDecimals
    /// @dev To convert to USD: rawPrice / 10^(6 - szDecimals)
    /// @dev To convert to 1e18-scaled: rawPrice * 1e18 / 10^(6 - szDecimals)
    function testHypePerpOracle(uint256 hypeAssetIndex) external view returns (
        uint256 rawPrice,
        bool callSucceeded,
        bytes memory rawReturn
    ) {
        bytes memory input = abi.encode(hypeAssetIndex);
        (callSucceeded, rawReturn) = PERP_ORACLE_PRECOMPILE.staticcall(input);

        if (callSucceeded && rawReturn.length >= 32) {
            rawPrice = abi.decode(rawReturn, (uint256));
        }
    }

    /// @notice Helper: scale raw price to 1e18 precision USD
    function scalePrice(uint256 rawPrice, uint256 szDecimals) external pure returns (uint256) {
        // For perps: raw / 10^(6 - szDecimals), then * 1e18
        // E.g., szDecimals = 4 → divisor = 10^2 = 100
        require(szDecimals <= 6, "INVALID_SZ_DECIMALS");
        uint256 divisor = 10 ** (6 - szDecimals);
        return rawPrice * 1e18 / divisor;
    }

    /// @notice Try multiple precompile addresses to find spot oracle
    /// @dev L1Read.sol may not be publicly available; this iterates address space
    function probePrecompiles(uint256 startOffset, uint256 endOffset, bytes memory testInput)
        external
        view
        returns (bool[] memory successes, bytes[] memory returns)
    {
        require(endOffset > startOffset, "INVALID_RANGE");
        uint256 count = endOffset - startOffset;
        successes = new bool[](count);
        returns = new bytes[](count);

        for (uint256 i = 0; i < count; i++) {
            address target = address(uint160(0x800 + startOffset + i));
            (successes[i], returns[i]) = target.staticcall(testInput);
        }
    }

    /// @notice Verify gas cost matches docs (2000 + 65 * (input + output))
    function measureGasCost(uint256 hypeAssetIndex) external view returns (uint256 gasUsed) {
        bytes memory input = abi.encode(hypeAssetIndex);
        uint256 gasBefore = gasleft();
        (bool ok, ) = PERP_ORACLE_PRECOMPILE.staticcall(input);
        gasUsed = gasBefore - gasleft();
        require(ok, "CALL_FAILED");
    }
}

/// @notice Deployment instructions for the dev team:
///
/// 1. Deploy on HyperEVM testnet (chain ID 998):
///    forge create --rpc-url https://rpc.hyperliquid-testnet.xyz/evm \
///                 --private-key $PK \
///                 src/HyperEVMPrecompileSmokeTest.sol:HyperEVMPrecompileSmokeTest
///
/// 2. Find HYPE perp asset index from HL info endpoint:
///    curl -X POST https://api.hyperliquid-testnet.xyz/info \
///         -H "Content-Type: application/json" \
///         -d '{"type":"meta"}'
///    Look for {"name":"HYPE","szDecimals":N} in the universe array.
///    Asset index = position in array (0-based).
///
/// 3. Call testHypePerpOracle(<assetIndex>):
///    cast call <DEPLOYED_ADDRESS> "testHypePerpOracle(uint256)" <ASSET_INDEX> \
///         --rpc-url https://rpc.hyperliquid-testnet.xyz/evm
///
/// 4. Compare returned `rawPrice` after scaling to actual HYPE/USD price from
///    HL info endpoint or web UI. Should match within 1-second oracle update window.
///
/// 5. Verify scalePrice() output matches expected 1e18-scaled USD price.
///
/// 6. Run measureGasCost() and confirm < 5000 gas (matches docs formula).
///
/// 7. If all checks pass, deploy production Oracle with verified hypeAssetIndex
///    and szDecimals constants in constructor.
///
/// 8. If any check fails, debug before proceeding. Common issues:
///    - Wrong assetIndex (spot vs perp ordering differs)
///    - Wrong szDecimals (look up in meta endpoint)
///    - Precompile returns differently encoded data on testnet vs mainnet
///    - Network issue (try multiple RPC endpoints)

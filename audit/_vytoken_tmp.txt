// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IValinityCapOfficer {
    function processTransactionFees(uint256 amount) external;
}

contract ValinityToken is ERC20, AccessControl {
    // EIP712 Precomputed hashes:
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant EIP712DOMAINTYPE_HASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // keccak256("ValinityToken")
    bytes32 private constant NAME_HASH =
        0x57baa3182211fc13f780c2c3f3afbe6e6f926eb3b16ce6b934be325d1727b10b;

    // keccak256("1")
    bytes32 private constant VERSION_HASH =
        0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    // keccak256("VYPermit(address owner,address spender,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 private constant TXTYPE_HASH =
        0x6c8edce185a41fbe1c6e13cedd3b642e5ee37856a522be18798cb6f18c0e6422;

    // solhint-disable-next-line var-name-mixedcase
    bytes32 public DOMAIN_SEPARATOR;
    mapping(address => uint256) public nonces;

    uint256 public constant MAX_SUPPLY = 70_000_000 * 10 ** 18; // 70 million hard cap
    uint256 public constant INITIAL_SUPPLY = 17_000_000 * 10 ** 18; // 17 million initial mint
    uint16 public constant MAX_FEE_BPS = 1000; // 10% max fee

    // ═══════════════════════════════════════════════════════════════════════════
    // MINT RATE LIMITING — Hardcoded, based on remaining supply
    // ═══════════════════════════════════════════════════════════════════════════
    uint16 public constant MINT_BPS_PER_TX = 7;       // 0.07% of remaining supply per tx
    uint16 public constant MINT_BPS_PER_EPOCH = 30;    // 0.30% of remaining supply per epoch
    uint32 public constant EPOCH_DURATION = 24 hours;

    /// @notice The only address allowed to mint (ValinityYieldTreasury)
    address public vyt;
    /// @notice Once true, VYT address can never be changed
    bool public vytLocked;

    // Epoch state for rate limiting
    uint64 public currentEpochStart;
    uint192 public mintedThisEpoch;
    uint256 public epochSupplySnapshot;

    uint16 public transferFeeBps;
    address public transferFeeRecipient;

    // Fee batching for VCO cap accounting
    IValinityCapOfficer public capOfficer;
    uint256 public accumulatedFees;
    uint8 public transfersSinceLastProcess;
    uint8 public transfersPerProcess = 7;

    mapping(address => bool) public whitelistedAddresses;

    error FeeTooHigh();
    error InvalidAddress();
    error InvalidSignature();
    error PermitExpired();
    error InvalidTransfersPerProcess();
    error VYTAlreadyLocked();
    error OnlyVYT();

    event TransferFeeUpdated(uint16 newBps);
    event TransferFeeRecipientUpdated(address recipient);
    event WhitelistUpdated(address indexed who, bool whitelisted);
    event TransferFee(
        address indexed from,
        address indexed to,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 feeBps
    );
    event Minted(address indexed to, uint256 amount);
    event CapOfficerUpdated(address indexed capOfficer);
    event FeesProcessed(uint256 amount, uint8 transferCount);
    event TransfersPerProcessUpdated(uint8 newValue);
    event VYTSet(address indexed vyt);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /**
     * @dev Constructor that setup all the admin governance agent.
     * Initializes transfer fee to 1% and no minter or fee recipient.
     */
    constructor(
        string memory name,
        string memory symbol,
        address adminAddress
    ) ERC20(name, symbol) {
        if (adminAddress == address(0)) {
            revert InvalidAddress();
        }

        // Setup EIP712
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712DOMAINTYPE_HASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid,
                address(this)
            )
        );

        // Default transfer fee to 1% (100 basis points)
        transferFeeBps = 100; // 1%

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);

        // Mint initial supply to deployer for manual distribution
        _mint(adminAddress, INITIAL_SUPPLY);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VYT-ONLY MINTING — Rate-limited, non-reverting
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set the VYT address (one-time, locked forever after)
     * @param _vyt The ValinityYieldTreasury address
     */
    function setVYT(address _vyt) external onlyRole(ADMIN_ROLE) {
        if (vytLocked) revert VYTAlreadyLocked();
        if (_vyt == address(0)) revert InvalidAddress();
        vyt = _vyt;
        vytLocked = true;
        emit VYTSet(_vyt);
    }

    /**
     * @notice Mint VY tokens with rate limiting — only callable by VYT
     * @dev Non-reverting on rate limits: mints min(requested, maxAllowed).
     *      Rate limits are based on remaining supply (MAX_SUPPLY - totalSupply),
     *      so minting slows down as supply approaches the cap.
     * @param to Recipient of minted tokens
     * @param requested Amount of VY requested
     * @return minted Actual amount minted (may be less than requested)
     */
    function mintAvailable(address to, uint256 requested) external returns (uint256 minted) {
        if (msg.sender != vyt) revert OnlyVYT();
        if (requested == 0 || to == address(0)) return 0;

        uint256 supply = totalSupply();
        if (supply >= MAX_SUPPLY) return 0;

        uint256 remaining;
        unchecked { remaining = MAX_SUPPLY - supply; }

        // Cap to remaining supply
        if (requested > remaining) requested = remaining;

        // Per-transaction limit
        uint256 maxPerTx;
        unchecked { maxPerTx = (remaining * MINT_BPS_PER_TX) / 10_000; }
        if (requested > maxPerTx) requested = maxPerTx;

        // Epoch tracking
        uint64 epochStart = currentEpochStart;
        uint256 epochMinted = mintedThisEpoch;
        uint256 snapshot = epochSupplySnapshot;

        // Reset epoch if needed
        if (block.timestamp >= epochStart + EPOCH_DURATION) {
            epochStart = uint64(block.timestamp);
            epochMinted = 0;
            snapshot = remaining;
            currentEpochStart = epochStart;
            epochSupplySnapshot = snapshot;
        }

        // Per-epoch limit
        uint256 maxPerEpoch;
        unchecked { maxPerEpoch = (snapshot * MINT_BPS_PER_EPOCH) / 10_000; }
        uint256 epochRemaining;
        unchecked { epochRemaining = maxPerEpoch > epochMinted ? maxPerEpoch - epochMinted : 0; }
        if (requested > epochRemaining) requested = epochRemaining;

        // Nothing to mint after all caps applied
        if (requested == 0) return 0;

        // Update epoch state and mint
        unchecked { mintedThisEpoch = uint192(epochMinted + requested); }
        _mint(to, requested);
        minted = requested;

        emit Minted(to, minted);
    }

    /**
     * @notice Get remaining mint allowance for current epoch
     * @return remainingPerTx Maximum mint allowed in a single transaction
     * @return remainingInEpoch Remaining mint allowance in current epoch
     * @return epochEndsAt Timestamp when current epoch ends
     */
    function getRemainingMintAllowance() external view returns (
        uint256 remainingPerTx,
        uint256 remainingInEpoch,
        uint256 epochEndsAt
    ) {
        uint256 supply = totalSupply();
        if (supply >= MAX_SUPPLY) return (0, 0, 0);

        uint256 remaining;
        unchecked { remaining = MAX_SUPPLY - supply; }

        unchecked { remainingPerTx = (remaining * MINT_BPS_PER_TX) / 10_000; }

        uint256 epochEnd = currentEpochStart + EPOCH_DURATION;
        bool newEpoch = block.timestamp >= epochEnd;

        if (newEpoch) {
            unchecked { remainingInEpoch = (remaining * MINT_BPS_PER_EPOCH) / 10_000; }
            epochEndsAt = block.timestamp + EPOCH_DURATION;
        } else {
            uint256 maxPerEpoch;
            unchecked { maxPerEpoch = (epochSupplySnapshot * MINT_BPS_PER_EPOCH) / 10_000; }
            unchecked { remainingInEpoch = maxPerEpoch > mintedThisEpoch ? maxPerEpoch - mintedThisEpoch : 0; }
            epochEndsAt = epochEnd;
        }
    }

    function isWhitelisted(address who) public view returns (bool) {
        return whitelistedAddresses[who];
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transferWithFee(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _spendAllowance(sender, _msgSender(), amount);
        _transferWithFee(sender, recipient, amount);
        return true;
    }

    function _transferWithFee(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        address feeRecipient = transferFeeRecipient;
        uint256 fee = _calculateTransferFee(sender, recipient, amount, feeRecipient);

        if (fee != 0) {
            uint256 netAmount = amount - fee;
            _transfer(sender, recipient, netAmount);
            _collectFee(sender, fee, feeRecipient);
            emit TransferFee(
                sender,
                feeRecipient,
                amount,
                netAmount,
                fee,
                transferFeeBps
            );
        } else {
            _transfer(sender, recipient, amount);
        }
    }

    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) {
            revert PermitExpired();
        }

        // EIP712 scheme: https://github.com/ethereum/EIPs/blob/master/EIPS/eip-712.md
        bytes32 txInputHash = keccak256(
            abi.encode(TXTYPE_HASH, owner, spender, amount, nonces[owner], deadline)
        );
        bytes32 totalHash = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, txInputHash)
        );

        address recoveredAddress = ECDSA.recover(totalHash, v, r, s);
        if (recoveredAddress != owner) {
            revert InvalidSignature();
        }

        ++nonces[owner];
        _approve(owner, spender, amount);
    }

    function setCapOfficer(address _capOfficer) external onlyRole(ADMIN_ROLE) {
        capOfficer = IValinityCapOfficer(_capOfficer);
        emit CapOfficerUpdated(_capOfficer);
    }

    function setTransferFeeBps(uint16 newBps) external onlyRole(ADMIN_ROLE) {
        if (newBps == transferFeeBps) return;
        if (newBps > MAX_FEE_BPS) {
            revert FeeTooHigh();
        }
        transferFeeBps = newBps;
        emit TransferFeeUpdated(newBps);
    }

    function setTransfersPerProcess(uint8 count) external onlyRole(ADMIN_ROLE) {
        if (count == 0) revert InvalidTransfersPerProcess();
        if (count == transfersPerProcess) return;
        transfersPerProcess = count;
        emit TransfersPerProcessUpdated(count);
    }

    function setTransferFeeRecipient(
        address recipient
    ) external onlyRole(ADMIN_ROLE) {
        if (recipient == transferFeeRecipient) return;
        transferFeeRecipient = recipient;
        emit TransferFeeRecipientUpdated(recipient);
    }

    function setWhitelisted(
        address who,
        bool exempt
    ) external onlyRole(ADMIN_ROLE) {
        if (who == address(0)) revert InvalidAddress();
        if (whitelistedAddresses[who] == exempt) return;
        whitelistedAddresses[who] = exempt;
        emit WhitelistUpdated(who, exempt);
    }

    function _calculateTransferFee(
        address from,
        address to,
        uint256 amount,
        address feeRecipient
    ) private view returns (uint256) {
        if (whitelistedAddresses[from] || whitelistedAddresses[to]) return 0;
        if (feeRecipient == address(0)) return 0;
        return (amount * transferFeeBps) / 10000;
    }

    function _collectFee(address sender, uint256 fee, address feeRecipient) private {
        _transfer(sender, feeRecipient, fee);

        accumulatedFees += fee;
        unchecked {
            ++transfersSinceLastProcess;
        }

        if (transfersSinceLastProcess >= transfersPerProcess) {
            _processAccumulatedFees();
        }
    }

    function _processAccumulatedFees() private {
        if (address(capOfficer) == address(0)) return;
        if (accumulatedFees == 0) return;

        uint256 feesToProcess = accumulatedFees;
        uint8 transferCount = transfersSinceLastProcess;

        accumulatedFees = 0;
        transfersSinceLastProcess = 0;

        capOfficer.processTransactionFees(feesToProcess);

        emit FeesProcessed(feesToProcess, transferCount);
    }
}

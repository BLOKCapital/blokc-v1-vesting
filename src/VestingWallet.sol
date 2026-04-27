// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*###############################################################################

    @title Vesting Wallet (clone-safe)
    @author BLOK Capital DAO
    @notice Clone-safe VestingWallet + VestingWalletCliff with DAO-gated revoke
            (ERC20 + ETH), pausable releases, DAO-only ownership rescue, and
            beneficiary-gated governance delegation. Designed to be deployed as
            an EIP-1167 minimal proxy via {VestingWalletFactory}.

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import {VestingWalletUpgradeable} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletUpgradeable.sol";
import {VestingWalletCliffUpgradeable} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletCliffUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title IVestingWalletFactory
/// @notice Minimal interface used by {VestingWalletBlokc} to read the active DAO
///         address live from the factory. A single source of truth avoids stale
///         DAO references across dozens of deployed wallets when keys are rotated.
interface IVestingWalletFactory {
    /// @notice Returns the current DAO address as known to the factory.
    /// @return The DAO address.
    function dao() external view returns (address);
}

/// @title VestingWalletBlokc
/// @author BLOK Capital DAO
/// @notice Clone-safe cliff-plus-linear vesting wallet with DAO oversight. Built on
///         top of {VestingWalletUpgradeable} + {VestingWalletCliffUpgradeable}.
///         Meant to be deployed once as an implementation contract and cloned per
///         beneficiary via EIP-1167 by {VestingWalletFactory}. Per-wallet state
///         (factory, revokeAllowed, revoked flags, pause state, ownership) lives
///         in the clone's storage; only logic is shared with the implementation.
///
/// @dev Post-revoke semantics: once `revoke` has been called for an asset, the
///      remaining balance in the wallet is treated as fully vested and becomes
///      immediately releasable. This differs from the OZ base, which would rebase
///      the vesting curve over the reduced pool and force the beneficiary to wait
///      out the full duration. The chosen semantic matches user intuition: "revoke
///      stops vesting — what you earned so far is yours to claim now."
///
/// @custom:security-contact security@blokcapital.io
contract VestingWalletBlokc is
    VestingWalletCliffUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Namespaced storage (ERC-7201)
    // ─────────────────────────────────────────────────────────────────────────

    /// @custom:storage-location erc7201:blokcapital.storage.VestingWalletBlokc
    struct BlokcStorage {
        IVestingWalletFactory factory;
        bool revokeAllowed;
        bool ethRevoked;
        mapping(address token => bool) revoked;
    }

    // keccak256(abi.encode(uint256(keccak256("blokcapital.storage.VestingWalletBlokc")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BlokcStorageLocation =
        0x7462af9568179619757c9bd0d7b3cfa71d161118442c47e67268dff80c5c1400;

    function _blokcStorage() private pure returns (BlokcStorage storage bs) {
        assembly {
            bs.slot := BlokcStorageLocation
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Caller is not the current DAO.
    error NotDAO();

    /// @notice Caller is not the current beneficiary (owner of the wallet).
    error NotBeneficiary();

    /// @notice Revoke was attempted on a wallet where `revokeAllowed == false`.
    error RevokeNotAllowed();

    /// @notice Revoke was attempted on an asset that has already been revoked.
    error AlreadyRevoked();

    /// @notice A zero address was supplied where a non-zero address is required.
    error ZeroAddress();

    /// @notice `renounceOwnership` is permanently disabled to prevent the vested
    /// funds from being orphaned with no reachable owner.
    error RenounceDisabled();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when the DAO sweeps unvested ERC20 to itself.
    event VestingRevoked(address indexed token, address indexed dao, uint256 unvestedAmount, bytes32 proposalRef);

    /// @notice Emitted when the DAO sweeps unvested ETH to itself.
    event EthVestingRevoked(address indexed dao, uint256 unvestedAmount, bytes32 proposalRef);

    /// @notice Emitted when the beneficiary delegates governance voting power.
    event Delegated(address indexed token, address indexed delegatee);

    /// @notice Emitted when the DAO pauses releases.
    event EmergencyPaused(address indexed dao);

    /// @notice Emitted when the DAO lifts the pause.
    event EmergencyUnpaused(address indexed dao);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Restricts the call to the current DAO address read from the factory.
    modifier onlyDAO() {
        if (msg.sender != _blokcStorage().factory.dao()) revert NotDAO();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Construction / Initialization
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Locks the implementation so it cannot be initialized directly.
    /// @dev Only the clones deployed by the factory are initialized. The
    ///      implementation itself must remain uninitialized to prevent any
    ///      accidental or malicious takeover of its storage slots.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a freshly deployed clone with its vesting schedule.
    /// @param factory_ The factory that deployed the clone; provides the live DAO address.
    /// @param beneficiary_ Initial owner / beneficiary who can call {release}.
    /// @param startTimestamp Vesting start (unix seconds).
    /// @param durationSeconds Total vesting duration in seconds from `startTimestamp`.
    /// @param cliffDuration Cliff duration in seconds measured from `startTimestamp`.
    /// @param revokeAllowed_ Whether the DAO may revoke unvested assets from this wallet.
    /// @dev {VestingWalletCliffUpgradeable} enforces `cliffDuration <= durationSeconds`.
    function initialize(
        address factory_,
        address beneficiary_,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffDuration,
        bool revokeAllowed_
    ) external initializer {
        if (factory_ == address(0)) revert ZeroAddress();

        __VestingWallet_init(beneficiary_, startTimestamp, durationSeconds);
        __VestingWalletCliff_init(cliffDuration);
        __Pausable_init();

        BlokcStorage storage bs = _blokcStorage();
        bs.factory = IVestingWalletFactory(factory_);
        bs.revokeAllowed = revokeAllowed_;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The factory that deployed this wallet.
    function factory() external view returns (address) {
        return address(_blokcStorage().factory);
    }

    /// @notice Whether the DAO is permitted to revoke unvested assets.
    function revokeAllowed() external view returns (bool) {
        return _blokcStorage().revokeAllowed;
    }

    /// @notice Whether the native ETH balance has already been revoked.
    function ethRevoked() external view returns (bool) {
        return _blokcStorage().ethRevoked;
    }

    /// @notice Whether `token`'s unvested portion has already been revoked.
    function revoked(address token) external view returns (bool) {
        return _blokcStorage().revoked[token];
    }

    /// @notice Returns the current DAO address as seen by this wallet.
    function dao() external view returns (address) {
        return _blokcStorage().factory.dao();
    }

    /// @notice Returns the current beneficiary of this wallet.
    function beneficiary() public view returns (address) {
        return owner();
    }

    /// @notice Computes the amount of ETH vested at `timestamp`.
    /// @dev Post-revoke: remaining balance is treated as fully vested.
    function vestedAmount(uint64 timestamp) public view virtual override returns (uint256) {
        if (_blokcStorage().ethRevoked) return address(this).balance + released();
        return super.vestedAmount(timestamp);
    }

    /// @notice Computes the amount of `token` vested at `timestamp`.
    /// @dev Post-revoke: remaining balance is treated as fully vested.
    function vestedAmount(address token, uint64 timestamp) public view virtual override returns (uint256) {
        if (_blokcStorage().revoked[token]) return IERC20(token).balanceOf(address(this)) + released(token);
        return super.vestedAmount(token, timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Releases pause-gated
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Release the ETH that has already vested. Pause-gated.
    function release() public virtual override whenNotPaused {
        super.release();
    }

    /// @notice Release the `token` amount that has already vested. Pause-gated.
    function release(address token) public virtual override whenNotPaused {
        super.release(token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Governance delegation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Delegates the voting power of an {IVotes} token held by this wallet.
    /// @dev Beneficiary-only.
    function delegate(address token, address delegatee) external {
        if (msg.sender != owner()) revert NotBeneficiary();
        if (token == address(0) || delegatee == address(0)) revert ZeroAddress();
        IVotes(token).delegate(delegatee);
        emit Delegated(token, delegatee);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Revoke (ERC20 + ETH)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sweep the unvested portion of `token` back to the DAO.
    function revoke(address token, bytes32 proposalRef) external onlyDAO nonReentrant {
        BlokcStorage storage bs = _blokcStorage();
        if (!bs.revokeAllowed) revert RevokeNotAllowed();
        if (bs.revoked[token]) revert AlreadyRevoked();

        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 claimable = releasable(token);
        uint256 unvestedAmount = bal - claimable;

        bs.revoked[token] = true;

        address daoAddr = bs.factory.dao();
        if (unvestedAmount > 0) {
            IERC20(token).safeTransfer(daoAddr, unvestedAmount);
        }
        emit VestingRevoked(token, daoAddr, unvestedAmount, proposalRef);
    }

    /// @notice Sweep the unvested portion of the wallet's ETH balance to the DAO.
    function revokeEth(bytes32 proposalRef) external onlyDAO nonReentrant {
        BlokcStorage storage bs = _blokcStorage();
        if (!bs.revokeAllowed) revert RevokeNotAllowed();
        if (bs.ethRevoked) revert AlreadyRevoked();

        uint256 bal = address(this).balance;
        uint256 claimable = releasable();
        uint256 unvestedAmount = bal - claimable;

        bs.ethRevoked = true;

        address daoAddr = bs.factory.dao();
        if (unvestedAmount > 0) {
            Address.sendValue(payable(daoAddr), unvestedAmount);
        }
        emit EthVestingRevoked(daoAddr, unvestedAmount, proposalRef);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Emergency pause
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Halt {release} calls. DAO-only.
    function pause() external onlyDAO {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    /// @notice Lift the pause. DAO-only.
    function unpause() external onlyDAO {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ownership overrides
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Transfer wallet ownership (beneficiary) to a new address. DAO-only.
    function transferOwnership(address newOwner) public override onlyDAO {
        if (newOwner == address(0)) revert ZeroAddress();
        _transferOwnership(newOwner);
    }

    /// @notice Disabled. Always reverts with {RenounceDisabled}.
    /// @dev Renouncing would set the owner to the zero address and make every
    ///future {release} call transfer to the zero address — effectively
    ///burning the vested funds. Disallowed by design.
    function renounceOwnership() public view override onlyDAO {
        revert RenounceDisabled();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    function _checkDAO() internal view {
        BlokcStorage storage bs = _blokcStorage();
        if (msg.sender != bs.factory.dao()) revert NotDAO();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*###############################################################################

    @title Vesting Wallet Factory (EIP-1167)
    @author BLOK Capital DAO
    @notice Deploys {VestingWalletBlokc} instances as EIP-1167 minimal proxy clones
            of a single shared implementation. DAO-gated creation, 2-step DAO
            rotation, registry with pagination, and deterministic (CREATE2)
            clone support for pre-funded wallets.

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {VestingWalletBlokc} from "../VestingWallet.sol";

/// @title VestingWalletFactory
/// @author BLOK Capital DAO
/// @notice Factory + registry for {VestingWalletBlokc} clones. Each call to
///         {createVestingWallet} deploys a 45-byte EIP-1167 proxy pointing at
///         {implementation} and atomically initializes it — no constructor is
///         executed per clone, dramatically reducing deployment gas.
///
/// @dev Responsibilities:
///      - Gate clone creation to the DAO (prevents registry pollution).
///      - Serve as the single source of truth for the active DAO address (every
///        clone reads `factory.dao()` live).
///      - Provide a 2-step DAO handover.
///      - Maintain `allVestings` and per-user lists for discovery.
///      - Optionally deploy clones at deterministic CREATE2 addresses, letting
///        the DAO pre-fund a wallet before it is actually deployed.
contract VestingWalletFactory {
    using Clones for address;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The {VestingWalletBlokc} implementation every clone delegates to.
    /// @dev Immutable; supplied at construction. To migrate to a new implementation
    ///      deploy a new factory rather than mutating this pointer — existing clones
    ///      must remain pinned to their original logic for beneficiary safety.
    address public immutable implementation;

    /// @notice Active DAO address; single source of truth for all deployed wallets.
    address public dao;

    /// @notice Candidate DAO address awaiting acceptance (2-step rotation).
    address public pendingDao;

    /// @notice Append-only list of every wallet the factory has deployed.
    address[] private _allVestings;

    /// @notice Per-beneficiary list of wallets, keyed by the beneficiary address
    ///         at creation time; stale if a wallet later calls {transferOwnership}.
    mapping(address => address[]) private _userVestings;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Caller is not the current DAO.
    error NotDAO();

    /// @notice Caller is not the pending DAO; cannot accept a transfer.
    error NotPendingDAO();

    /// @notice A zero address was supplied where a non-zero address is required.
    error ZeroAddress();

    /// @notice Vesting duration cannot be zero.
    error ZeroDuration();

    /// @notice Vesting start timestamp cannot be zero.
    error ZeroStart();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when the current DAO initiates a rotation.
    event DAOTransferStarted(address indexed currentDao, address indexed pendingDao);

    /// @notice Emitted when a DAO rotation completes.
    event DAOTransferred(address indexed oldDao, address indexed newDao);

    /// @notice Emitted when a pending DAO transfer is cancelled before acceptance.
    event DAOTransferCancelled(address indexed currentDao, address indexed cancelledPendingDao);

    /// @notice Emitted when a new vesting wallet clone is created.
    /// @param wallet Address of the newly deployed clone.
    /// @param beneficiary The initial beneficiary (owner) of the wallet.
    /// @param start Vesting start timestamp (unix seconds).
    /// @param duration Total vesting duration in seconds.
    /// @param cliffDuration Cliff duration in seconds, measured from `start`.
    /// @param revokeAllowed Whether the DAO may revoke unvested assets.
    /// @param salt Salt used for CREATE2 deployment; `bytes32(0)` for non-deterministic.
    event VestingWalletCreated(
        address indexed wallet,
        address indexed beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliffDuration,
        bool revokeAllowed,
        bytes32 salt
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Restricts the call to the current DAO address.
    modifier onlyDAO() {
        _checkDAO();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Construction
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Initialize the factory with an implementation and a DAO address.
    /// @param implementation_ Address of the deployed {VestingWalletBlokc} logic
    ///        contract. Must be non-zero and must have its initializers disabled
    ///        (the {VestingWalletBlokc} constructor does this).
    /// @param dao_ Initial DAO address. Must be non-zero. Rotate via the 2-step flow.
    constructor(address implementation_, address dao_) {
        if (implementation_ == address(0) || dao_ == address(0)) revert ZeroAddress();
        implementation = implementation_;
        dao = dao_;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DAO rotation (2-step)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Start a 2-step DAO rotation.
    function beginDAOTransfer(address newDAO) external onlyDAO {
        if (newDAO == address(0)) revert ZeroAddress();
        pendingDao = newDAO;
        emit DAOTransferStarted(dao, newDAO);
    }

    /// @notice Finalize DAO rotation. Called by the pending DAO.
    function acceptDAOTransfer() external {
        if (msg.sender != pendingDao) revert NotPendingDAO();
        address old = dao;
        dao = pendingDao;
        pendingDao = address(0);
        emit DAOTransferred(old, dao);
    }

    /// @notice Cancel a pending DAO transfer before acceptance.
    function cancelDAOTransfer() external onlyDAO {
        address cancelled = pendingDao;
        pendingDao = address(0);
        emit DAOTransferCancelled(dao, cancelled);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Wallet creation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploy a new vesting wallet clone at a non-deterministic address.
    /// @dev Uses {Clones.clone} (CREATE). Cheapest path; address depends on nonce.
    /// @param beneficiary Initial wallet owner. Must be non-zero.
    /// @param start Vesting start timestamp (unix seconds).
    /// @param duration Total vesting duration in seconds. Must be > 0.
    /// @param cliffDuration Cliff duration in seconds, measured from `start`.
    /// @param revokeAllowed Whether the DAO may revoke unvested assets.
    /// @return wallet The address of the newly deployed clone.
    function createVestingWallet(
        address beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliffDuration,
        bool revokeAllowed
    ) external onlyDAO returns (address wallet) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (duration == 0) revert ZeroDuration();

        wallet = implementation.clone();
        _initializeAndRegister(wallet, beneficiary, start, duration, cliffDuration, revokeAllowed, bytes32(0));
    }

    /// @notice Predict the address a {createVestingWalletDeterministic} call with
    ///         `salt` would produce. Useful for pre-funding before deployment.
    /// @param salt CREATE2 salt.
    /// @return The predicted clone address.
    function predictDeterministicAddress(bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, salt, address(this));
    }

    /// @dev Shared post-deploy hook: initialize the clone, update registries, emit.
    function _initializeAndRegister(
        address wallet,
        address beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliffDuration,
        bool revokeAllowed,
        bytes32 salt
    ) private {
        VestingWalletBlokc(payable(wallet)).initialize(
            address(this), beneficiary, start, duration, cliffDuration, revokeAllowed
        );
        _userVestings[beneficiary].push(wallet);
        _allVestings.push(wallet);

        emit VestingWalletCreated(wallet, beneficiary, start, duration, cliffDuration, revokeAllowed, salt);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Number of wallets ever deployed by this factory.
    function allVestingsLength() external view returns (uint256) {
        return _allVestings.length;
    }

    /// @notice Number of wallets registered for a given user (by original beneficiary).
    function userVestingsLength(address user) external view returns (uint256) {
        return _userVestings[user].length;
    }

    /// @notice Full registry. Prefer {getAllVestingsPaged} on-chain.
    function getAllVestings() external view returns (address[] memory) {
        return _allVestings;
    }

    /// @notice All wallets assigned to `user` at creation time.
    function getUserVestings(address user) external view returns (address[] memory) {
        return _userVestings[user];
    }

    /// @notice Paginated registry slice.
    function getAllVestingsPaged(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        return _slice(_allVestings, offset, limit);
    }

    /// @notice Paginated per-user registry slice.
    function getUserVestingsPaged(address user, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        return _slice(_userVestings[user], offset, limit);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    function _checkDAO() internal view {
        if (msg.sender != dao) revert NotDAO();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Shared slicing helper.
    function _slice(address[] storage arr, uint256 offset, uint256 limit)
        private
        view
        returns (address[] memory page)
    {
        uint256 total = arr.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        page = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            page[i] = arr[offset + i];
        }
    }
}

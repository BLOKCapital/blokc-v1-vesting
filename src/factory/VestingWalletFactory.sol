// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*###############################################################################

    @title Vesting Wallet Factory
    @author BLOK Capital DAO
    @notice Deploys and registers VestingWalletBlokc instances. DAO-gated creation,
            2-step DAO rotation, and a registry queryable with pagination.

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import {VestingWalletBlokc} from "../VestingWallet.sol";

/// @title VestingWalletFactory
/// @author BLOK Capital DAO
/// @notice Factory + registry for {VestingWalletBlokc} instances. Serves as the
///single source of truth for the active DAO address — every wallet
///deployed by this factory reads `factory.dao()` live, so rotating the
///DAO here immediately propagates the new authority to all existing
///wallets without needing per-wallet migrations.

/// @dev Responsibilities:
///Gate wallet creation to the DAO (prevents registry pollution).
///Provide a 2-step DAO handover (`beginDAOTransfer` → `acceptDAOTransfer`)
///to avoid irrecoverable transfers to the wrong address.
///Maintain `allVestings` and per-user lists for discovery.
///Emit rich creation events so indexers can reconstruct the schedule
///without extra RPC calls into each wallet.

contract VestingWalletFactory {
    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Active DAO address; single source of truth for all deployed wallets.
    address public dao;

    /// @notice Candidate DAO address awaiting acceptance (2-step rotation).
   
    address public pendingDao;

    /// @notice Append-only list of every wallet the factory has deployed.
    address[] private _allVestings;

    /// @notice Per-beneficiary list of wallets, keyed by the beneficiary address
    ///at creation time, stale if a wallet later calls {transferOwnership}
    mapping(address => address[]) private _userVestings;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Caller is not the current DAO.
    error NotDAO();

    /// @notice Caller is not the pending DAO; cannot accept a transfer.
    error NotPendingDAO();

    /// @notice A zero address was supplied where a non-zero address is required.
    error ZeroAddress();

    /// @notice Vesting duration cannot be zero.
    error ZeroDuration();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when the current DAO initiates a rotation.
    /// @param currentDao Existing DAO address (still authoritative).
    /// @param pendingDao Candidate DAO address that must call {acceptDAOTransfer}.
    event DAOTransferStarted(address indexed currentDao, address indexed pendingDao);

    /// @notice Emitted when a DAO rotation completes.
    /// @param oldDao DAO address prior to the transfer.
    /// @param newDao New authoritative DAO address.
    event DAOTransferred(address indexed oldDao, address indexed newDao);

    /// @notice Emitted when a new vesting wallet is created.These include params for indexing and logging.
    /// @param wallet Address of the newly deployed {VestingWalletBlokc}.
    /// @param beneficiary The initial beneficiary (owner) of the wallet.
    /// @param start Vesting start timestamp (unix seconds).
    /// @param duration Total vesting duration in seconds.
    /// @param cliffDuration Cliff duration in seconds, measured from `start`.
    /// @param revokeAllowed Whether the DAO may revoke unvested assets.
    event VestingWalletCreated(
        address indexed wallet,
        address indexed beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliffDuration,
        bool revokeAllowed
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Restricts the call to the current DAO address.
    modifier onlyDAO() {
        if (msg.sender != dao) revert NotDAO();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Construction
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Initialise the factory with a DAO address.
    /// @param dao_ The initial DAO. Must be non-zero. Can be rotated later via the
    ///2-step {beginDAOTransfer} / {acceptDAOTransfer} flow.
    constructor(address dao_) {
        if (dao_ == address(0)) revert ZeroAddress();
        dao = dao_;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DAO rotation (2-step)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Start a 2-step DAO rotation. The new DAO must call {acceptDAOTransfer} to complete.
    /// @dev The rotation is not effective until acceptance; any address that has
    /// not yet accepted cannot authorise DAO-only actions.
    /// @param newDAO Candidate DAO address. Must be non-zero.
    function beginDAOTransfer(address newDAO) external onlyDAO {
        if (newDAO == address(0)) revert ZeroAddress();
        pendingDao = newDAO;
        emit DAOTransferStarted(dao, newDAO);
    }

    /// @notice Called by the pending DAO to finalise rotation. Propagates to every existing wallet
    /// because wallets read `factory.dao()` live.
    /// @dev Clears {pendingDao} on success. Reverts with {NotPendingDAO} if called
    ///      by any address other than the current pending DAO.
    function acceptDAOTransfer() external {
        if (msg.sender != pendingDao) revert NotPendingDAO();
        address old = dao;
        dao = pendingDao;
        pendingDao = address(0);
        emit DAOTransferred(old, dao);
    }

    /// @notice Cancel a pending DAO transfer before acceptance.
    /// @dev Useful when the intended candidate no longer applies (e.g. wrong address
    ///      queued). Only callable by the current DAO.
    function cancelDAOTransfer() external onlyDAO {
        pendingDao = address(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Wallet creation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploy a new vesting wallet. DAO-only to prevent registry pollution.
    /// @dev The DAO is responsible for funding the wallet with the relevant asset
    ///it may be ERC20 or ETH
    /// @param beneficiary The initial wallet owner / beneficiary. Must be non-zero.
    /// @param start Vesting start timestamp (unix seconds).
    /// @param duration Total vesting duration in seconds. Must be > 0.
    /// @param cliffDuration Cliff duration in seconds, measured from `start`.
    /// @param revokeAllowed Whether the DAO may revoke unvested assets from the wallet.
    /// @return The address of the newly deployed {VestingWalletBlokc}.
    function createVestingWallet(
        address beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliffDuration,
        bool revokeAllowed
    ) external onlyDAO returns (address) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (duration == 0) revert ZeroDuration();

        VestingWalletBlokc wallet =
            new VestingWalletBlokc(address(this), beneficiary, start, duration, cliffDuration, revokeAllowed);
        address walletAddr = address(wallet);
        _userVestings[beneficiary].push(walletAddr);
        _allVestings.push(walletAddr);

        emit VestingWalletCreated(walletAddr, beneficiary, start, duration, cliffDuration, revokeAllowed);
        return walletAddr;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Number of wallets ever deployed by this factory.
    /// @return Length of the internal registry.
    function allVestingsLength() external view returns (uint256) {
        return _allVestings.length;
    }

    /// @notice Number of wallets registered for a given user (by original beneficiary).
    /// @param user The beneficiary at creation time.
    /// @return Length of the user's registry list.
    function userVestingsLength(address user) external view returns (uint256) {
        return _userVestings[user].length;
    }

    /// @notice Full registry. Convenient off-chain, unsafe for on-chain consumption at scale.
    /// @dev Returns the entire list — O(n) memory + gas. Prefer {getAllVestingsPaged}
    ///      for on-chain calls once the registry grows.
    /// @return All wallet addresses ever created.
    function getAllVestings() external view returns (address[] memory) {
        return _allVestings;
    }

    /// @notice All wallets assigned to `user` at creation time. (Stale after {transferOwnership}.)
    /// @dev Because ownership can be moved (rescue), this list reflects the
    ///      beneficiary at creation time, not necessarily the current owner.
    /// @param user The beneficiary at creation time.
    /// @return All wallet addresses originally assigned to `user`.
    function getUserVestings(address user) external view returns (address[] memory) {
        return _userVestings[user];
    }

    /// @notice Paginated registry slice.
    /// @param offset Index to start at (0-based).
    /// @param limit Maximum number of entries to return.
    /// @return page The slice `[offset, offset+limit)` (clamped to the registry length).
    function getAllVestingsPaged(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        return _slice(_allVestings, offset, limit);
    }

    /// @notice Paginated per-user registry slice.
    /// @param user The beneficiary at creation time.
    /// @param offset Index to start at (0-based).
    /// @param limit Maximum number of entries to return.
    /// @return page The slice `[offset, offset+limit)` of the user's list.
    function getUserVestingsPaged(address user, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        return _slice(_userVestings[user], offset, limit);
    }

    /// @dev Shared slicing helper. Returns an empty array if `offset` is past the
    ///end; otherwise returns up to `limit` elements starting at `offset`.
    /// @param arr Storage array to slice.
    /// @param offset Index to start at.
    /// @param limit Maximum number of elements to copy.
    /// @return page Memory copy of the requested slice.
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

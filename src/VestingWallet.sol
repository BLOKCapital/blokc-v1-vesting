// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*###############################################################################

    @title Vesting Wallet
    @author BLOK Capital DAO
    @notice Extends OpenZeppelin VestingWallet + VestingWalletCliff with:
            DAO-gated revoke (ERC20 + ETH), pausable releases, DAO-only
            ownership rescue, and beneficiary-gated governance delegation.

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title IVestingWalletFactory
/// @notice Minimal interface used by {VestingWalletBlokc} to read the active DAO address
///         live from the factory. A single source of truth avoids stale DAO references
///         across dozens of deployed wallets when keys are rotated.
interface IVestingWalletFactory {
    /// @notice Returns the current DAO address as known to the factory.
    /// @return The DAO address.
    function dao() external view returns (address);
}

/// @title VestingWalletBlokc
/// @author BLOK Capital DAO
/// @notice Cliff-plus-linear vesting wallet with DAO oversight. Built on top of
///         {VestingWallet} and {VestingWalletCliff} from OpenZeppelin. In addition to
///         the base vesting behavior it supports:
///
///         * DAO-initiated revoke of unvested ERC20 / ETH (behind an immutable
///           `revokeAllowed` flag set at construction),
///         * Idempotent per-asset revoke with `proposalRef` logged for off-chain
///           governance audit trails,
///         * Emergency pause of releases by the DAO,
///         * DAO-only `transferOwnership` rescue path (prevents a beneficiary from
///           selling unvested tokens by trading out the wallet owner),
///         * Disabled `renounceOwnership` to prevent orphaning vested funds,
///         * Beneficiary-only governance `delegate()` passthrough.
///
/// @dev Post-revoke semantics: once `revoke` has been called for an asset, the
///      remaining balance in the wallet is treated as fully vested and becomes
///      immediately releasable. This differs from the OZ base, which would rebase
///      the vesting curve over the reduced pool and force the beneficiary to wait
///      out the full duration. The chosen semantic matches user intuition: "revoke
///      stops vesting — what you earned so far is yours to claim now."
///
/// @custom:security-contact security@blokcapital.io
contract VestingWalletBlokc is VestingWalletCliff, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The factory that deployed this wallet. Acts as the authoritative
    ///         source of the current DAO address via `factory.dao()`.
    /// @dev Immutable; set once in the constructor. A rotation at the factory level
    ///      propagates to every wallet automatically because DAO is read live.
    IVestingWalletFactory public immutable factory;

    /// @notice Whether the DAO is permitted to revoke unvested assets from this
    ///         wallet. Set at construction and cannot change afterwards — this is
    ///         the contractual commitment made to the beneficiary at grant time.
    bool public immutable revokeAllowed;

    /// @notice Tracks whether a given ERC20 asset has already been revoked.
    /// @dev Once `true` for a token, subsequent `revoke()` calls for that token
    ///      revert with {AlreadyRevoked}. Also flips the {vestedAmount} view for
    ///      that token into "fully vested" mode.
    mapping(address token => bool) public revoked;

    /// @notice Tracks whether the native ETH balance has already been revoked.
    /// @dev Mirrors {revoked} but for the ETH path.
    bool public ethRevoked;

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
    /// @param token The ERC20 whose unvested portion was swept.
    /// @param dao The DAO address that received the unvested amount (snapshot at revoke time).
    /// @param unvestedAmount Amount transferred to the DAO. May be zero if everything was already vested.
    /// @param proposalRef Off-chain governance reference (e.g. proposal hash, Snapshot id)
    ///        included purely for audit traceability. Not verified on-chain.
    event VestingRevoked(address indexed token, address indexed dao, uint256 unvestedAmount, bytes32 proposalRef);

    /// @notice Emitted when the DAO sweeps unvested ETH to itself.
    /// @param dao DAO address that received the unvested ETH.
    /// @param unvestedAmount Amount of wei transferred.
    /// @param proposalRef Off-chain governance reference.
    event EthVestingRevoked(address indexed dao, uint256 unvestedAmount, bytes32 proposalRef);

    /// @notice Emitted when the beneficiary delegates the wallet's governance voting power.
    /// @param token ERC20Votes-compatible token whose voting power is being delegated.
    /// @param delegatee Address receiving the delegated voting power.
    event Delegated(address indexed token, address indexed delegatee);

    /// @notice Emitted when the DAO pauses releases.
    /// @param dao DAO address that triggered the pause.
    event EmergencyPaused(address indexed dao);

    /// @notice Emitted when the DAO lifts the pause.
    /// @param dao DAO address that lifted the pause.
    event EmergencyUnpaused(address indexed dao);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Restricts the call to the current DAO address read from the factory.
    /// @dev Reads DAO live via `factory.dao()` so that key rotations at the factory
    ///      level immediately update every deployed wallet's authorisation set.
    modifier onlyDAO() {
        _checkDAO();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Construction
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploys a vesting wallet with the supplied schedule parameters.
    /// @param factory_ The factory deploying this wallet; provides the live DAO address.
    /// @param beneficiary_ The initial owner / beneficiary who can call {release}.
    /// @param startTimestamp Vesting start (unix seconds). Tokens deposited before this
    ///point are treated as if locked from the start; linear vesting begins here.
    /// @param durationSeconds Total vesting duration in seconds from `startTimestamp`.
    /// @param cliffDuration Cliff duration in seconds measured from `startTimestamp`.
    ///No tokens are releasable until `start + cliffDuration` is reached.
    /// @param revokeAllowed_ Whether the DAO may revoke unvested assets from this wallet.
    ///This is the on-chain commitment; flip it to `false` to make the grant
    ///non-revocable.
    /// @dev The OZ {VestingWalletCliff} constructor already enforces
    ///`cliffDuration <= durationSeconds` via `InvalidCliffDuration`.
    constructor(
        address factory_,
        address beneficiary_,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffDuration,
        bool revokeAllowed_
    ) VestingWallet(beneficiary_, startTimestamp, durationSeconds) VestingWalletCliff(cliffDuration) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = IVestingWalletFactory(factory_);
        revokeAllowed = revokeAllowed_;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the current DAO address as seen by this wallet.
    /// @dev Equivalent to `factory.dao()`. Exposed as a convenience for indexers.
    /// @return The live DAO address.
    function dao() external view returns (address) {
        return factory.dao();
    }

    /// @notice Returns the current beneficiary of this wallet.
    /// @dev By OZ convention, the beneficiary is always `owner()`. This getter
    ///reflects post-rescue state after a DAO-initiated {transferOwnership}.
    /// @return The beneficiary address (== {owner}).
    function beneficiary() public view returns (address) {
        return owner();
    }

    /// @notice Computes the amount of ETH vested at `timestamp`.
    /// @dev Overrides the OZ base to short-circuit after ETH revoke. Post-revoke the
    ///remaining balance is treated as fully vested (see contract-level dev note),
    ///so the beneficiary can claim it immediately rather than waiting out the
    ///original duration on a rebased curve.
    /// @param timestamp Unix time in seconds at which to evaluate the schedule.
    /// @return The ETH amount considered vested at `timestamp`.
    function vestedAmount(uint64 timestamp) public view virtual override returns (uint256) {
        if (ethRevoked) return address(this).balance + released();
        return super.vestedAmount(timestamp);
    }

    /// @notice Computes the amount of `token` vested at `timestamp`.
    /// @dev See {vestedAmount(uint64)} for the post-revoke rationale.
    /// @param token ERC20 token whose vested amount should be computed.
    /// @param timestamp Unix time in seconds at which to evaluate the schedule.
    /// @return The token amount considered vested at `timestamp`.
    function vestedAmount(address token, uint64 timestamp) public view virtual override returns (uint256) {
        if (revoked[token]) return IERC20(token).balanceOf(address(this)) + released(token);
        return super.vestedAmount(token, timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Releases pause-gated
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Release the ETH that has already vested.
    /// @dev Gated by {Pausable} so the DAO can halt releases during an incident.
    function release() public virtual override whenNotPaused {
        super.release();
    }

    /// @notice Release the `token` amount that has already vested.
    /// @param token ERC20 token to release to the beneficiary.
    /// @dev Gated by {Pausable} so the DAO can halt releases during an incident.
    function release(address token) public virtual override whenNotPaused {
        super.release(token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Governance delegation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Delegates the voting power of an {IVotes} token held by this wallet.
    /// @dev Only the current beneficiary (owner) may call this. Delegation can be
    ///  rotated at any time by re-calling with a different `delegatee`.
    /// @param token An {IVotes}-compatible token address.
    /// @param delegatee Address to delegate voting power to. Cannot be zero.
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
    /// @dev Must be invoked by the current DAO, and only on wallets where
    ///`revokeAllowed == true`. Idempotent per token: a second call for the
    ///same token reverts with {AlreadyRevoked}. The unvested amount is
    ///computed against the pre-revoke vesting curve; `revoked[token]` is
    ///flipped **after** that computation so the {releasable} view returns
    ///the correct pre-revoke number.
    /// @param token ERC20 being revoked.
    /// @param proposalRef Off-chain governance reference (proposal hash / Snapshot id)
    ///recorded in the event. Not validated on-chain; intended for audit trails.
    function revoke(address token, bytes32 proposalRef) external onlyDAO nonReentrant {
        if (!revokeAllowed) revert RevokeNotAllowed();
        if (revoked[token]) revert AlreadyRevoked();

        // Compute unvested against the pre-revoke schedule; only then flip the flag.
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 claimable = releasable(token);
        uint256 unvestedAmount = bal - claimable;

        revoked[token] = true;

        address daoAddr = factory.dao();
        if (unvestedAmount > 0) {
            IERC20(token).safeTransfer(daoAddr, unvestedAmount);
        }
        emit VestingRevoked(token, daoAddr, unvestedAmount, proposalRef);
    }

    /// @notice Sweep the unvested portion of the wallet's ETH balance to the DAO.
    /// @dev Same semantics as {revoke(address,bytes32)} but for ETH. Idempotent.
    /// @param proposalRef Off-chain governance reference, recorded in the event.
    function revokeEth(bytes32 proposalRef) external onlyDAO nonReentrant {
        if (!revokeAllowed) revert RevokeNotAllowed();
        if (ethRevoked) revert AlreadyRevoked();

        uint256 bal = address(this).balance;
        uint256 claimable = releasable();
        uint256 unvestedAmount = bal - claimable;

        ethRevoked = true;

        address daoAddr = factory.dao();
        if (unvestedAmount > 0) {
            Address.sendValue(payable(daoAddr), unvestedAmount);
        }
        emit EthVestingRevoked(daoAddr, unvestedAmount, proposalRef);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Emergency pause
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Halt {release} calls. DAO-only.
    /// @dev Intended as a circuit breaker during incidents; see OZ {Pausable}.
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
    /// @dev Gated to the DAO so that a compromised beneficiary cannot trade out
    ///their grant by transferring the owner slot. This is also the rescue
    ///path for a lost-key scenario: the DAO can migrate ownership to a
    ///replacement address the beneficiary controls. Zero address is rejected.
    /// @param newOwner The new beneficiary. Must be non-zero.
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
        if (msg.sender != factory.dao()) revert NotDAO();
    }
}

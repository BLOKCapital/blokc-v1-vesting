// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {VestingWalletUpgradeable} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletUpgradeable.sol";
import {
    VestingWalletCliffUpgradeable
} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletCliffUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @notice Minimal callback interface used by the wallet to notify the
///         factory on forfeit so dashboards/indexers see a single feed.
interface IBLOKCVestingFactory {
    function notifyForfeit(uint256 unvestedAmount) external;
}

/**
 * @title BLOKCVestingWallet
 * @author BLOK Capital
 * @notice Per-vest contract holding $BLOKC for a single beneficiary. Implements
 *         BCIP-001: cliff-then-linear schedule (OZ math — at cliff end the
 *         linearly accrued portion through the cliff becomes claimable; e.g.
 *         12mo cliff of a 48mo total schedule unlocks 25% at month 12, then
 *         linearly to 100% at month 48), prePaid flag separating builder from
 *         investor vests, terminationDisclosed gate on DAO termination,
 *         voluntary forfeiture (builders only), and day-one voting power via
 *         IVotes delegation.
 *
 *         Deployed as an EIP-1167 minimal proxy clone by BLOKCVestingFactory.
 *         The factory is the only authorized caller of {terminate}.
 */
contract BLOKCVestingWallet is VestingWalletCliffUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public factory;
    address public treasury;
    address public token;

    bool public prePaid;
    bool public terminationDisclosed;

    bool public ended;
    uint64 public endedAt;

    uint256 public totalAtStart;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Terminated(uint256 unvestedReturnedToTreasury, uint64 endedAt, bytes32 proposalRef, bytes32 groundsHash);
    event Forfeited(uint256 unvestedReturnedToTreasury, uint64 endedAt);
    event DelegateUpdated(address indexed previousDelegate, address indexed newDelegate);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotBeneficiary();
    error NotFactory();
    error InvestorVestNonTerminable();
    error InvestorVestNonForfeitable();
    error TerminationNotDisclosed();
    error AlreadyEnded();
    error AlreadyMatured();
    error ZeroAddress();
    error InvalidDuration();
    error RenounceDisabled();
    error OwnershipTransferDisabled();
    error EthNotSupported();

    // ---------------------------------------------------------------------
    // Constructor — disables initializers on the implementation contract
    // ---------------------------------------------------------------------

    constructor() {
        _disableInitializers();
    }

    // ---------------------------------------------------------------------
    // Initialization (called by the factory after cloning)
    // ---------------------------------------------------------------------

    /// @notice Cliff and linear durations come from the factory's immutable
    ///         schedule — every vest deployed by a given factory shares the
    ///         same curve, regardless of prePaid / terminationDisclosed.
    function initialize(
        address factory_,
        address token_,
        address treasury_,
        address beneficiary_,
        uint64 startTimestamp_,
        uint64 cliffDuration_,
        uint64 linearVestDuration_,
        bool prePaid_,
        bool terminationDisclosed_,
        uint256 totalAmount_
    ) external initializer {
        if (factory_ == address(0)) revert ZeroAddress();
        if (token_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (beneficiary_ == address(0)) revert ZeroAddress();
        if (linearVestDuration_ == 0) revert InvalidDuration();

        uint64 totalDuration = cliffDuration_ + linearVestDuration_;
        __VestingWallet_init(beneficiary_, startTimestamp_, totalDuration);
        __VestingWalletCliff_init(cliffDuration_);

        factory = factory_;
        token = token_;
        treasury = treasury_;
        prePaid = prePaid_;
        terminationDisclosed = terminationDisclosed_;
        totalAtStart = totalAmount_;

        // Sweep any pre-existing surplus so delegated votes equal exactly totalAmount_.
        uint256 bal = IERC20(token_).balanceOf(address(this));
        if (bal > totalAmount_) {
            IERC20(token_).safeTransfer(treasury_, bal - totalAmount_);
        }

        // Day-one voting power: the wallet's $BLOKC balance accrues votes to
        // the beneficiary on Aragon TokenVoting from this block forward.
        IVotes(token_).delegate(beneficiary_);
    }

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyBeneficiary() {
        if (msg.sender != owner()) revert NotBeneficiary();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    // ---------------------------------------------------------------------
    // Vesting schedule overrides
    // ---------------------------------------------------------------------

    /// @notice Returns 0 for any token other than the configured $BLOKC.
    ///         Computes against {totalAtStart} (not balance + released) so
    ///         returning unvested tokens to the treasury on termination does
    ///         not corrupt the curve. Caps the effective timestamp at
    ///         {endedAt} when the vest has been ended.
    ///
    ///         The underlying {_vestingSchedule} is OZ's cliff curve: 0 before
    ///         cliff(), then `total * (t - start) / duration` from the cliff
    ///         moment onward. For a 12/36/48 schedule that's 25% at month 12,
    ///         50% at month 24, 100% at month 48.
    function vestedAmount(address tkn, uint64 timestamp) public view virtual override returns (uint256) {
        if (tkn != token) return 0;
        uint64 effective = ended && timestamp > endedAt ? endedAt : timestamp;
        return _vestingSchedule(totalAtStart, effective);
    }

    // ---------------------------------------------------------------------
    // Termination — DAO-initiated, factory-routed
    // ---------------------------------------------------------------------

    /// @notice End the vest by DAO action. Returns the unvested portion to
    ///         the treasury; already-vested tokens remain claimable by the
    ///         beneficiary via {release}. Reverts unconditionally for
    ///         investor (prePaid) vests — the contract-level protection
    ///         promised in BCIP-001. Reverts post-maturity to prevent
    ///         misleading termination events on naturally-completed vests.
    /// @param proposalRef Aragon proposal hash that authorised this call.
    /// @param groundsHash keccak of the published grounds text. Pinned on
    ///        chain so a future audit can detect grounds-text tampering.
    function terminate(bytes32 proposalRef, bytes32 groundsHash) external onlyFactory nonReentrant {
        if (prePaid) revert InvestorVestNonTerminable();
        if (!terminationDisclosed) revert TerminationNotDisclosed();
        if (ended) revert AlreadyEnded();
        if (totalAtStart - _vestingSchedule(totalAtStart, uint64(block.timestamp)) == 0) revert AlreadyMatured();

        uint64 endTime = uint64(block.timestamp);
        ended = true;
        endedAt = endTime;

        uint256 vestedAmt = _vestingSchedule(totalAtStart, endTime);
        uint256 unvested = totalAtStart - vestedAmt;

        if (unvested > 0) {
            IERC20(token).safeTransfer(treasury, unvested);
        }

        emit Terminated(unvested, endTime, proposalRef, groundsHash);
    }

    // ---------------------------------------------------------------------
    // Voluntary forfeit — beneficiary initiated, builders only
    // ---------------------------------------------------------------------

    /// @notice Beneficiary-initiated end of the vest. Pre-cliff: full
    ///         allocation returns to treasury. Post-cliff: vested portion
    ///         remains claimable, unvested returns to treasury.
    ///
    ///         Reverts for investor (prePaid) vests — investors paid for
    ///         their allocation; voluntarily forfeiting it is not a defined
    ///         action under BCIP-001 and would only ever be a misclick. The
    ///         tokens vest normally and are claimable on schedule.
    ///
    ///         Reverts post-maturity (all tokens already vested) to prevent
    ///         misleading forfeit events with unvested == 0.
    ///
    ///         On success, calls {IBLOKCVestingFactory.notifyForfeit} so the
    ///         factory emits a single-source-of-truth event for indexers.
    function forfeit() external onlyBeneficiary nonReentrant {
        if (prePaid) revert InvestorVestNonForfeitable();
        if (ended) revert AlreadyEnded();
        if (totalAtStart - _vestingSchedule(totalAtStart, uint64(block.timestamp)) == 0) revert AlreadyMatured();

        uint64 endTime = uint64(block.timestamp);
        ended = true;
        endedAt = endTime;

        uint256 vestedAmt = _vestingSchedule(totalAtStart, endTime);
        uint256 unvested = totalAtStart - vestedAmt;

        if (unvested > 0) {
            IERC20(token).safeTransfer(treasury, unvested);
        }

        IBLOKCVestingFactory(factory).notifyForfeit(unvested);

        emit Forfeited(unvested, endTime);
    }

    // ---------------------------------------------------------------------
    // Claim — pause-free, reentrancy-guarded
    // ---------------------------------------------------------------------

    /// @notice Release the vested $BLOKC to the beneficiary. Anyone can call
    ///         this; funds always go to {owner}. Reentrancy-guarded as
    ///         defence-in-depth around the underlying ERC20 transfer.
    function release(address tkn) public virtual override nonReentrant {
        super.release(tkn);
    }

    // ---------------------------------------------------------------------
    // ETH rejected; standard no-arg interface re-routed to ERC20
    // ---------------------------------------------------------------------

    /// @notice ETH is not part of BCIP-001 scope. Reject incoming ETH so it
    ///         cannot accidentally vest to the beneficiary.
    receive() external payable override {
        revert EthNotSupported();
    }

    /// @notice No-arg release routes to the ERC20 path so generic OZ
    ///         integrations work correctly without knowing the token address.
    function release() public virtual override nonReentrant {
        super.release(token);
    }

    function vestedAmount(uint64) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Returns the ERC20 $BLOKC amount currently claimable, so no-arg
    ///         OZ integrations read the correct value instead of 0.
    function releasable() public view virtual override returns (uint256) {
        return super.releasable(token);
    }

    /// @notice Returns the ERC20 $BLOKC amount released to date.
    function released() public view virtual override returns (uint256) {
        return super.released(token);
    }

    // ---------------------------------------------------------------------
    // Ownership controls — both paths permanently disabled
    // ---------------------------------------------------------------------

    /// @notice Renouncing would orphan vested-but-unclaimed tokens and kill
    ///         the IVotes delegation. Permanently disabled.
    function renounceOwnership() public view override {
        revert RenounceDisabled();
    }

    /// @notice A vest is bound to its original beneficiary; rotating
    ///         addresses is not supported. Keeps the factory's
    ///         `_vestsByBeneficiary` registry authoritative.
    function transferOwnership(address) public view override {
        revert OwnershipTransferDisabled();
    }

    // ---------------------------------------------------------------------
    // Governance delegation rotation
    // ---------------------------------------------------------------------

    /// @notice Re-delegates the vest's voting power to a new address.
    ///         Only the beneficiary can call this. Emits {DelegateUpdated}.
    function updateDelegate(address newDelegate) external onlyBeneficiary {
        if (newDelegate == address(0)) revert ZeroAddress();
        address previous = IVotes(token).delegates(address(this));
        IVotes(token).delegate(newDelegate);
        emit DelegateUpdated(previous, newDelegate);
    }

    // ---------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------

    /// @notice Vested amount of $BLOKC at the current block timestamp.
    function vested() external view returns (uint256) {
        return vestedAmount(token, uint64(block.timestamp));
    }

    /// @notice Amount of $BLOKC currently claimable via {release}.
    function claimable() external view returns (uint256) {
        return releasable(token);
    }

    /// @notice Whether this vest's agreement disclosed the DAO's termination
    ///         right. Builder vests with `false` cannot be terminated.
    function isTerminationDisclosed() external view returns (bool) {
        return terminationDisclosed;
    }

    /// @notice Total promised allocation that has not yet been released.
    ///         Used by the dashboard and by the Aragon plugin for voting
    ///         weight aggregation. After termination/forfeiture, freezes at
    ///         the value implied by {endedAt}.
    function unclaimedAllocation() external view returns (uint256) {
        if (ended) {
            uint256 finalVested = _vestingSchedule(totalAtStart, endedAt);
            return finalVested - released(token);
        }
        return totalAtStart - released(token);
    }
}

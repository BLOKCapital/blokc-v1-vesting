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
    function notifyForfeit() external;
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
 *         voluntary forfeiture (non-disclosed builder vests only — disclosed
 *         vests are DAO-termination-only so the grounds record cannot be
 *         pre-empted), and day-one voting power via IVotes delegation.
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

    /// @notice Set by the factory via {requestTermination} to reserve the
    ///         termination path ahead of {terminate}. While pending, only
    ///         {terminate} (or {cancelTerminationRequest}) can resolve it;
    ///         disclosed vests cannot {forfeit} at all, so the {Terminated}
    ///         event with its grounds hash can never be pre-empted.
    bool public terminationRequested;
    bytes32 public pendingProposalRef;
    bytes32 public pendingGroundsHash;

    /// @notice Absolute expiry of the pending termination request. A request
    ///         governance neither fulfils nor cancels expires after
    ///         {TERMINATION_REQUEST_WINDOW}; once expired it no longer
    ///         authorises {terminate}. An *active* request cannot be
    ///         re-requested, so the window cannot be extended indefinitely
    ///         by re-issuing requests.
    uint64 public terminationRequestDeadline;

    /// @notice How long a pending termination request stays valid. The DAO
    ///         must fulfil it within this window; afterwards the request
    ///         expires and may be replaced by a fresh one.
    uint64 public constant TERMINATION_REQUEST_WINDOW = 30 days;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Terminated(uint256 unvestedReturnedToTreasury, uint64 endedAt, bytes32 proposalRef, bytes32 groundsHash);
    event Forfeited(uint256 unvestedReturnedToTreasury, uint64 endedAt);
    event TerminationRequested(bytes32 proposalRef, bytes32 groundsHash);
    event TerminationRequestCancelled();
    /// @notice A balance above the curve-tracked remainder (donation or forced
    ///         transfer) was swept back to the treasury. Emitted on the init,
    ///         release, forfeit, terminate and recoverSurplus sweeps so
    ///         indexers can reconcile the exact treasury inflow — the frozen
    ///         Terminated/Forfeited amounts cover only the curve.
    event SurplusSwept(uint256 amount);

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
    error Underfunded(uint256 actual, uint256 expected);
    error DisclosedVestNonForfeitable();
    error TerminationRequestActive();
    error NoTerminationRequest();
    error TerminationRefsMismatch();
    error TerminationRequestExpired();
    error NotSupportedToken();

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
    ) external initializer nonReentrant {
        if (factory_ == address(0)) revert ZeroAddress();
        if (token_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (beneficiary_ == address(0)) revert ZeroAddress();
        if (linearVestDuration_ == 0) revert InvalidDuration();
        // The sum is stored in uint64 via __VestingWallet_init; a wrapped
        // total duration would produce a schedule that never vests. Checked
        // in uint256 space so the addition itself cannot overflow.
        if (uint256(cliffDuration_) + uint256(linearVestDuration_) > type(uint64).max) revert InvalidDuration();
        // The cliff timestamp is also a uint64 addition (start + cliff); a
        // wrapped sum silently produces a schedule that has already started.
        // Same uint256-space check.
        if (uint256(startTimestamp_) + uint256(cliffDuration_) > type(uint64).max) revert InvalidDuration();
        // The schedule end (start + cliff + linear) must fit in uint64 too:
        // `end()` is computed in uint256, so a wrapped end can never be
        // reached by any real timestamp and the vest would never mature — a
        // permanent lock for investor (prePaid) vests, whose forfeit and
        // terminate paths are both disabled.
        if (uint256(startTimestamp_) + uint256(cliffDuration_) + uint256(linearVestDuration_) > type(uint64).max) {
            revert InvalidDuration();
        }
        // Bind the initializer to the factory the clone advertises: without
        // this, anyone can clone the implementation and initialize it with
        // the canonical factory's address, producing a look-alike vest whose
        // `factory()` and lifecycle events point at the real factory (the
        // factory itself only ever initializes clones it deploys atomically
        // inside createVest, so it cannot be the source of such a clone).
        // Bare clones are still possible — they simply name their own
        // initializer as `factory_`. The factory's `isVest` registry
        // independently gates every privileged interaction with the
        // canonical factory.
        if (msg.sender != factory_) revert NotFactory();

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
        // A deficit (fee-on-transfer token delivering less than promised) would
        // overstate totalAtStart against the actual balance and eventually
        // brick release() — reject it instead.
        _sweepSurplusOrRevert(token_, treasury_, totalAmount_);

        // Day-one voting power: the wallet's $BLOKC balance accrues votes to
        // the beneficiary on Aragon TokenVoting from this block forward.
        IVotes(token_).delegate(beneficiary_);
    }

    /// @notice Returns any pre-existing balance above `expected` to the
    ///         treasury; reverts if the wallet holds less than `expected`
    ///         (e.g. a fee-on-transfer token under-delivered the funding).
    function _sweepSurplusOrRevert(address token_, address treasury_, uint256 expected) internal {
        uint256 bal = IERC20(token_).balanceOf(address(this));
        if (bal > expected) {
            emit SurplusSwept(bal - expected);
            IERC20(token_).safeTransfer(treasury_, bal - expected);
            // Re-check after the sweep: a fee-on-transfer token that taxes
            // the sweep transfer would otherwise leave the wallet short of
            // the promised funding with no error.
            uint256 balAfter = IERC20(token_).balanceOf(address(this));
            if (balAfter < expected) revert Underfunded(balAfter, expected);
        } else if (bal < expected) {
            revert Underfunded(bal, expected);
        }
    }

    /// @notice Returns any balance above the amount the vest should hold —
    ///         the curve-tracked remainder — to the treasury. Post-init
    ///         donations would otherwise be permanently locked (every value
    ///         path is anchored to {totalAtStart}) and keep inflating the
    ///         beneficiary's delegated votes, since the wallet's balance is
    ///         the IVotes vote ledger. No-op when the wallet holds exactly
    ///         the expected amount or less (e.g. outbound transfer fees).
    function _sweepExcess() internal {
        uint256 expected =
            ended ? _vestingSchedule(totalAtStart, endedAt) - released(token) : totalAtStart - released(token);
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > expected) {
            emit SurplusSwept(bal - expected);
            IERC20(token).safeTransfer(treasury, bal - expected);
        }
    }

    /// @notice Anyone can route a post-init surplus (direct $BLOKC transfers
    ///         to this vest) back to the treasury, un-trapping the tokens and
    ///         deflating the balance-driven delegated votes.
    function recoverSurplus() external nonReentrant {
        _sweepExcess();
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

    /// @notice Reserve the termination path ahead of {terminate}, committing
    ///         the proposal ref and grounds hash that {terminate} must later
    ///         match. Disclosed vests cannot {forfeit} at all, so this
    ///         reservation cannot be pre-empted. An active request cannot be
    ///         replaced until it is fulfilled, cancelled, or expired.
    /// @param proposalRef Aragon proposal hash that authorised this request.
    /// @param groundsHash keccak of the published grounds text.
    function requestTermination(bytes32 proposalRef, bytes32 groundsHash) external onlyFactory {
        if (prePaid) revert InvestorVestNonTerminable();
        if (!terminationDisclosed) revert TerminationNotDisclosed();
        if (ended) revert AlreadyEnded();
        if (totalAtStart - _vestingSchedule(totalAtStart, uint64(block.timestamp)) == 0) revert AlreadyMatured();
        // An active request cannot be re-requested: each call would
        // otherwise push the deadline another full window out, negating the
        // expiry. Expired requests may be replaced with fresh refs.
        if (terminationRequested && block.timestamp <= terminationRequestDeadline) revert TerminationRequestActive();

        terminationRequested = true;
        terminationRequestDeadline = uint64(block.timestamp) + TERMINATION_REQUEST_WINDOW;
        pendingProposalRef = proposalRef;
        pendingGroundsHash = groundsHash;
        emit TerminationRequested(proposalRef, groundsHash);
    }

    /// @notice Withdraw a pending termination request (governance changed its
    ///         mind before executing). Only the factory may call.
    function cancelTerminationRequest() external onlyFactory {
        if (!terminationRequested) revert NoTerminationRequest();
        terminationRequested = false;
        terminationRequestDeadline = 0;
        pendingProposalRef = bytes32(0);
        pendingGroundsHash = bytes32(0);
        emit TerminationRequestCancelled();
    }

    /// @notice End the vest by DAO action. Returns the unvested portion to
    ///         the treasury; already-vested tokens remain claimable by the
    ///         beneficiary via {release}. Reverts unconditionally for
    ///         investor (prePaid) vests — the contract-level protection
    ///         promised in BCIP-001. Reverts post-maturity to prevent
    ///         misleading termination events on naturally-completed vests.
    /// @param proposalRef Aragon proposal hash that authorised this call.
    /// @param groundsHash keccak of the published grounds text. Pinned on
    ///        chain so a future audit can detect grounds-text tampering.
    ///        Must match the refs committed by the pending {requestTermination}.
    function terminate(bytes32 proposalRef, bytes32 groundsHash) external onlyFactory nonReentrant {
        if (prePaid) revert InvestorVestNonTerminable();
        if (!terminationDisclosed) revert TerminationNotDisclosed();
        if (ended) revert AlreadyEnded();
        // Termination requires a pending request: the two-step
        // {requestTermination} → {terminate} flow commits the proposal ref
        // and grounds hash before execution, and disclosed vests cannot
        // {forfeit} at all, so the grounds record cannot be pre-empted.
        if (!terminationRequested) revert NoTerminationRequest();
        // The grounds pinned on-chain must be the ones the request committed
        // to; silently accepting different refs would void the anti-tamper
        // guarantee the request mechanism exists for.
        if (proposalRef != pendingProposalRef || groundsHash != pendingGroundsHash) revert TerminationRefsMismatch();
        if (block.timestamp > terminationRequestDeadline) revert TerminationRequestExpired();
        if (totalAtStart - _vestingSchedule(totalAtStart, uint64(block.timestamp)) == 0) revert AlreadyMatured();

        uint64 endTime = uint64(block.timestamp);
        ended = true;
        endedAt = endTime;
        // A pending request is fulfilled by this termination; clear it so the
        // vest returns to a clean (ended) state.
        terminationRequested = false;
        terminationRequestDeadline = 0;
        pendingProposalRef = bytes32(0);
        pendingGroundsHash = bytes32(0);

        uint256 vestedAmt = _vestingSchedule(totalAtStart, endTime);
        uint256 unvested = totalAtStart - vestedAmt;

        if (unvested > 0) {
            IERC20(token).safeTransfer(treasury, unvested);
        }
        // Return any post-init surplus (direct transfers to this vest) along
        // with the unvested portion, so donated tokens do not stay trapped.
        _sweepExcess();

        emit Terminated(unvested, endTime, proposalRef, groundsHash);
    }

    // ---------------------------------------------------------------------
    // Voluntary forfeit — beneficiary initiated, non-disclosed builders only
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
    ///         Reverts for disclosed (DAO-terminable) vests: a beneficiary
    ///         forfeit could otherwise pre-empt a DAO termination and erase
    ///         the grounds-hash record. Non-disclosed vests are not
    ///         terminable, so forfeit stays available there as the only
    ///         early exit.
    ///
    ///         On success, calls {IBLOKCVestingFactory.notifyForfeit} so the
    ///         factory emits a single-source-of-truth event for indexers.
    function forfeit() external onlyBeneficiary nonReentrant {
        if (prePaid) revert InvestorVestNonForfeitable();
        if (terminationDisclosed) revert DisclosedVestNonForfeitable();
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
        // Return any post-init surplus (direct transfers to this vest) along
        // with the unvested portion, so donated tokens do not stay trapped.
        _sweepExcess();

        IBLOKCVestingFactory(factory).notifyForfeit();

        emit Forfeited(unvested, endTime);
    }

    // ---------------------------------------------------------------------
    // Claim — pause-free, reentrancy-guarded
    // ---------------------------------------------------------------------

    /// @notice Release the vested $BLOKC to the beneficiary. Beneficiary-only:
    ///         an unauthenticated release would move the released tokens'
    ///         delegated votes to the beneficiary's own delegate — address(0)
    ///         unless they self-delegate — permanently destroying voting power
    ///         the BCIP-001 weight formula expects. Beneficiaries who want
    ///         their claimed tokens to keep voting should self-delegate
    ///         ($BLOKC.delegate(beneficiary)) so released votes follow them.
    ///         Reverts for any token other than the configured $BLOKC —
    ///         silently releasing 0 for an unrecognized token would mislead
    ///         generic OZ integrations. Reentrancy-guarded as defence-in-depth
    ///         around the underlying ERC20 transfer.
    function release(address tkn) public virtual override onlyBeneficiary nonReentrant {
        if (tkn != token) revert NotSupportedToken();
        _sweepExcess();
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
    function release() public virtual override onlyBeneficiary nonReentrant {
        _sweepExcess();
        super.release(token);
    }

    /// @notice No-arg vestedAmount routes to the ERC20 path so generic OZ
    ///         integrations that query the no-arg overload see the $BLOKC
    ///         value instead of 0. (The base ETH path is dead — ETH is
    ///         rejected via {receive}.)
    function vestedAmount(uint64 timestamp) public view override returns (uint256) {
        return vestedAmount(token, timestamp);
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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BLOKCVestingWallet} from "./BLOKCVestingWallet.sol";

/**
 * @title BLOKCVestingFactory
 * @author BLOK Capital
 * @notice Deploys BLOKCVestingWallet instances as EIP-1167 minimal proxy
 *         clones. Owned by the Aragon DAO executor via Ownable2Step;
 *         createVest and terminateVest can only be called by passing a
 *         governance proposal on the Blok Capital DAO.
 *
 *         The cliff and linear-vest durations are immutable factory state set
 *         at construction — every vest deployed by this factory shares the
 *         same curve. To change the schedule, deploy a new factory.
 *
 *         The factory holds no state beyond the registry of created vests
 *         and the immutable token / treasury / implementation / schedule
 *         pointers. It cannot amend vests, override the contract-level
 *         investor protection, or rescue funds — every privileged action
 *         flows through the DAO.
 */
contract BLOKCVestingFactory is Ownable2Step {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------

    address public immutable implementation;
    address public immutable token;
    address public immutable treasury;

    /// @notice Cliff seconds applied to every vest deployed by this factory.
    uint64 public immutable cliffDuration;

    /// @notice Linear-vest seconds applied to every vest deployed by this
    ///         factory; total vest length is cliffDuration + linearVestDuration.
    uint64 public immutable linearVestDuration;

    // ---------------------------------------------------------------------
    // Registry
    // ---------------------------------------------------------------------

    address[] public allVests;
    mapping(address => address[]) internal _vestsByBeneficiary;

    /// @notice True for every clone this factory has deployed. Used by
    ///         {notifyForfeit} to verify that the caller is one of our vests.
    mapping(address => bool) public isVest;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event VestCreated(
        address indexed vest,
        address indexed beneficiary,
        uint256 totalAmount,
        uint64 startTimestamp,
        uint64 cliffDuration,
        uint64 linearVestDuration,
        bool prePaid,
        bool terminationDisclosed
    );

    event VestTerminated(
        address indexed vest,
        bytes32 proposalRef,
        bytes32 groundsHash,
        uint256 unvestedAmount,
        uint64 endedAt
    );

    event VestForfeited(address indexed vest, uint256 unvestedAmount, uint64 endedAt);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error InvalidDuration();
    error InvalidImplementation();
    error NotRegisteredVest();
    error RenounceDisabled();
    error PastCliff();
    error DeadlineExceeded();
    error InsufficientUnvested();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /**
     * @param implementation_     Pre-deployed BLOKCVestingWallet logic contract.
     * @param token_              $BLOKC token address.
     * @param treasury_           DAO treasury — source of vest funding, sink
     *                            for unvested tokens on termination/forfeit.
     * @param governance_         Aragon DAO executor; becomes the factory's owner.
     * @param cliffDuration_      Cliff seconds applied to every vest.
     * @param linearVestDuration_ Linear-vest seconds applied to every vest.
     */
    constructor(
        address implementation_,
        address token_,
        address treasury_,
        address governance_,
        uint64 cliffDuration_,
        uint64 linearVestDuration_
    ) Ownable(governance_) {
        if (implementation_ == address(0)) revert ZeroAddress();
        if (token_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (governance_ == address(0)) revert ZeroAddress();
        if (linearVestDuration_ == 0) revert InvalidDuration();
        if (implementation_.code.length == 0) revert InvalidImplementation();

        implementation = implementation_;
        token = token_;
        treasury = treasury_;
        cliffDuration = cliffDuration_;
        linearVestDuration = linearVestDuration_;
    }

    // ---------------------------------------------------------------------
    // createVest — owner only
    // ---------------------------------------------------------------------

    /// @notice Deploy a new vest as a minimal-proxy clone, atomically pulling
    ///         `totalAmount` $BLOKC from the treasury into the new clone and
    ///         initializing it with the factory's immutable schedule plus the
    ///         supplied flags. The treasury must have approved this factory
    ///         for at least `totalAmount` before calling.
    function createVest(
        address beneficiary,
        uint256 totalAmount,
        uint64 startTimestamp,
        bool prePaid,
        bool terminationDisclosed
    ) external onlyOwner returns (address vest) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();

        vest = Clones.clone(implementation);

        // Move tokens into the clone before initialize. The clone's delegate()
        // call inside initialize will register the (already-present) balance
        // as voting power for the beneficiary at the next checkpoint.
        IERC20(token).safeTransferFrom(treasury, vest, totalAmount);

        BLOKCVestingWallet(payable(vest))
            .initialize(
                address(this),
                token,
                treasury,
                beneficiary,
                startTimestamp,
                cliffDuration,
                linearVestDuration,
                prePaid,
                terminationDisclosed,
                totalAmount
            );

        // Verify initialize wrote the expected state; catches no-code / no-op implementations.
        {
            BLOKCVestingWallet w = BLOKCVestingWallet(payable(vest));
            if (w.factory() != address(this) || w.token() != token || w.treasury() != treasury || w.totalAtStart() != totalAmount)
                revert InvalidImplementation();
        }

        allVests.push(vest);
        _vestsByBeneficiary[beneficiary].push(vest);
        isVest[vest] = true;

        emit VestCreated(vest, beneficiary, totalAmount, startTimestamp, cliffDuration, linearVestDuration, prePaid, terminationDisclosed);
    }

    // ---------------------------------------------------------------------
    // terminateVest — owner only
    // ---------------------------------------------------------------------

    /// @notice Terminate a single vest under a specific Aragon proposal.
    ///         The wallet enforces:
    ///           - investor (prePaid) vests revert unconditionally
    ///           - vests where terminationDisclosed == false revert
    ///           - already-ended vests revert
    ///           - fully matured vests revert (AlreadyMatured)
    /// @param vest         Address of the BLOKCVestingWallet clone.
    /// @param proposalRef  Aragon proposal hash that authorised this call.
    /// @param groundsHash  keccak of the published grounds text.
    function terminateVest(address vest, bytes32 proposalRef, bytes32 groundsHash) external onlyOwner {
        BLOKCVestingWallet w = BLOKCVestingWallet(payable(vest));
        w.terminate(proposalRef, groundsHash);
        uint64 endTime = w.endedAt();
        uint256 unvested = w.totalAtStart() - w.vestedAmount(token, endTime);
        emit VestTerminated(vest, proposalRef, groundsHash, unvested, endTime);
    }

    /// @notice Guarded variant of {terminateVest} that enforces pre-cliff
    ///         timing, an execution deadline, and a minimum unvested floor.
    ///         Useful when governance wants to guarantee the termination
    ///         occurs before the cliff tranche unlocks.
    /// @param vest            Address of the BLOKCVestingWallet clone.
    /// @param proposalRef     Aragon proposal hash that authorised this call.
    /// @param groundsHash     keccak of the published grounds text.
    /// @param minUnvested     Minimum unvested tokens required at execution time.
    /// @param requirePrecliff If true, revert when block.timestamp >= cliff().
    /// @param notAfter        If non-zero, revert when block.timestamp > notAfter.
    function terminateVestGuarded(
        address vest,
        bytes32 proposalRef,
        bytes32 groundsHash,
        uint256 minUnvested,
        bool requirePrecliff,
        uint64 notAfter
    ) external onlyOwner {
        BLOKCVestingWallet w = BLOKCVestingWallet(payable(vest));
        if (requirePrecliff && block.timestamp >= w.cliff()) revert PastCliff();
        if (notAfter != 0 && block.timestamp > notAfter) revert DeadlineExceeded();
        uint256 unvested = w.totalAtStart() - w.vestedAmount(token, uint64(block.timestamp));
        if (unvested < minUnvested) revert InsufficientUnvested();
        w.terminate(proposalRef, groundsHash);
        uint64 endTime = w.endedAt();
        emit VestTerminated(vest, proposalRef, groundsHash, unvested, endTime);
    }

    // ---------------------------------------------------------------------
    // notifyForfeit — registered vests only
    // ---------------------------------------------------------------------

    /// @notice Callback used by {BLOKCVestingWallet.forfeit} so the factory
    ///         emits a single-source-of-truth event for the dashboard /
    ///         indexer. msg.sender must be a clone deployed by this factory.
    function notifyForfeit(uint256 unvestedAmount) external {
        if (!isVest[msg.sender]) revert NotRegisteredVest();
        uint64 endTime = BLOKCVestingWallet(payable(msg.sender)).endedAt();
        emit VestForfeited(msg.sender, unvestedAmount, endTime);
    }

    // ---------------------------------------------------------------------
    // Renounce permanently disabled
    // ---------------------------------------------------------------------

    /// @notice Renouncing would leave the system unable to create or
    ///         terminate vests. Permanently disabled.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------

    function totalVests() external view returns (uint256) {
        return allVests.length;
    }

    function getVestsByBeneficiary(address beneficiary) external view returns (address[] memory) {
        return _vestsByBeneficiary[beneficiary];
    }

    /// @notice Sum of {BLOKCVestingWallet.unclaimedAllocation} across every
    ///         vest registered to `user` at creation. Combined with
    ///         IERC20(token).balanceOf(user) this is the BCIP-001 voting
    ///         weight: wallet balance + unclaimed allocation across vests.
    ///
    ///         O(n) external calls in n = vests held by the user. Intended
    ///         for off-chain consumption (eth_call) and Aragon snapshot
    ///         calculations. On-chain consumers that call this every block
    ///         should bound `n` or maintain their own cache, otherwise gas
    ///         scales linearly with the user's vest count.
    function unclaimedAllocation(address user) external view returns (uint256 total) {
        address[] storage vests = _vestsByBeneficiary[user];
        uint256 n = vests.length;
        for (uint256 i; i < n; ++i) {
            total += BLOKCVestingWallet(payable(vests[i])).unclaimedAllocation();
        }
    }
}

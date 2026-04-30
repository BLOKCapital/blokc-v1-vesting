// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
 *         createVest / terminateVest{,s} can only be called by passing a
 *         governance proposal on the Blok Capital DAO.
 *
 *         Holds no state beyond the registry of created vests and the
 *         immutable token / treasury / implementation pointers. The factory
 *         has no ability to amend vests, override the contract-level
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

    // ---------------------------------------------------------------------
    // Registry
    // ---------------------------------------------------------------------

    address[] public allVests;
    mapping(address => address[]) internal _vestsByBeneficiary;

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

    event VestTerminated(address indexed vest, bytes32 proposalRef);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error EmptyBatch();
    error RenounceDisabled();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /**
     * @param implementation_ Pre-deployed BLOKCVestingWallet logic contract.
     * @param token_          $BLOKC token address.
     * @param treasury_       DAO treasury — source of vest funding, sink for
     *                        unvested tokens on termination/forfeit.
     * @param governance_     Aragon DAO executor; becomes the factory's owner.
     */
    constructor(
        address implementation_,
        address token_,
        address treasury_,
        address governance_
    ) Ownable(governance_) {
        if (implementation_ == address(0)) revert ZeroAddress();
        if (token_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (governance_ == address(0)) revert ZeroAddress();

        implementation = implementation_;
        token = token_;
        treasury = treasury_;
    }

    // ---------------------------------------------------------------------
    // createVest
    // ---------------------------------------------------------------------

    /// @notice Deploy a new vest as a minimal-proxy clone, atomically pulling
    ///         `totalAmount` $BLOKC from the treasury into the new clone and
    ///         initializing it with the supplied schedule and flags.
    ///         The treasury must have approved this factory for at least
    ///         `totalAmount` before calling.
    function createVest(
        address beneficiary,
        uint256 totalAmount,
        uint64 startTimestamp,
        uint64 cliffDuration,
        uint64 linearVestDuration,
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

        BLOKCVestingWallet(payable(vest)).initialize(
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

        allVests.push(vest);
        _vestsByBeneficiary[beneficiary].push(vest);

        emit VestCreated(
            vest,
            beneficiary,
            totalAmount,
            startTimestamp,
            cliffDuration,
            linearVestDuration,
            prePaid,
            terminationDisclosed
        );
    }

    // ---------------------------------------------------------------------
    // terminateVest / terminateVests
    // ---------------------------------------------------------------------

    /// @notice Terminate a single vest under a specific Aragon proposal.
    ///         The wallet enforces:
    ///           - investor (prePaid) vests revert unconditionally
    ///           - vests where terminationDisclosed == false revert
    ///           - already-ended vests revert
    function terminateVest(address vest, bytes32 proposalRef) external onlyOwner {
        BLOKCVestingWallet(payable(vest)).terminate(proposalRef);
        emit VestTerminated(vest, proposalRef);
    }

    /// @notice Batch-terminate multiple vests under one proposal. Any
    ///         single-vest revert reverts the whole batch — callers should
    ///         pre-filter eligible vests via the registry views.
    function terminateVests(address[] calldata vests, bytes32 proposalRef) external onlyOwner {
        uint256 n = vests.length;
        if (n == 0) revert EmptyBatch();
        for (uint256 i; i < n; ++i) {
            BLOKCVestingWallet(payable(vests[i])).terminate(proposalRef);
            emit VestTerminated(vests[i], proposalRef);
        }
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

    function getVestsByBeneficiary(
        address beneficiary
    ) external view returns (address[] memory) {
        return _vestsByBeneficiary[beneficiary];
    }

    /// @notice Sum of {BLOKCVestingWallet.unclaimedAllocation} across every
    ///         vest registered to `user` at creation. Combined with
    ///         IERC20(token).balanceOf(user) this is the BCIP-001 voting
    ///         weight: wallet balance + unclaimed allocation across vests.
    function unclaimedAllocation(address user) external view returns (uint256 total) {
        address[] storage vests = _vestsByBeneficiary[user];
        uint256 n = vests.length;
        for (uint256 i; i < n; ++i) {
            total += BLOKCVestingWallet(payable(vests[i])).unclaimedAllocation();
        }
    }
}

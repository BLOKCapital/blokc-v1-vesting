// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VestingWalletUpgradeable} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletUpgradeable.sol";
import {VestingWalletCliffUpgradeable} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletCliffUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title BLOKCVestingWallet
 * @author BLOK Capital
 * @notice Per-vest contract holding $BLOKC for a single beneficiary. Implements
 *         BCIP-001: cliff-then-linear schedule, prePaid flag separating builder
 *         from investor vests, terminationDisclosed gate on DAO termination,
 *         voluntary forfeiture, and day-one voting power via IVotes delegation.
 *
 *         Deployed as an EIP-1167 minimal proxy clone by BLOKCVestingFactory.
 *         The factory is the only authorized caller of {terminate}.
 */
contract BLOKCVestingWallet is VestingWalletCliffUpgradeable {
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

    event Terminated(uint256 unvestedReturnedToTreasury, uint64 endedAt, bytes32 proposalRef);
    event Forfeited(uint256 unvestedReturnedToTreasury, uint64 endedAt);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotBeneficiary();
    error NotFactory();
    error InvestorVestNonTerminable();
    error TerminationNotDisclosed();
    error AlreadyEnded();
    error ZeroAddress();
    error InvalidDuration();
    error RenounceDisabled();
    error OwnershipTransferDisabled();

    // ---------------------------------------------------------------------
    // Constructor — disables initializers on the implementation contract
    // ---------------------------------------------------------------------

    constructor() {
        _disableInitializers();
    }

    // ---------------------------------------------------------------------
    // Initialization (called by the factory after cloning)
    // ---------------------------------------------------------------------

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
    function vestedAmount(
        address tkn,
        uint64 timestamp
    ) public view virtual override returns (uint256) {
        if (tkn != token) return 0;
        uint64 effective = ended && timestamp > endedAt ? endedAt : timestamp;
        return _vestingSchedule(totalAtStart, effective);
    }

    /// @notice BCIP-001 curve: 0 before cliff(); linear from 0 at the cliff
    ///         end to {totalAllocation} at start() + duration().
    ///         Diverges from OZ VestingWalletCliffUpgradeable, which jumps to
    ///         `totalAllocation * cliff / duration` at the cliff moment.
    function _vestingSchedule(
        uint256 totalAllocation,
        uint64 timestamp
    ) internal view virtual override returns (uint256) {
        uint64 cliffEnd = uint64(cliff());
        uint64 vestEnd = uint64(start() + duration());

        if (timestamp < cliffEnd) {
            return 0;
        } else if (timestamp >= vestEnd) {
            return totalAllocation;
        } else {
            return (totalAllocation * (timestamp - cliffEnd)) / (vestEnd - cliffEnd);
        }
    }

    // ---------------------------------------------------------------------
    // Termination
    // ---------------------------------------------------------------------

    /// @notice End the vest by DAO action. Returns the unvested portion to
    ///         the treasury; already-vested tokens remain claimable by the
    ///         beneficiary via {release}. Reverts unconditionally for
    ///         investor (prePaid) vests — the contract-level protection
    ///         promised in BCIP-001.
    function terminate(bytes32 proposalRef) external onlyFactory {
        if (prePaid) revert InvestorVestNonTerminable();
        if (!terminationDisclosed) revert TerminationNotDisclosed();
        if (ended) revert AlreadyEnded();

        uint64 endTime = uint64(block.timestamp);
        ended = true;
        endedAt = endTime;

        uint256 vested = _vestingSchedule(totalAtStart, endTime);
        uint256 unvested = totalAtStart - vested;

        if (unvested > 0) {
            IERC20(token).safeTransfer(treasury, unvested);
        }

        emit Terminated(unvested, endTime, proposalRef);
    }

    // ---------------------------------------------------------------------
    // Voluntary forfeit — beneficiary initiated
    // ---------------------------------------------------------------------

    /// @notice Beneficiary-initiated end of the vest. Pre-cliff: full
    ///         allocation returns to treasury. Post-cliff: vested portion
    ///         remains claimable, unvested returns to treasury.
    function forfeit() external onlyBeneficiary {
        if (ended) revert AlreadyEnded();

        uint64 endTime = uint64(block.timestamp);
        ended = true;
        endedAt = endTime;

        uint256 vested = _vestingSchedule(totalAtStart, endTime);
        uint256 unvested = totalAtStart - vested;

        if (unvested > 0) {
            IERC20(token).safeTransfer(treasury, unvested);
        }

        emit Forfeited(unvested, endTime);
    }

    // ---------------------------------------------------------------------
    // Ownership controls
    // ---------------------------------------------------------------------

    /// @notice Renouncing would orphan vested-but-unclaimed tokens and kill
    ///         the IVotes delegation. Permanently disabled.
    function renounceOwnership() public view override onlyBeneficiary {
        revert RenounceDisabled();
    }

    /// @notice A vest is bound to its original beneficiary; rotating
    ///         addresses is not supported. Keeps the factory's
    ///         `_vestsByBeneficiary` registry authoritative.
    function transferOwnership(address) public view override onlyBeneficiary {
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

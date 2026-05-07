// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {BLOKCVestingFactory} from "../../src/BLOKCVestingFactory.sol";
import {BLOKCVestingWallet} from "../../src/BLOKCVestingWallet.sol";
import {MockBLOKC} from "../utils/MockBLOKC.sol";

/// @notice Stateful handler for invariant testing. Each public function is a
///         random transition the fuzzer may invoke; modifiers narrow the
///         search space to actor-shaped sequences (governance creates and
///         terminates vests, beneficiaries claim and forfeit).
contract Handler is CommonBase, StdCheats, StdUtils {
    BLOKCVestingFactory public immutable factory;
    MockBLOKC public immutable token;
    address public immutable governance;
    address public immutable treasury;

    address[] public actors;
    address[] public createdVests;
    /// @dev Cumulative tokens minted to treasury for funding vests; used to
    ///      assert global conservation independently of treasury's pre-state.
    uint256 public totalFunded;

    /// @dev Sum of unvested tokens returned to treasury via terminate/forfeit.
    uint256 public totalReturnedToTreasury;
    /// @dev Sum of vested tokens released to beneficiaries.
    uint256 public totalReleased;

    constructor(BLOKCVestingFactory factory_, MockBLOKC token_, address governance_, address treasury_) {
        factory = factory_;
        token = token_;
        governance = governance_;
        treasury = treasury_;

        // Pre-allocate a small set of actors. The handler picks among them
        // for each call so the search concentrates on shared-state edge cases
        // (multiple vests per beneficiary, etc.) rather than a fresh address
        // every transition.
        for (uint256 i; i < 5; ++i) {
            actors.push(address(uint160(uint256(keccak256(abi.encode("actor", i))))));
        }
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickVest(uint256 seed) internal view returns (BLOKCVestingWallet) {
        if (createdVests.length == 0) return BLOKCVestingWallet(payable(address(0)));
        return BLOKCVestingWallet(payable(createdVests[seed % createdVests.length]));
    }

    // ---------------------------------------------------------------------
    // Transitions
    // ---------------------------------------------------------------------

    function createVest(uint256 actorSeed, uint96 amount, uint8 flagBits, uint32 startOffset) external {
        amount = uint96(bound(amount, 1, 10_000 ether));
        address beneficiary = _pickActor(actorSeed);
        bool prePaid = (flagBits & 1) != 0;
        bool disclosed = (flagBits & 2) != 0;
        uint64 startTs = uint64(block.timestamp + (startOffset % 30 days));

        // Top up the treasury so the safeTransferFrom inside createVest succeeds.
        token.mint(treasury, amount);
        totalFunded += amount;

        vm.prank(governance);
        try factory.createVest(beneficiary, amount, startTs, prePaid, disclosed) returns (address vest) {
            createdVests.push(vest);
        } catch {
            // No-op; bound() makes a revert unlikely but keep handler robust.
        }
    }

    function warp(uint64 secs) external {
        secs = uint64(bound(secs, 1, 30 days));
        vm.warp(block.timestamp + secs);
    }

    function release(uint256 vestSeed) external {
        BLOKCVestingWallet vest = _pickVest(vestSeed);
        if (address(vest) == address(0)) return;

        uint256 before = token.balanceOf(vest.owner());
        try vest.release(address(token)) {
            totalReleased += token.balanceOf(vest.owner()) - before;
        } catch {}
    }

    function terminate(uint256 vestSeed, bytes32 proposalRef, bytes32 groundsHash) external {
        BLOKCVestingWallet vest = _pickVest(vestSeed);
        if (address(vest) == address(0)) return;

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(governance);
        try factory.terminateVest(address(vest), proposalRef, groundsHash) {
            totalReturnedToTreasury += token.balanceOf(treasury) - treasuryBefore;
        } catch {}
    }

    function forfeit(uint256 vestSeed) external {
        BLOKCVestingWallet vest = _pickVest(vestSeed);
        if (address(vest) == address(0)) return;

        address ben = vest.owner();
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(ben);
        try vest.forfeit() {
            totalReturnedToTreasury += token.balanceOf(treasury) - treasuryBefore;
        } catch {}
    }

    // ---------------------------------------------------------------------
    // Views used by the invariant suite
    // ---------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function vestCount() external view returns (uint256) {
        return createdVests.length;
    }

    function vestAt(uint256 i) external view returns (address) {
        return createdVests[i];
    }
}

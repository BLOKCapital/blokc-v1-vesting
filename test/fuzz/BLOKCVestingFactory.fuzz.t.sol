// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {BaseTest} from "../utils/Base.t.sol";
import {BLOKCVestingFactory} from "../../src/BLOKCVestingFactory.sol";
import {BLOKCVestingWallet} from "../../src/BLOKCVestingWallet.sol";

/// @notice Property tests focused on factory-shaped state: registry
///         consistency, per-beneficiary segregation, and the aggregate
///         unclaimedAllocation view.
contract BLOKCVestingFactoryFuzz is BaseTest {
    /// @notice Every successful createVest grows allVests by exactly one,
    ///         records the new clone in isVest, and appends it to the
    ///         beneficiary's per-user list.
    function testFuzz_createVest_registryGrows(address beneficiary_, uint96 amount, uint32 startOffset, uint8 flagBits)
        public
    {
        vm.assume(beneficiary_ != address(0));
        vm.assume(beneficiary_.code.length == 0); // avoid OZ Ownable rejecting if we land on a contract that reverts on receive
        amount = uint96(bound(amount, 1, 100_000 ether));
        uint64 startTs = uint64(block.timestamp + (startOffset % 30 days));
        bool prePaid = (flagBits & 1) != 0;
        bool disclosed = (flagBits & 2) != 0;

        uint256 totalBefore = factory.totalVests();
        uint256 perBenBefore = factory.getVestsByBeneficiary(beneficiary_).length;

        vm.prank(governance);
        address vest = factory.createVest(beneficiary_, amount, startTs, prePaid, disclosed);

        assertEq(factory.totalVests(), totalBefore + 1);
        assertTrue(factory.isVest(vest));
        assertEq(factory.allVests(totalBefore), vest);

        address[] memory list = factory.getVestsByBeneficiary(beneficiary_);
        assertEq(list.length, perBenBefore + 1);
        assertEq(list[list.length - 1], vest);

        // Initialised with the factory's immutable schedule, regardless of the
        // flags / amount / start the caller chose.
        BLOKCVestingWallet w = BLOKCVestingWallet(payable(vest));
        assertEq(w.start(), startTs);
        assertEq(w.duration(), uint256(CLIFF) + LINEAR);
        assertEq(w.cliff(), uint256(startTs) + CLIFF);
        assertEq(w.totalAtStart(), amount);
        assertEq(w.owner(), beneficiary_);
    }

    /// @notice Per-beneficiary lists are disjoint: a vest created for A does
    ///         not appear in B's list and vice versa.
    function testFuzz_perBeneficiarySegregation(uint8 nA, uint8 nB) public {
        nA = uint8(bound(nA, 1, 5));
        nB = uint8(bound(nB, 1, 5));

        vm.startPrank(governance);
        for (uint8 i; i < nA; ++i) {
            factory.createVest(alice, 1 ether, uint64(block.timestamp), false, true);
        }
        for (uint8 i; i < nB; ++i) {
            factory.createVest(bob, 1 ether, uint64(block.timestamp), true, true);
        }
        vm.stopPrank();

        address[] memory aList = factory.getVestsByBeneficiary(alice);
        address[] memory bList = factory.getVestsByBeneficiary(bob);

        assertEq(aList.length, nA);
        assertEq(bList.length, nB);

        // No overlap.
        for (uint256 i; i < aList.length; ++i) {
            for (uint256 j; j < bList.length; ++j) {
                assertTrue(aList[i] != bList[j], "beneficiary lists overlap");
            }
        }

        // Total registry equals the sum.
        assertEq(factory.totalVests(), uint256(nA) + uint256(nB));
    }

    /// @notice Aggregate unclaimedAllocation = sum of per-vest unclaimedAllocation
    ///         for any user, at any time, regardless of releases / terminations.
    function testFuzz_unclaimedAllocation_aggregateMatchesSum(uint8 vestCount, uint256 elapsed, uint8 actionMask)
        public
    {
        vestCount = uint8(bound(vestCount, 1, 6));
        elapsed = bound(elapsed, 0, 2 * (uint256(CLIFF) + LINEAR));

        // Mint enough so multiple amounts can be drawn from the treasury.
        uint64 startTs = uint64(block.timestamp);
        vm.startPrank(governance);
        for (uint8 i; i < vestCount; ++i) {
            // Vary amount, prePaid flag (so terminate is sometimes a no-op)
            // and disclosure (so terminate is sometimes blocked).
            uint256 amount = uint256(i + 1) * 50 ether;
            bool prePaid = ((actionMask >> i) & 1) != 0;
            bool disclosed = ((actionMask >> (i + 4)) & 1) != 0;
            factory.createVest(beneficiary, amount, startTs, prePaid, disclosed);
        }
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);

        // Optionally release some vests and terminate the eligible ones.
        address[] memory list = factory.getVestsByBeneficiary(beneficiary);
        for (uint256 i; i < list.length; ++i) {
            BLOKCVestingWallet v = BLOKCVestingWallet(payable(list[i]));
            if (((actionMask >> i) & 1) != 0) {
                // best-effort release; harmless if claimable() == 0
                v.release(address(token));
            }
        }
        // Try to terminate a builder+disclosed vest; ignore reverts (investor / not disclosed).
        for (uint256 i; i < list.length; ++i) {
            BLOKCVestingWallet v = BLOKCVestingWallet(payable(list[i]));
            if (!v.prePaid() && v.isTerminationDisclosed() && !v.ended()) {
                vm.prank(governance);
                factory.terminateVest(address(v), bytes32("p"), bytes32("g"));
                break; // single termination is enough to exercise the ended branch
            }
        }

        uint256 expected;
        for (uint256 i; i < list.length; ++i) {
            expected += BLOKCVestingWallet(payable(list[i])).unclaimedAllocation();
        }
        assertEq(factory.unclaimedAllocation(beneficiary), expected);
    }

    /// @notice The factory itself never holds $BLOKC: createVest moves tokens
    ///         from the treasury straight into the clone.
    function testFuzz_factory_holdsNoTokens(uint96 amount, uint32 startOffset) public {
        amount = uint96(bound(amount, 1, 100_000 ether));
        uint64 startTs = uint64(block.timestamp + (startOffset % 30 days));

        vm.prank(governance);
        factory.createVest(alice, amount, startTs, false, true);

        assertEq(token.balanceOf(address(factory)), 0);
    }
}

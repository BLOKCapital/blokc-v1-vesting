// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {BaseTest} from "../utils/Base.t.sol";
import {BLOKCVestingWallet} from "../../src/BLOKCVestingWallet.sol";
import {BLOKCVestingFactory} from "../../src/BLOKCVestingFactory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract BLOKCVestingFactory_Constructor is BaseTest {
    function test_constructor_setsImmutables() public view {
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.token(), address(token));
        assertEq(factory.treasury(), treasury);
        assertEq(factory.owner(), governance);
        assertEq(factory.cliffDuration(), CLIFF);
        assertEq(factory.linearVestDuration(), LINEAR);
        assertEq(factory.totalVests(), 0);
    }

    function test_constructor_revertsOnZeroImpl() public {
        vm.expectRevert(BLOKCVestingFactory.ZeroAddress.selector);
        new BLOKCVestingFactory(address(0), address(token), treasury, governance, CLIFF, LINEAR);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(BLOKCVestingFactory.ZeroAddress.selector);
        new BLOKCVestingFactory(address(implementation), address(0), treasury, governance, CLIFF, LINEAR);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(BLOKCVestingFactory.ZeroAddress.selector);
        new BLOKCVestingFactory(address(implementation), address(token), address(0), governance, CLIFF, LINEAR);
    }

    function test_constructor_revertsOnZeroGovernance() public {
        // Ownable's own check fires before ours when governance == 0.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BLOKCVestingFactory(address(implementation), address(token), treasury, address(0), CLIFF, LINEAR);
    }

    function test_constructor_revertsOnZeroLinearDuration() public {
        vm.expectRevert(BLOKCVestingFactory.InvalidDuration.selector);
        new BLOKCVestingFactory(address(implementation), address(token), treasury, governance, CLIFF, 0);
    }

    function test_constructor_zeroCliffAllowed() public {
        BLOKCVestingFactory f = new BLOKCVestingFactory(
            address(implementation), address(token), treasury, governance, 0, LINEAR
        );
        assertEq(f.cliffDuration(), 0);
    }
}

contract BLOKCVestingFactory_CreateVest is BaseTest {
    function test_createVest_happyPath() public {
        uint64 startTs = uint64(block.timestamp);

        vm.expectEmit(false, true, false, true);
        emit BLOKCVestingFactory.VestCreated(address(0), beneficiary, DEFAULT_AMOUNT, startTs, false, true);

        vm.prank(governance);
        address vest = factory.createVest(beneficiary, DEFAULT_AMOUNT, startTs, false, true);

        // Registry
        assertEq(factory.totalVests(), 1);
        assertEq(factory.allVests(0), vest);
        assertTrue(factory.isVest(vest));
        address[] memory list = factory.getVestsByBeneficiary(beneficiary);
        assertEq(list.length, 1);
        assertEq(list[0], vest);

        // Funding moved from treasury into clone.
        assertEq(token.balanceOf(vest), DEFAULT_AMOUNT);
        assertEq(token.balanceOf(treasury), TREASURY_FUND - DEFAULT_AMOUNT);

        // Initialization plumbed correctly.
        BLOKCVestingWallet w = BLOKCVestingWallet(payable(vest));
        assertEq(w.factory(), address(factory));
        assertEq(w.token(), address(token));
        assertEq(w.treasury(), treasury);
        assertEq(w.owner(), beneficiary);
        assertEq(w.totalAtStart(), DEFAULT_AMOUNT);
        assertEq(w.start(), startTs);
        assertEq(w.duration(), uint256(CLIFF) + LINEAR);
        assertEq(w.cliff(), uint256(startTs) + CLIFF);
        assertEq(w.prePaid(), false);
        assertEq(w.terminationDisclosed(), true);

        // Day-one delegation: clone has voting power for the beneficiary.
        assertEq(token.delegates(vest), beneficiary);
        assertEq(token.getVotes(beneficiary), DEFAULT_AMOUNT);
    }

    function test_createVest_revertsWhenNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.createVest(beneficiary, DEFAULT_AMOUNT, uint64(block.timestamp), false, true);
    }

    function test_createVest_revertsOnZeroBeneficiary() public {
        vm.prank(governance);
        vm.expectRevert(BLOKCVestingFactory.ZeroAddress.selector);
        factory.createVest(address(0), DEFAULT_AMOUNT, uint64(block.timestamp), false, true);
    }

    function test_createVest_revertsOnZeroAmount() public {
        vm.prank(governance);
        vm.expectRevert(BLOKCVestingFactory.ZeroAmount.selector);
        factory.createVest(beneficiary, 0, uint64(block.timestamp), false, true);
    }

    function test_createVest_revertsWhenTreasuryNotApproved() public {
        // Drop the approval set in BaseTest.
        vm.prank(treasury);
        token.approve(address(factory), 0);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, DEFAULT_AMOUNT)
        );
        factory.createVest(beneficiary, DEFAULT_AMOUNT, uint64(block.timestamp), false, true);
    }

    function test_createVest_multipleVestsForSameBeneficiary() public {
        uint64 startTs = uint64(block.timestamp);
        vm.startPrank(governance);
        address v1 = factory.createVest(beneficiary, 100 ether, startTs, false, true);
        address v2 = factory.createVest(beneficiary, 200 ether, startTs, true, true);
        vm.stopPrank();

        assertEq(factory.totalVests(), 2);
        address[] memory list = factory.getVestsByBeneficiary(beneficiary);
        assertEq(list.length, 2);
        assertEq(list[0], v1);
        assertEq(list[1], v2);
    }

    function test_createVest_storesAllFlagPermutations() public {
        uint64 startTs = uint64(block.timestamp);
        bool[2] memory flags = [false, true];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                vm.prank(governance);
                address v = factory.createVest(beneficiary, 1 ether, startTs, flags[i], flags[j]);
                BLOKCVestingWallet w = BLOKCVestingWallet(payable(v));
                assertEq(w.prePaid(), flags[i]);
                assertEq(w.terminationDisclosed(), flags[j]);
            }
        }
    }
}

contract BLOKCVestingFactory_TerminateVest is BaseTest {
    BLOKCVestingWallet internal vest;

    function setUp() public override {
        super.setUp();
        vest = _defaultVest();
    }

    function test_terminateVest_revertsWhenNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.terminateVest(address(vest), bytes32("p"), bytes32("g"));
    }

    function test_terminateVest_emitsAndForwards() public {
        vm.warp(block.timestamp + CLIFF + LINEAR / 2);

        bytes32 proposalRef = keccak256("proposal");
        bytes32 groundsHash = keccak256("grounds");

        vm.expectEmit(true, false, false, true);
        emit BLOKCVestingFactory.VestTerminated(address(vest), proposalRef, groundsHash);

        vm.prank(governance);
        factory.terminateVest(address(vest), proposalRef, groundsHash);

        assertTrue(vest.ended());
        assertEq(vest.endedAt(), uint64(block.timestamp));
    }
}

contract BLOKCVestingFactory_NotifyForfeit is BaseTest {
    function test_notifyForfeit_revertsForUnregisteredCaller() public {
        vm.expectRevert(BLOKCVestingFactory.NotRegisteredVest.selector);
        factory.notifyForfeit(123);
    }

    function test_notifyForfeit_emittedFromForfeit() public {
        BLOKCVestingWallet vest = _defaultVest();
        vm.warp(block.timestamp + CLIFF + LINEAR / 4);

        vm.expectEmit(true, false, false, false);
        emit BLOKCVestingFactory.VestForfeited(address(vest), 0); // amount checked in wallet tests
        vm.prank(beneficiary);
        vest.forfeit();
    }
}

contract BLOKCVestingFactory_RenounceOwnership is BaseTest {
    function test_renounce_revertsForOwner() public {
        vm.prank(governance);
        vm.expectRevert(BLOKCVestingFactory.RenounceDisabled.selector);
        factory.renounceOwnership();
    }

    function test_renounce_revertsForNonOwnerWithUnauthorized() public {
        // onlyOwner runs first → OwnableUnauthorizedAccount, not RenounceDisabled.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.renounceOwnership();
    }
}

contract BLOKCVestingFactory_Ownable2Step is BaseTest {
    function test_transferAndAcceptOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(governance);
        factory.transferOwnership(newOwner);
        assertEq(factory.owner(), governance, "owner not yet rotated");
        assertEq(factory.pendingOwner(), newOwner);

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner);
        assertEq(factory.pendingOwner(), address(0));
    }
}

contract BLOKCVestingFactory_UnclaimedAllocation is BaseTest {
    function test_unclaimedAllocation_emptyForUnknownUser() public {
        address nobody = makeAddr("nobody");
        assertEq(factory.unclaimedAllocation(nobody), 0);
    }

    function test_unclaimedAllocation_sumsAllVests() public {
        uint64 startTs = uint64(block.timestamp);
        vm.startPrank(governance);
        factory.createVest(beneficiary, 100 ether, startTs, false, true);
        factory.createVest(beneficiary, 250 ether, startTs, true, false);
        vm.stopPrank();

        assertEq(factory.unclaimedAllocation(beneficiary), 350 ether);
    }

    function test_unclaimedAllocation_decreasesAfterRelease() public {
        BLOKCVestingWallet vest = _defaultVest();
        vm.warp(block.timestamp + CLIFF + LINEAR / 2); // ~62.5% vested

        uint256 expectedVested = vest.vested();
        vest.release(address(token));

        assertEq(factory.unclaimedAllocation(beneficiary), DEFAULT_AMOUNT - expectedVested);
    }
}

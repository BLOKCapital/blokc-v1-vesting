// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {BaseTest} from "../utils/Base.t.sol";
import {BLOKCVestingWallet} from "../../src/BLOKCVestingWallet.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {
    VestingWalletCliffUpgradeable
} from "@openzeppelin/contracts-upgradeable/finance/VestingWalletCliffUpgradeable.sol";

contract BLOKCVestingWallet_Constructor is BaseTest {
    function test_implementation_initializerDisabled() public {
        BLOKCVestingWallet impl = new BLOKCVestingWallet();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            address(factory),
            address(token),
            treasury,
            beneficiary,
            uint64(block.timestamp),
            CLIFF,
            LINEAR,
            false,
            true,
            DEFAULT_AMOUNT
        );
    }
}

contract BLOKCVestingWallet_Initialize is BaseTest {
    function test_initialize_doubleInitReverts() public {
        BLOKCVestingWallet vest = _defaultVest();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vest.initialize(
            address(factory),
            address(token),
            treasury,
            beneficiary,
            uint64(block.timestamp),
            CLIFF,
            LINEAR,
            false,
            true,
            DEFAULT_AMOUNT
        );
    }

    // The factory injects validated args, but initialize is `external` and a
    // future caller (e.g., a misconfigured factory) could feed garbage. Cover
    // every guard directly via Clones.clone.
    function _fresh() internal returns (BLOKCVestingWallet) {
        return BLOKCVestingWallet(payable(Clones.clone(address(implementation))));
    }

    function _init(
        BLOKCVestingWallet vest,
        address factory_,
        address token_,
        address treasury_,
        address beneficiary_,
        uint64 cliff_,
        uint64 linear_
    ) internal {
        vest.initialize(
            factory_, token_, treasury_, beneficiary_, uint64(block.timestamp), cliff_, linear_, false, true, 1 ether
        );
    }

    function test_initialize_revertsOnZeroFactory() public {
        BLOKCVestingWallet vest = _fresh();
        vm.expectRevert(BLOKCVestingWallet.ZeroAddress.selector);
        _init(vest, address(0), address(token), treasury, beneficiary, CLIFF, LINEAR);
    }

    function test_initialize_revertsOnZeroToken() public {
        BLOKCVestingWallet vest = _fresh();
        vm.expectRevert(BLOKCVestingWallet.ZeroAddress.selector);
        _init(vest, address(factory), address(0), treasury, beneficiary, CLIFF, LINEAR);
    }

    function test_initialize_revertsOnZeroTreasury() public {
        BLOKCVestingWallet vest = _fresh();
        vm.expectRevert(BLOKCVestingWallet.ZeroAddress.selector);
        _init(vest, address(factory), address(token), address(0), beneficiary, CLIFF, LINEAR);
    }

    function test_initialize_revertsOnZeroBeneficiary() public {
        BLOKCVestingWallet vest = _fresh();
        vm.expectRevert(BLOKCVestingWallet.ZeroAddress.selector);
        _init(vest, address(factory), address(token), treasury, address(0), CLIFF, LINEAR);
    }

    function test_initialize_revertsOnZeroLinearDuration() public {
        BLOKCVestingWallet vest = _fresh();
        vm.expectRevert(BLOKCVestingWallet.InvalidDuration.selector);
        _init(vest, address(factory), address(token), treasury, beneficiary, CLIFF, 0);
    }
}

contract BLOKCVestingWallet_Schedule is BaseTest {
    BLOKCVestingWallet internal vest;
    uint64 internal startTs;

    function setUp() public override {
        super.setUp();
        startTs = uint64(block.timestamp);
        vest = _defaultVest();
    }

    function test_vestedAmount_zeroForUnknownToken() public view {
        assertEq(vest.vestedAmount(address(0xdead), uint64(block.timestamp + CLIFF + LINEAR)), 0);
    }

    function test_vestedAmount_zeroBeforeCliff() public {
        // Right before cliff end → still 0.
        vm.warp(startTs + CLIFF - 1);
        assertEq(vest.vested(), 0);
        assertEq(vest.claimable(), 0);
    }

    function test_vestedAmount_atCliff_unlocksProportional() public {
        // OZ cliff curve: at cliff end, unlock = total * cliff / duration.
        vm.warp(startTs + CLIFF);
        uint256 expected = (DEFAULT_AMOUNT * CLIFF) / (uint256(CLIFF) + LINEAR);
        assertEq(vest.vested(), expected);
    }

    function test_vestedAmount_linearMidway() public {
        vm.warp(startTs + CLIFF + LINEAR / 2);
        uint256 expected = (DEFAULT_AMOUNT * (uint256(CLIFF) + LINEAR / 2)) / (uint256(CLIFF) + LINEAR);
        assertEq(vest.vested(), expected);
    }

    function test_vestedAmount_atEnd_total() public {
        vm.warp(startTs + CLIFF + LINEAR);
        assertEq(vest.vested(), DEFAULT_AMOUNT);
    }

    function test_vestedAmount_pastEnd_capped() public {
        vm.warp(startTs + CLIFF + LINEAR + 365 days);
        assertEq(vest.vested(), DEFAULT_AMOUNT);
    }

    function test_vestedAmount_freezeAtEndedAt() public {
        vm.warp(startTs + CLIFF + LINEAR / 2);
        uint256 vestedAtTermination = vest.vested();
        vm.prank(governance);
        factory.terminateVest(address(vest), bytes32("p"), bytes32("g"));

        // Roll forward; vestedAmount must stay frozen at endedAt.
        vm.warp(block.timestamp + 365 days);
        assertEq(vest.vested(), vestedAtTermination);
    }

    function test_vestedAmount_zeroEthFunctionAlwaysZero() public view {
        assertEq(vest.vestedAmount(uint64(block.timestamp + CLIFF + LINEAR)), 0);
    }
}

contract BLOKCVestingWallet_Terminate is BaseTest {
    BLOKCVestingWallet internal vest;
    uint64 internal startTs;

    function setUp() public override {
        super.setUp();
        startTs = uint64(block.timestamp);
        vest = _defaultVest(); // builder, terminationDisclosed=true
    }

    function test_terminate_onlyFactory() public {
        vm.expectRevert(BLOKCVestingWallet.NotFactory.selector);
        vest.terminate(bytes32("p"), bytes32("g"));
    }

    function test_terminate_revertsOnInvestorVest() public {
        BLOKCVestingWallet inv = _createVest(alice, DEFAULT_AMOUNT, startTs, true, true);
        vm.prank(governance);
        vm.expectRevert(BLOKCVestingWallet.InvestorVestNonTerminable.selector);
        factory.terminateVest(address(inv), bytes32("p"), bytes32("g"));
    }

    function test_terminate_revertsWhenNotDisclosed() public {
        BLOKCVestingWallet hidden = _createVest(alice, DEFAULT_AMOUNT, startTs, false, false);
        vm.prank(governance);
        vm.expectRevert(BLOKCVestingWallet.TerminationNotDisclosed.selector);
        factory.terminateVest(address(hidden), bytes32("p"), bytes32("g"));
    }

    function test_terminate_revertsAlreadyEnded() public {
        vm.warp(startTs + CLIFF);
        vm.prank(governance);
        factory.terminateVest(address(vest), bytes32("p"), bytes32("g"));

        vm.prank(governance);
        vm.expectRevert(BLOKCVestingWallet.AlreadyEnded.selector);
        factory.terminateVest(address(vest), bytes32("p2"), bytes32("g2"));
    }

    function test_terminate_revertsAlreadyMatured() public {
        vm.warp(startTs + CLIFF + LINEAR);
        vm.prank(governance);
        vm.expectRevert(BLOKCVestingWallet.AlreadyMatured.selector);
        factory.terminateVest(address(vest), bytes32("p"), bytes32("g"));
    }

    function test_terminate_preCliff_returnsAllToTreasury() public {
        // Terminate before cliff; treasury gets the full balance back.
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.expectEmit(true, true, true, true, address(vest));
        emit BLOKCVestingWallet.Terminated(DEFAULT_AMOUNT, uint64(block.timestamp), bytes32("p"), bytes32("g"));

        vm.prank(governance);
        factory.terminateVest(address(vest), bytes32("p"), bytes32("g"));

        assertEq(token.balanceOf(treasury), treasuryBefore + DEFAULT_AMOUNT);
        assertEq(token.balanceOf(address(vest)), 0);
        assertEq(vest.claimable(), 0);
        assertTrue(vest.ended());
        assertEq(vest.endedAt(), uint64(block.timestamp));
    }

    function test_terminate_midSchedule_splitsCorrectly() public {
        vm.warp(startTs + CLIFF + LINEAR / 2);
        uint256 vestedNow = vest.vested();
        uint256 unvested = DEFAULT_AMOUNT - vestedNow;
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(governance);
        factory.terminateVest(address(vest), bytes32("p"), bytes32("g"));

        // Treasury reclaimed unvested portion.
        assertEq(token.balanceOf(treasury), treasuryBefore + unvested);
        // Wallet retains the still-claimable vested portion.
        assertEq(token.balanceOf(address(vest)), vestedNow);
        assertEq(vest.claimable(), vestedNow);
    }

    function test_terminate_thenReleaseStillWorks() public {
        vm.warp(startTs + CLIFF + LINEAR / 4);
        vm.prank(governance);
        factory.terminateVest(address(vest), bytes32("p"), bytes32("g"));

        uint256 vestedFrozen = vest.vested();
        vm.warp(block.timestamp + 365 days);
        assertEq(vest.claimable(), vestedFrozen);

        uint256 benBefore = token.balanceOf(beneficiary);
        vest.release(address(token));
        assertEq(token.balanceOf(beneficiary), benBefore + vestedFrozen);
        assertEq(vest.claimable(), 0);
    }
}

contract BLOKCVestingWallet_Forfeit is BaseTest {
    BLOKCVestingWallet internal vest;
    uint64 internal startTs;

    function setUp() public override {
        super.setUp();
        startTs = uint64(block.timestamp);
        vest = _defaultVest();
    }

    function test_forfeit_onlyBeneficiary() public {
        vm.expectRevert(BLOKCVestingWallet.NotBeneficiary.selector);
        vm.prank(alice);
        vest.forfeit();
    }

    function test_forfeit_revertsForInvestorVest() public {
        BLOKCVestingWallet inv = _createVest(alice, DEFAULT_AMOUNT, startTs, true, true);
        vm.expectRevert(BLOKCVestingWallet.InvestorVestNonForfeitable.selector);
        vm.prank(alice);
        inv.forfeit();
    }

    function test_forfeit_revertsAlreadyMatured() public {
        vm.warp(startTs + CLIFF + LINEAR);
        vm.expectRevert(BLOKCVestingWallet.AlreadyMatured.selector);
        vm.prank(beneficiary);
        vest.forfeit();
    }

    function test_forfeit_preCliff_returnsAllToTreasury() public {
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.expectEmit(true, true, true, true, address(vest));
        emit BLOKCVestingWallet.Forfeited(DEFAULT_AMOUNT, uint64(block.timestamp));

        vm.prank(beneficiary);
        vest.forfeit();

        assertEq(token.balanceOf(treasury), treasuryBefore + DEFAULT_AMOUNT);
        assertEq(token.balanceOf(address(vest)), 0);
        assertTrue(vest.ended());
        assertEq(vest.endedAt(), uint64(block.timestamp));
    }

    function test_forfeit_postCliff_keepsVestedClaimable() public {
        vm.warp(startTs + CLIFF + LINEAR / 3);
        uint256 vestedNow = vest.vested();
        uint256 unvested = DEFAULT_AMOUNT - vestedNow;
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(beneficiary);
        vest.forfeit();

        assertEq(token.balanceOf(treasury), treasuryBefore + unvested);
        assertEq(token.balanceOf(address(vest)), vestedNow);
        assertEq(vest.claimable(), vestedNow);
    }

    function test_forfeit_revertsAlreadyEnded() public {
        vm.prank(beneficiary);
        vest.forfeit();

        vm.expectRevert(BLOKCVestingWallet.AlreadyEnded.selector);
        vm.prank(beneficiary);
        vest.forfeit();
    }

    function test_forfeit_emitsFactoryNotification() public {
        uint64 warpTo = startTs + CLIFF + LINEAR / 2;
        vm.warp(warpTo);
        uint256 unvested = DEFAULT_AMOUNT - vest.vested();

        vm.expectEmit(true, false, false, true, address(factory));
        emit BLOKCVestingWalletFactoryEvent.VestForfeited(address(vest), unvested, warpTo);
        vm.prank(beneficiary);
        vest.forfeit();
    }
}

/// @dev Trampoline for cross-contract event signature lookup.
interface BLOKCVestingWalletFactoryEvent {
    event VestForfeited(address indexed vest, uint256 unvestedAmount, uint64 endedAt);
}

contract BLOKCVestingWallet_Release is BaseTest {
    BLOKCVestingWallet internal vest;
    uint64 internal startTs;

    function setUp() public override {
        super.setUp();
        startTs = uint64(block.timestamp);
        vest = _defaultVest();
    }

    function test_release_zeroBeforeCliff() public {
        uint256 benBefore = token.balanceOf(beneficiary);
        vest.release(address(token));
        assertEq(token.balanceOf(beneficiary), benBefore);
        assertEq(vest.released(address(token)), 0);
    }

    function test_release_partial_thenRest() public {
        vm.warp(startTs + CLIFF + LINEAR / 2);
        uint256 firstClaim = vest.claimable();
        uint256 benBefore = token.balanceOf(beneficiary);

        vest.release(address(token));
        assertEq(token.balanceOf(beneficiary), benBefore + firstClaim);
        assertEq(vest.released(address(token)), firstClaim);
        assertEq(vest.claimable(), 0);

        vm.warp(startTs + CLIFF + LINEAR);
        assertEq(vest.claimable(), DEFAULT_AMOUNT - firstClaim);
        vest.release(address(token));
        assertEq(token.balanceOf(beneficiary), DEFAULT_AMOUNT);
    }

    function test_release_callableByAnyone_paysOwner() public {
        vm.warp(startTs + CLIFF + LINEAR);

        vm.prank(alice);
        vest.release(address(token));
        assertEq(token.balanceOf(beneficiary), DEFAULT_AMOUNT);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_release_noArg_routesToERC20() public {
        // Before cliff: no-arg release should not revert and releases 0.
        uint256 benBefore = token.balanceOf(beneficiary);
        vest.release();
        assertEq(token.balanceOf(beneficiary), benBefore);

        // After full vesting: releases all.
        vm.warp(startTs + CLIFF + LINEAR);
        vest.release();
        assertEq(token.balanceOf(beneficiary), DEFAULT_AMOUNT);
    }

    function test_releasable_noArg_returnsERC20Amount() public {
        assertEq(vest.releasable(), 0);
        vm.warp(startTs + CLIFF + LINEAR);
        assertEq(vest.releasable(), DEFAULT_AMOUNT);
    }

    function test_released_noArg_returnsERC20Amount() public {
        vm.warp(startTs + CLIFF + LINEAR / 2);
        uint256 amount = vest.claimable();
        vest.release(address(token));
        assertEq(vest.released(), amount);
    }

    function test_receive_revertsOnEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vest).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(vest).balance, 0);
    }
}

contract BLOKCVestingWallet_UpdateDelegate is BaseTest {
    BLOKCVestingWallet internal vest;

    function setUp() public override {
        super.setUp();
        vest = _defaultVest();
    }

    function test_updateDelegate_onlyBeneficiary() public {
        vm.expectRevert(BLOKCVestingWallet.NotBeneficiary.selector);
        vm.prank(alice);
        vest.updateDelegate(alice);
    }

    function test_updateDelegate_revertsOnZeroAddress() public {
        vm.prank(beneficiary);
        vm.expectRevert(BLOKCVestingWallet.ZeroAddress.selector);
        vest.updateDelegate(address(0));
    }

    function test_updateDelegate_changesDelegate() public {
        assertEq(token.delegates(address(vest)), beneficiary);

        vm.expectEmit(true, true, false, false, address(vest));
        emit BLOKCVestingWallet.DelegateUpdated(beneficiary, alice);

        vm.prank(beneficiary);
        vest.updateDelegate(alice);

        assertEq(token.delegates(address(vest)), alice);
        assertEq(token.getVotes(alice), DEFAULT_AMOUNT);
        assertEq(token.getVotes(beneficiary), 0);
    }
}

contract BLOKCVestingWallet_Ownership is BaseTest {
    BLOKCVestingWallet internal vest;

    function setUp() public override {
        super.setUp();
        vest = _defaultVest();
    }

    function test_renounce_disabled() public {
        vm.prank(beneficiary);
        vm.expectRevert(BLOKCVestingWallet.RenounceDisabled.selector);
        vest.renounceOwnership();
    }

    function test_renounce_disabled_evenForNonOwner() public {
        // Override is `view`, no onlyOwner — same revert regardless of caller.
        vm.expectRevert(BLOKCVestingWallet.RenounceDisabled.selector);
        vest.renounceOwnership();
    }

    function test_transferOwnership_disabled() public {
        vm.prank(beneficiary);
        vm.expectRevert(BLOKCVestingWallet.OwnershipTransferDisabled.selector);
        vest.transferOwnership(alice);
    }
}

contract BLOKCVestingWallet_Views is BaseTest {
    BLOKCVestingWallet internal vest;
    uint64 internal startTs;

    function setUp() public override {
        super.setUp();
        startTs = uint64(block.timestamp);
        vest = _defaultVest();
    }

    function test_isTerminationDisclosed_reflectsFlag() public {
        BLOKCVestingWallet hidden = _createVest(alice, 1 ether, startTs, false, false);
        assertTrue(vest.isTerminationDisclosed());
        assertFalse(hidden.isTerminationDisclosed());
    }

    function test_unclaimedAllocation_beforeAnyAction() public view {
        assertEq(vest.unclaimedAllocation(), DEFAULT_AMOUNT);
    }

    function test_unclaimedAllocation_afterRelease() public {
        vm.warp(startTs + CLIFF + LINEAR / 2);
        uint256 vestedNow = vest.vested();
        vest.release(address(token));
        assertEq(vest.unclaimedAllocation(), DEFAULT_AMOUNT - vestedNow);
    }

    function test_unclaimedAllocation_afterTerminationFreezesAtEndedAt() public {
        vm.warp(startTs + CLIFF + LINEAR / 2);
        uint256 vestedFrozen = vest.vested();
        vm.prank(governance);
        factory.terminateVest(address(vest), bytes32("p"), bytes32("g"));

        // Pre-release: full vested portion outstanding.
        assertEq(vest.unclaimedAllocation(), vestedFrozen);

        vest.release(address(token));
        assertEq(vest.unclaimedAllocation(), 0);
    }
}

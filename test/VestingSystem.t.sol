// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*###############################################################################

    @title Vesting Wallet test
    @author BLOK Capital DAO
    @notice End-to-end tests for the vesting system including regressions for
            the revoke math, delegate access control, and DAO-gated flows.

################################################################################*/

import "forge-std/Test.sol";
import {VestingWalletFactory} from "../src/factory/VestingWalletFactory.sol";
import {VestingWalletBlokc} from "../src/VestingWallet.sol";
import {MockERC20Votes} from "./mocks/MockERC20Votes.sol";

contract VestingSystemTest is Test {
    VestingWalletFactory factory;
    address constant DAO = address(0xD40);
    address constant NEW_DAO = address(0xD41);
    address constant BENEFICIARY = address(0xB0B);
    address constant ATTACKER = address(0xBAD);

    uint64 start;
    uint64 duration = 30 days;
    uint64 cliff = 7 days;

    bytes32 constant PROPOSAL = keccak256("proposal/42");

    function setUp() public {
        start = uint64(block.timestamp + 1 days);
        factory = new VestingWalletFactory(DAO);
    }

    // -----------------------------
    // Helpers
    // -----------------------------

    function _createWallet(bool revokeAllowed) internal returns (VestingWalletBlokc wallet) {
        vm.prank(DAO);
        address walletAddr = factory.createVestingWallet(BENEFICIARY, start, duration, cliff, revokeAllowed);
        wallet = VestingWalletBlokc(payable(walletAddr));
    }

    // -----------------------------
    // Factory: access control & registry
    // -----------------------------

    function test_factory_onlyDAO_canCreate() public {
        vm.prank(ATTACKER);
        vm.expectRevert(VestingWalletFactory.NotDAO.selector);
        factory.createVestingWallet(BENEFICIARY, start, duration, cliff, true);
    }

    function test_factory_registersNewWallet() public {
        VestingWalletBlokc wallet = _createWallet(true);
        address[] memory user = factory.getUserVestings(BENEFICIARY);
        address[] memory all = factory.getAllVestings();
        assertEq(user.length, 1);
        assertEq(all.length, 1);
        assertEq(user[0], address(wallet));
        assertEq(all[0], address(wallet));
    }

    function test_factory_rejectsZeroBeneficiary() public {
        vm.prank(DAO);
        vm.expectRevert(VestingWalletFactory.ZeroAddress.selector);
        factory.createVestingWallet(address(0), start, duration, cliff, true);
    }

    function test_factory_rejectsZeroDuration() public {
        vm.prank(DAO);
        vm.expectRevert(VestingWalletFactory.ZeroDuration.selector);
        factory.createVestingWallet(BENEFICIARY, start, 0, 0, true);
    }

    function test_factory_pagination() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(DAO);
            factory.createVestingWallet(address(uint160(0xA00 + i)), start, duration, cliff, false);
        }
        address[] memory page = factory.getAllVestingsPaged(1, 2);
        assertEq(page.length, 2);
        assertEq(factory.allVestingsLength(), 5);
    }

    function test_factory_constructor_rejectsZeroDAO() public {
        vm.expectRevert(VestingWalletFactory.ZeroAddress.selector);
        new VestingWalletFactory(address(0));
    }

    // -----------------------------
    // DAO 2-step rotation
    // -----------------------------

    function test_dao_rotation_twoStep() public {
        VestingWalletBlokc wallet = _createWallet(true);

        vm.prank(DAO);
        factory.beginDAOTransfer(NEW_DAO);
        assertEq(factory.dao(), DAO, "dao must not change until accepted");
        assertEq(factory.pendingDao(), NEW_DAO);

        vm.prank(NEW_DAO);
        factory.acceptDAOTransfer();
        assertEq(factory.dao(), NEW_DAO);
        assertEq(factory.pendingDao(), address(0));

        // Existing wallet sees the new DAO live.
        assertEq(wallet.dao(), NEW_DAO);
    }

    function test_dao_rotation_rejectsWrongAcceptor() public {
        vm.prank(DAO);
        factory.beginDAOTransfer(NEW_DAO);
        vm.prank(ATTACKER);
        vm.expectRevert(VestingWalletFactory.NotPendingDAO.selector);
        factory.acceptDAOTransfer();
    }

    function test_dao_rotation_cancel() public {
        vm.prank(DAO);
        factory.beginDAOTransfer(NEW_DAO);
        vm.prank(DAO);
        factory.cancelDAOTransfer();
        assertEq(factory.pendingDao(), address(0));
    }

    // -----------------------------
    // Delegate: access control (C2 regression)
    // -----------------------------

    function test_delegate_onlyBeneficiary() public {
        VestingWalletBlokc wallet = _createWallet(false);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);

        vm.prank(BENEFICIARY);
        wallet.delegate(address(token), BENEFICIARY);
        assertEq(token.delegates(address(wallet)), BENEFICIARY);
    }

    function test_delegate_revertsForNonBeneficiary() public {
        VestingWalletBlokc wallet = _createWallet(false);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);

        vm.prank(ATTACKER);
        vm.expectRevert(VestingWalletBlokc.NotBeneficiary.selector);
        wallet.delegate(address(token), ATTACKER);
    }

    // -----------------------------
    // Revoke: C1 + H1 regressions
    // -----------------------------

    function test_revoke_transfersOnlyUnvested_andBeneficiaryKeepsVested() public {
        VestingWalletBlokc wallet = _createWallet(true);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);

        // Warp to 50% of the way through the post-cliff period: cliff + half of remaining linear.
        // Linear schedule: at start+duration, full allocation vests. Half-way == duration/2.
        vm.warp(start + duration / 2);

        uint256 vestedBefore = wallet.vestedAmount(address(token), uint64(block.timestamp));
        assertEq(vestedBefore, 500 ether, "half of 1000 should be vested at 50%");

        vm.prank(DAO);
        wallet.revoke(address(token), PROPOSAL);

        // DAO receives the 500 unvested; wallet retains exactly the vested 500 for the beneficiary.
        assertEq(token.balanceOf(DAO), 500 ether, "DAO sweeps only unvested");
        assertEq(token.balanceOf(address(wallet)), 500 ether, "beneficiary retains vested");

        // Beneficiary can still release the vested portion.
        vm.prank(BENEFICIARY);
        wallet.release(address(token));
        assertEq(token.balanceOf(BENEFICIARY), 500 ether, "beneficiary gets full vested");
    }

    function test_revoke_accountsForAlreadyReleased() public {
        // H1 regression: if beneficiary already claimed part, revoke must not double-count.
        VestingWalletBlokc wallet = _createWallet(true);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);

        vm.warp(start + duration / 4);
        uint256 claimable1 = wallet.releasable(address(token));
        vm.prank(BENEFICIARY);
        wallet.release(address(token));
        assertEq(token.balanceOf(BENEFICIARY), claimable1);

        // Move to 75% total vested, then revoke.
        vm.warp(start + (duration * 3) / 4);
        uint256 expectedVested = 750 ether;
        uint256 expectedUnvested = 250 ether;

        vm.prank(DAO);
        wallet.revoke(address(token), PROPOSAL);

        // DAO should get only the 250 unvested, not a bogus amount inflated by released.
        assertEq(token.balanceOf(DAO), expectedUnvested, "DAO must see released-aware math");

        // Wallet balance left = vested - alreadyReleased, which is what beneficiary can still claim.
        uint256 expectedRemainingForBeneficiary = expectedVested - claimable1;
        assertEq(token.balanceOf(address(wallet)), expectedRemainingForBeneficiary);
    }

    function test_revoke_notAllowed_reverts() public {
        VestingWalletBlokc wallet = _createWallet(false);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);

        vm.prank(DAO);
        vm.expectRevert(VestingWalletBlokc.RevokeNotAllowed.selector);
        wallet.revoke(address(token), PROPOSAL);
    }

    function test_revoke_onlyDAO() public {
        VestingWalletBlokc wallet = _createWallet(true);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);

        vm.prank(ATTACKER);
        vm.expectRevert(VestingWalletBlokc.NotDAO.selector);
        wallet.revoke(address(token), PROPOSAL);
    }

    function test_revoke_idempotentPerToken() public {
        VestingWalletBlokc wallet = _createWallet(true);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);
        vm.warp(start + duration / 2);

        vm.prank(DAO);
        wallet.revoke(address(token), PROPOSAL);

        vm.prank(DAO);
        vm.expectRevert(VestingWalletBlokc.AlreadyRevoked.selector);
        wallet.revoke(address(token), PROPOSAL);
    }

    function test_revoke_usesPostRotationDAO() public {
        VestingWalletBlokc wallet = _createWallet(true);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);
        vm.warp(start + duration / 2);

        // Rotate DAO before revoke.
        vm.prank(DAO);
        factory.beginDAOTransfer(NEW_DAO);
        vm.prank(NEW_DAO);
        factory.acceptDAOTransfer();

        vm.prank(DAO);
        vm.expectRevert(VestingWalletBlokc.NotDAO.selector);
        wallet.revoke(address(token), PROPOSAL);

        vm.prank(NEW_DAO);
        wallet.revoke(address(token), PROPOSAL);
        assertEq(token.balanceOf(NEW_DAO), 500 ether);
    }

    // -----------------------------
    // ETH revoke
    // -----------------------------

    function test_revokeEth_sweepsUnvested() public {
        VestingWalletBlokc wallet = _createWallet(true);
        vm.deal(address(wallet), 10 ether);
        vm.warp(start + duration / 2);

        vm.prank(DAO);
        wallet.revokeEth(PROPOSAL);

        assertEq(DAO.balance, 5 ether);
        assertEq(address(wallet).balance, 5 ether);
    }

    function test_revokeEth_idempotent() public {
        VestingWalletBlokc wallet = _createWallet(true);
        vm.deal(address(wallet), 10 ether);
        vm.warp(start + duration / 2);

        vm.prank(DAO);
        wallet.revokeEth(PROPOSAL);

        vm.prank(DAO);
        vm.expectRevert(VestingWalletBlokc.AlreadyRevoked.selector);
        wallet.revokeEth(PROPOSAL);
    }

    // -----------------------------
    // Pause
    // -----------------------------

    function test_pause_blocksRelease() public {
        VestingWalletBlokc wallet = _createWallet(true);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);
        vm.warp(start + duration);

        vm.prank(DAO);
        wallet.pause();

        vm.prank(BENEFICIARY);
        vm.expectRevert();
        wallet.release(address(token));

        vm.prank(DAO);
        wallet.unpause();

        vm.prank(BENEFICIARY);
        wallet.release(address(token));
        assertEq(token.balanceOf(BENEFICIARY), 1000 ether);
    }

    function test_pause_onlyDAO() public {
        VestingWalletBlokc wallet = _createWallet(true);
        vm.prank(ATTACKER);
        vm.expectRevert(VestingWalletBlokc.NotDAO.selector);
        wallet.pause();
    }

    // -----------------------------
    // Ownership controls
    // -----------------------------

    function test_beneficiaryCannotTransferOwnership() public {
        VestingWalletBlokc wallet = _createWallet(true);
        vm.prank(BENEFICIARY);
        vm.expectRevert(VestingWalletBlokc.NotDAO.selector);
        wallet.transferOwnership(ATTACKER);
    }

    function test_dao_canRescueViaTransferOwnership() public {
        VestingWalletBlokc wallet = _createWallet(true);
        address rescueAddr = address(0xBEEF);
        vm.prank(DAO);
        wallet.transferOwnership(rescueAddr);
        assertEq(wallet.owner(), rescueAddr);
        assertEq(wallet.beneficiary(), rescueAddr);
    }

    function test_renounceOwnershipReverts() public {
        VestingWalletBlokc wallet = _createWallet(true);
        vm.prank(DAO);
        vm.expectRevert(VestingWalletBlokc.RenounceDisabled.selector);
        wallet.renounceOwnership();
    }

    // -----------------------------
    // Cliff still respected
    // -----------------------------

    function test_cliff_blocksReleaseBeforeCliff() public {
        VestingWalletBlokc wallet = _createWallet(true);
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);

        // Just after start but before cliff end.
        vm.warp(start + 1);
        assertEq(wallet.releasable(address(token)), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test} from "forge-std/Test.sol";
import {BLOKCVestingWallet} from "../../src/BLOKCVestingWallet.sol";
import {BLOKCVestingFactory} from "../../src/BLOKCVestingFactory.sol";
import {MockBLOKC} from "./MockBLOKC.sol";

/// @notice Shared fixture: deploys mock token, wallet implementation, and a
///         factory owned by `governance`. Funds the treasury and pre-approves
///         the factory so individual tests can call createVest directly.
abstract contract BaseTest is Test {
    MockBLOKC internal token;
    BLOKCVestingWallet internal implementation;
    BLOKCVestingFactory internal factory;

    address internal governance = makeAddr("governance");
    address internal treasury = makeAddr("treasury");
    address internal beneficiary = makeAddr("beneficiary");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint64 internal constant CLIFF = 365 days; // 12 months
    uint64 internal constant LINEAR = 3 * 365 days; // 36 months
    uint256 internal constant TREASURY_FUND = 1_000_000_000 ether;
    uint256 internal constant DEFAULT_AMOUNT = 1_000_000 ether;

    function setUp() public virtual {
        // Move start clock off zero so cliff/end math is unambiguous.
        vm.warp(1_700_000_000);

        token = new MockBLOKC();
        implementation = new BLOKCVestingWallet();
        factory = new BLOKCVestingFactory(
            address(implementation), address(token), treasury, governance, CLIFF, LINEAR
        );

        token.mint(treasury, TREASURY_FUND);
        vm.prank(treasury);
        token.approve(address(factory), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _createVest(
        address beneficiary_,
        uint256 amount,
        uint64 startTimestamp,
        bool prePaid,
        bool terminationDisclosed
    ) internal returns (BLOKCVestingWallet vest) {
        vm.prank(governance);
        vest = BLOKCVestingWallet(
            payable(factory.createVest(beneficiary_, amount, startTimestamp, prePaid, terminationDisclosed))
        );
    }

    function _defaultVest() internal returns (BLOKCVestingWallet) {
        return _createVest(beneficiary, DEFAULT_AMOUNT, uint64(block.timestamp), false, true);
    }
}

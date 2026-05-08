// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {BLOKCVestingFactory} from "../../src/BLOKCVestingFactory.sol";
import {BLOKCVestingWallet} from "../../src/BLOKCVestingWallet.sol";
import {MockBLOKC} from "../utils/MockBLOKC.sol";
import {Handler} from "./Handler.sol";

/// @notice Stateful invariants. The Handler drives random sequences of
///         createVest / warp / release / terminate / forfeit and the
///         invariants below must hold no matter what sequence the fuzzer
///         constructs.
contract BLOKCVestingInvariants is StdInvariant, Test {
    MockBLOKC internal token;
    BLOKCVestingWallet internal implementation;
    BLOKCVestingFactory internal factory;
    Handler internal handler;

    address internal governance = makeAddr("governance");
    address internal treasury = makeAddr("treasury");

    uint64 internal constant CLIFF = 30 days;
    uint64 internal constant LINEAR = 90 days;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockBLOKC();
        implementation = new BLOKCVestingWallet();
        factory = new BLOKCVestingFactory(address(implementation), address(token), treasury, governance, CLIFF, LINEAR);

        // Pre-approve max so the handler doesn't need to manage it.
        vm.prank(treasury);
        token.approve(address(factory), type(uint256).max);

        handler = new Handler(factory, token, governance, treasury);

        // Restrict the fuzzer to only call our handler, with the four
        // transitions we care about.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.createVest.selector;
        selectors[1] = handler.warp.selector;
        selectors[2] = handler.release.selector;
        selectors[3] = handler.terminate.selector;
        selectors[4] = handler.forfeit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Token conservation: every $BLOKC minted to the treasury for
    ///         vest funding must end up in exactly one of three places —
    ///         still inside a vest wallet, claimed by a beneficiary, or
    ///         returned to the treasury via terminate/forfeit.
    function invariant_tokenConservation() public view {
        uint256 inWallets;
        uint256 n = handler.vestCount();
        for (uint256 i; i < n; ++i) {
            inWallets += token.balanceOf(handler.vestAt(i));
        }

        uint256 inBeneficiaries;
        uint256 a = handler.actorCount();
        for (uint256 i; i < a; ++i) {
            inBeneficiaries += token.balanceOf(handler.actorAt(i));
        }

        // treasury sits at: initial supply (0 from the handler's POV) +
        // funds it minted - amount transferred to vests + reclaimed-on-end.
        // Net: balance(treasury) = totalFunded - inWallets - inBeneficiaries.
        uint256 lhs = token.balanceOf(treasury) + inWallets + inBeneficiaries;
        assertEq(lhs, handler.totalFunded(), "token conservation broken");
    }

    /// @notice For every vest, released(token) ≤ vestedAmount(now or endedAt).
    function invariant_releasedNeverExceedsVested() public view {
        uint256 n = handler.vestCount();
        for (uint256 i; i < n; ++i) {
            BLOKCVestingWallet v = BLOKCVestingWallet(payable(handler.vestAt(i)));
            uint256 ts = v.ended() ? v.endedAt() : uint64(block.timestamp);
            uint256 vested = v.vestedAmount(address(token), uint64(ts));
            assertLe(v.released(address(token)), vested, "released > vested");
        }
    }

    /// @notice For every vest, vested(now) ≤ totalAtStart.
    function invariant_vestedBoundedByTotal() public view {
        uint256 n = handler.vestCount();
        for (uint256 i; i < n; ++i) {
            BLOKCVestingWallet v = BLOKCVestingWallet(payable(handler.vestAt(i)));
            assertLe(v.vested(), v.totalAtStart(), "vested > total");
        }
    }

    /// @notice Once a vest is ended, ended() stays true and endedAt() is in
    ///         the past.
    function invariant_endedIsTerminal() public view {
        uint256 n = handler.vestCount();
        for (uint256 i; i < n; ++i) {
            BLOKCVestingWallet v = BLOKCVestingWallet(payable(handler.vestAt(i)));
            if (v.ended()) {
                assertLe(uint256(v.endedAt()), block.timestamp, "endedAt in future");
            }
        }
    }

    /// @notice Factory registry consistency: every vest in allVests is also
    ///         flagged in isVest.
    function invariant_registryConsistent() public view {
        uint256 n = factory.totalVests();
        for (uint256 i; i < n; ++i) {
            address v = factory.allVests(i);
            assertTrue(factory.isVest(v), "registered vest not in isVest map");
        }
    }

    /// @notice The wallet's $BLOKC balance always covers what's still
    ///         claimable by the beneficiary (vested - released).
    function invariant_walletCoversClaimable() public view {
        uint256 n = handler.vestCount();
        for (uint256 i; i < n; ++i) {
            BLOKCVestingWallet v = BLOKCVestingWallet(payable(handler.vestAt(i)));
            assertGe(token.balanceOf(address(v)), v.claimable(), "wallet underfunded for claim");
        }
    }

    /// @notice Voting-power delegation persists for every vest: the clone's
    ///         delegate is the vest's beneficiary.
    function invariant_delegationStable() public view {
        uint256 n = handler.vestCount();
        for (uint256 i; i < n; ++i) {
            BLOKCVestingWallet v = BLOKCVestingWallet(payable(handler.vestAt(i)));
            assertEq(token.delegates(address(v)), v.owner(), "delegation drifted");
        }
    }

    // ---------------------------------------------------------------------
    // Factory-shaped invariants
    // ---------------------------------------------------------------------

    /// @notice The factory is a pass-through deployer; it must never hold
    ///         $BLOKC (createVest sends from treasury straight to the clone).
    function invariant_factoryHoldsNoTokens() public view {
        assertEq(token.balanceOf(address(factory)), 0);
    }

    /// @notice allVests is append-only: its length only ever grows. Tracked
    ///         against the highest length the handler ever observed by
    ///         comparing against the handler's createdVests cursor (which
    ///         only grows on successful createVest).
    function invariant_registryIsAppendOnly() public view {
        assertEq(factory.totalVests(), handler.vestCount());
    }

    /// @notice Sum of per-beneficiary list lengths equals total vests. No
    ///         vest is ever orphaned or double-counted.
    function invariant_perBeneficiarySumsToTotal() public view {
        uint256 sum;
        uint256 a = handler.actorCount();
        for (uint256 i; i < a; ++i) {
            sum += factory.getVestsByBeneficiary(handler.actorAt(i)).length;
        }
        assertEq(sum, factory.totalVests(), "per-beneficiary lists out of sync with allVests");
    }

    /// @notice Every entry in vestsByBeneficiary[user] has owner() == user.
    function invariant_perBeneficiaryListsConsistent() public view {
        uint256 a = handler.actorCount();
        for (uint256 i; i < a; ++i) {
            address user = handler.actorAt(i);
            address[] memory list = factory.getVestsByBeneficiary(user);
            for (uint256 j; j < list.length; ++j) {
                assertEq(BLOKCVestingWallet(payable(list[j])).owner(), user, "vest owner != claimed beneficiary");
                assertTrue(factory.isVest(list[j]), "per-beneficiary entry not flagged in isVest");
            }
        }
    }

    /// @notice Factory immutables and ownership remain stable; the handler
    ///         never rotates ownership, so it must equal governance.
    function invariant_factoryConfigStable() public view {
        assertEq(factory.owner(), governance);
        assertEq(factory.token(), address(token));
        assertEq(factory.treasury(), treasury);
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.cliffDuration(), CLIFF);
        assertEq(factory.linearVestDuration(), LINEAR);
    }
}

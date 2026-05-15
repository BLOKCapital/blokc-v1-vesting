// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {BaseTest} from "../utils/Base.t.sol";
import {BLOKCVestingWallet} from "../../src/BLOKCVestingWallet.sol";

/// @notice Property tests for the BCIP-001 cliff-then-linear schedule.
contract BLOKCVestingWalletFuzz is BaseTest {
    uint256 internal constant MAX_AMOUNT = 1_000_000_000 ether; // < TREASURY_FUND
    uint64 internal constant MAX_CLIFF = 5 * 365 days;
    uint64 internal constant MAX_LINEAR = 10 * 365 days;

    function _deployWith(uint64 cliff, uint64 linear, uint256 amount, uint64 startTs)
        internal
        returns (BLOKCVestingWallet vest)
    {
        BLOKCVestingWallet impl = new BLOKCVestingWallet();
        vm.prank(treasury);
        token.approve(address(this), type(uint256).max); // not needed; factory uses its own approval
        // Re-deploy a factory with the fuzzed schedule so we go through the
        // production deploy path (clone + initialize + delegate).
        vm.startPrank(governance);
        bytes memory ctor = abi.encode(address(impl), address(token), treasury, governance, cliff, linear);
        ctor; // silence unused
        vm.stopPrank();

        // Reuse BaseTest's factory by deploying a fresh one with the fuzzed schedule.
        BLOKCVestingFactoryFresh f =
            new BLOKCVestingFactoryFresh(address(impl), address(token), treasury, governance, cliff, linear);
        vm.prank(treasury);
        token.approve(address(f), type(uint256).max);
        vm.prank(governance);
        vest = BLOKCVestingWallet(payable(f.createVest(beneficiary, amount, startTs, false, true)));
    }

    /// @notice Vested amount is bounded: 0 ≤ vested ≤ totalAmount, always.
    function testFuzz_vestedAmount_bounded(uint256 amount, uint64 cliff, uint64 linear, int256 deltaSeconds) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        cliff = uint64(bound(cliff, 0, MAX_CLIFF));
        linear = uint64(bound(linear, 1, MAX_LINEAR));

        uint64 startTs = uint64(block.timestamp);
        BLOKCVestingWallet vest = _deployWith(cliff, linear, amount, startTs);

        // Sample a timestamp within ±2*total around start.
        uint64 total = cliff + linear;
        deltaSeconds = bound(deltaSeconds, -int256(uint256(total)), int256(uint256(total)) * 2);

        uint64 ts;
        if (deltaSeconds < 0) {
            uint256 absDelta = uint256(-deltaSeconds);
            ts = absDelta > startTs ? 0 : uint64(uint256(startTs) - absDelta);
        } else {
            ts = uint64(uint256(startTs) + uint256(deltaSeconds));
        }

        uint256 v = vest.vestedAmount(address(token), ts);
        assertLe(v, amount, "vested > total");
    }

    /// @notice The schedule is non-decreasing in time: t1 ≤ t2 ⇒ vested(t1) ≤ vested(t2).
    function testFuzz_vestedAmount_monotonic(uint256 amount, uint64 cliff, uint64 linear, uint64 t1, uint64 t2) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        cliff = uint64(bound(cliff, 0, MAX_CLIFF));
        linear = uint64(bound(linear, 1, MAX_LINEAR));

        uint64 startTs = uint64(block.timestamp);
        BLOKCVestingWallet vest = _deployWith(cliff, linear, amount, startTs);

        uint64 total = cliff + linear;
        t1 = uint64(bound(t1, startTs, uint256(startTs) + 2 * uint256(total)));
        t2 = uint64(bound(t2, t1, uint256(startTs) + 2 * uint256(total)));

        assertLe(vest.vestedAmount(address(token), t1), vest.vestedAmount(address(token), t2));
    }

    /// @notice Pre-cliff value is exactly 0.
    function testFuzz_vestedAmount_zeroBeforeCliff(uint256 amount, uint64 cliff, uint64 linear, uint256 fraction)
        public
    {
        amount = bound(amount, 1, MAX_AMOUNT);
        cliff = uint64(bound(cliff, 1, MAX_CLIFF));
        linear = uint64(bound(linear, 1, MAX_LINEAR));
        fraction = bound(fraction, 0, uint256(cliff) - 1);

        uint64 startTs = uint64(block.timestamp);
        BLOKCVestingWallet vest = _deployWith(cliff, linear, amount, startTs);

        assertEq(vest.vestedAmount(address(token), uint64(uint256(startTs) + fraction)), 0);
    }

    /// @notice At/after end the vested amount equals totalAmount.
    function testFuzz_vestedAmount_fullAtOrAfterEnd(uint256 amount, uint64 cliff, uint64 linear, uint64 extra) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        cliff = uint64(bound(cliff, 0, MAX_CLIFF));
        linear = uint64(bound(linear, 1, MAX_LINEAR));
        extra = uint64(bound(extra, 0, type(uint32).max));

        uint64 startTs = uint64(block.timestamp);
        BLOKCVestingWallet vest = _deployWith(cliff, linear, amount, startTs);

        uint64 ts = uint64(uint256(startTs) + uint256(cliff) + uint256(linear) + uint256(extra));
        assertEq(vest.vestedAmount(address(token), ts), amount);
    }

    /// @notice Termination conservation: at the moment of terminate(),
    ///         treasuryReturn + vestedFrozen == totalAtStart.
    function testFuzz_terminate_conservesTotal(uint256 amount, uint64 cliff, uint64 linear, uint256 elapsed) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        cliff = uint64(bound(cliff, 0, MAX_CLIFF));
        linear = uint64(bound(linear, 1, MAX_LINEAR));
        uint64 total = cliff + linear;
        // Cap elapsed to total - 1 so the vest is never fully matured when we
        // call terminate (AlreadyMatured reverts on fully-vested vests).
        elapsed = bound(elapsed, 0, uint256(total) - 1);

        uint64 startTs = uint64(block.timestamp);
        BLOKCVestingWallet vest = _deployWith(cliff, linear, amount, startTs);

        vm.warp(uint256(startTs) + elapsed);

        uint256 vestedBefore = vest.vested();
        uint256 treasuryBefore = token.balanceOf(treasury);

        // Terminate via the registered factory of this clone.
        address f = vest.factory();
        vm.prank(governance);
        BLOKCVestingFactoryFresh(f).terminateVest(address(vest), bytes32("p"), bytes32("g"));

        uint256 returned = token.balanceOf(treasury) - treasuryBefore;
        assertEq(returned + vestedBefore, amount, "termination broke conservation");
        assertEq(token.balanceOf(address(vest)), vestedBefore, "wallet keeps the vested portion");
    }

    /// @notice Forfeit conservation mirrors terminate.
    function testFuzz_forfeit_conservesTotal(uint256 amount, uint64 cliff, uint64 linear, uint256 elapsed) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        cliff = uint64(bound(cliff, 0, MAX_CLIFF));
        linear = uint64(bound(linear, 1, MAX_LINEAR));
        uint64 total = cliff + linear;
        // Cap elapsed to total - 1 so the vest is never fully matured when we
        // call forfeit (AlreadyMatured reverts on fully-vested vests).
        elapsed = bound(elapsed, 0, uint256(total) - 1);

        uint64 startTs = uint64(block.timestamp);
        BLOKCVestingWallet vest = _deployWith(cliff, linear, amount, startTs);
        vm.warp(uint256(startTs) + elapsed);

        uint256 vestedBefore = vest.vested();
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(beneficiary);
        vest.forfeit();

        uint256 returned = token.balanceOf(treasury) - treasuryBefore;
        assertEq(returned + vestedBefore, amount);
    }

    /// @notice Releasing in chunks at increasing timestamps never overpays
    ///         the beneficiary.
    function testFuzz_release_chunked_neverOverpays(uint256 amount, uint64 cliff, uint64 linear, uint64 step) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        cliff = uint64(bound(cliff, 0, MAX_CLIFF));
        linear = uint64(bound(linear, 1, MAX_LINEAR));
        step = uint64(bound(step, 1 days, 90 days));

        uint64 startTs = uint64(block.timestamp);
        BLOKCVestingWallet vest = _deployWith(cliff, linear, amount, startTs);

        uint256 totalDuration = uint256(cliff) + uint256(linear);
        uint256 elapsed;
        uint256 paid;
        while (elapsed <= totalDuration) {
            vm.warp(uint256(startTs) + elapsed);
            vm.prank(alice); // anyone can call; beneficiary receives
            vest.release(address(token));
            paid = token.balanceOf(beneficiary);
            // vest.vested() reads block.timestamp inside the wallet — avoids
            // any caller-side caching of timestamp across cheatcode warps.
            assertLe(paid, vest.vested(), "paid > vested at this timestamp");
            assertLe(paid, amount);
            elapsed += step;
        }
        // After end, the full amount should have been paid out.
        vm.warp(uint256(startTs) + totalDuration + 1);
        vest.release(address(token));
        assertEq(token.balanceOf(beneficiary), amount);
    }
}

// Helper factory exposed at module scope so the fuzz contract can deploy it
// from its inline helper without depending on internal state of BaseTest.
import {BLOKCVestingFactory} from "../../src/BLOKCVestingFactory.sol";

contract BLOKCVestingFactoryFresh is BLOKCVestingFactory {
    constructor(address impl, address token_, address treasury_, address governance_, uint64 cliff, uint64 linear)
        BLOKCVestingFactory(impl, token_, treasury_, governance_, cliff, linear)
    {}
}

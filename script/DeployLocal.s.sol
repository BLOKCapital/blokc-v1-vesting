// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Script, console} from "forge-std/Script.sol";
import {MockBLOKC} from "../test/utils/MockBLOKC.sol";
import {BLOKCVestingWallet} from "../src/BLOKCVestingWallet.sol";
import {BLOKCVestingFactory} from "../src/BLOKCVestingFactory.sol";

/// @title DeployLocal
/// @notice Deploys the full vesting system against a local anvil node using
///         the standard anvil test accounts:
///           governance = anvil account #0 (factory owner)
///           treasury   = anvil account #1 (funding source + unvested sink)
///         Mints 1B mock $BLOKC to the treasury and pre-approves the factory.
contract DeployLocal is Script {
    address constant GOVERNANCE = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant TREASURY = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant TREASURY_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    function run() external {
        uint64 cliff = 365 days; // 12 months
        uint64 linear = 3 * 365 days; // 36 months

        vm.startBroadcast();
        MockBLOKC token = new MockBLOKC();
        BLOKCVestingWallet implementation = new BLOKCVestingWallet();
        BLOKCVestingFactory factory = new BLOKCVestingFactory(
            address(implementation), address(token), TREASURY, GOVERNANCE, cliff, linear
        );
        token.mint(TREASURY, 1_000_000_000 ether);
        vm.stopBroadcast();

        // createVest pulls funding via safeTransferFrom(treasury, ...), so the
        // treasury must pre-approve the factory. Signed with the treasury key.
        vm.startBroadcast(TREASURY_PK);
        token.approve(address(factory), type(uint256).max);
        vm.stopBroadcast();

        console.log("TOKEN=%s", address(token));
        console.log("IMPLEMENTATION=%s", address(implementation));
        console.log("FACTORY=%s", address(factory));
        console.log("GOVERNANCE=%s", GOVERNANCE);
        console.log("TREASURY=%s", TREASURY);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {Script, console} from "forge-std/Script.sol";
import {BLOKCVestingWallet} from "../src/BLOKCVestingWallet.sol";
import {BLOKCVestingFactory} from "../src/BLOKCVestingFactory.sol";

/// @title DeployAll
/// @author BLOK Capital DAO
/// @notice Deploys the BLOKCVestingWallet implementation and the
///         BLOKCVestingFactory pointing at it. Reads from env:
///           BLOKC_TOKEN, TREASURY_ADDRESS, GOVERNANCE_ADDRESS,
///           CLIFF_DURATION, LINEAR_VEST_DURATION (seconds, uint64).
contract DeployAll is Script {
    function run() external returns (BLOKCVestingWallet implementation, BLOKCVestingFactory factory) {
        address token = vm.envAddress("BLOKC_TOKEN");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address governance = vm.envAddress("GOVERNANCE_ADDRESS");
        // Validate before the narrowing cast: a wrapped value would silently
        // truncate into a tiny valid duration and bypass the factory
        // constructor's overflow guard.
        uint256 cliffEnv = vm.envUint("CLIFF_DURATION");
        uint256 linearEnv = vm.envUint("LINEAR_VEST_DURATION");
        if (cliffEnv > type(uint64).max || linearEnv > type(uint64).max) {
            revert("CLIFF_DURATION / LINEAR_VEST_DURATION must fit in uint64");
        }
        uint64 cliffDuration = uint64(cliffEnv);
        uint64 linearVestDuration = uint64(linearEnv);

        vm.startBroadcast();
        implementation = new BLOKCVestingWallet();
        factory = new BLOKCVestingFactory(
            address(implementation), token, treasury, governance, cliffDuration, linearVestDuration
        );
        vm.stopBroadcast();

        console.log("Implementation deployed at:", address(implementation));
        console.log("Factory deployed at:", address(factory));
        console.log("Token:", token);
        console.log("Treasury:", treasury);
        console.log("Governance (factory owner):", governance);
        console.log("Cliff (s):", cliffDuration);
        console.log("Linear vest (s):", linearVestDuration);
    }
}

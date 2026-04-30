// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BLOKCVestingWallet} from "../src/BLOKCVestingWallet.sol";
import {BLOKCVestingFactory} from "../src/BLOKCVestingFactory.sol";

/// @title DeployAll
/// @author BLOK Capital DAO
/// @notice Deploys the BLOKCVestingWallet implementation and the
///         BLOKCVestingFactory pointing at it. Reads BLOKC_TOKEN,
///         TREASURY_ADDRESS, and GOVERNANCE_ADDRESS from env.
contract DeployAll is Script {
    function run() external returns (BLOKCVestingWallet implementation, BLOKCVestingFactory factory) {
        address token = vm.envAddress("BLOKC_TOKEN");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address governance = vm.envAddress("GOVERNANCE_ADDRESS");

        vm.startBroadcast();
        implementation = new BLOKCVestingWallet();
        factory = new BLOKCVestingFactory(address(implementation), token, treasury, governance);
        vm.stopBroadcast();

        console.log("Implementation deployed at:", address(implementation));
        console.log("Factory deployed at:", address(factory));
        console.log("Token:", token);
        console.log("Treasury:", treasury);
        console.log("Governance (factory owner):", governance);
    }
}

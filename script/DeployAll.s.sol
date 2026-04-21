// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*###############################################################################

    @title Vesting System Deployment Script
    @author BLOK Capital DAO
    @notice Deploys VestingWalletFactory with the DAO supplied via the DAO_ADDRESS env var.

################################################################################*/

import "forge-std/Script.sol";
import {VestingWalletFactory} from "../src/factory/VestingWalletFactory.sol";

/// @title DeployAll
/// @author BLOK Capital DAO
/// @notice Forge deployment script for the vesting system.
/// 
contract DeployAll is Script {
    /// @notice Deploy the factory with the DAO read from the `DAO_ADDRESS` env var.
    /// @return factory The deployed {VestingWalletFactory} instance.
    function run() external returns (VestingWalletFactory factory) {
        address dao = vm.envAddress("DAO_ADDRESS");
        vm.startBroadcast();
        factory = new VestingWalletFactory(dao);
        vm.stopBroadcast();
    }
}

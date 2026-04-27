// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*###############################################################################

    @title Vesting System Deployment Script
    @author BLOK Capital DAO
    @notice Deploys the shared {VestingWalletBlokc} implementation and the
            {VestingWalletFactory} that clones it. DAO is read from DAO_ADDRESS.

################################################################################*/

import "forge-std/Script.sol";
import {VestingWalletBlokc} from "../src/VestingWallet.sol";
import {VestingWalletFactory} from "../src/factory/VestingWalletFactory.sol";

/// @title DeployAll
/// @author BLOK Capital DAO
/// @notice Forge deployment script for the clone-based vesting system.
contract DeployAll is Script {
    /// @notice Deploys the implementation and then the factory pointing at it.
    /// @return implementation The shared {VestingWalletBlokc} logic contract.
    /// @return factory The deployed {VestingWalletFactory} instance.
    function run() external returns (VestingWalletBlokc implementation, VestingWalletFactory factory) {
        address dao = vm.envAddress("DAO_ADDRESS");
        vm.startBroadcast();
        implementation = new VestingWalletBlokc();
        factory = new VestingWalletFactory(address(implementation), dao);
        vm.stopBroadcast();
    }
}

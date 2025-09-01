// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*###############################################################################

    @title Vesting Wallet Factory
    @author BLOK Capital DAO
    @notice This contract implements logic for Vesting Wallet Factory which helps deploy vesting wallets

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖ 
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘


################################################################################*/

import "../VestingWallet.sol";

contract VestingWalletFactory {
    /// @notice Restrict access to DAO-only functions in this factory

    modifier onlyDAO() {
        require(msg.sender == dao, "Not DAO");
        _;
    }
    /// @notice Allows the current DAO to update the DAO address
    /// @param newDAO The new DAO address

    function updateDAO(address newDAO) external onlyDAO {
        require(newDAO != address(0), "Invalid DAO address");
        dao = newDAO;
    }

    /// @notice Restrict access to DAO-only functions using a modifier
    address public dao = 0x003a7E96B48Ee318DE5200Fcc9504480643237f3;

    /// @notice Registry storage
    mapping(address => address[]) internal userVestings;
    /// @notice Array of all vesting wallets
    address[] internal allVestings;

    /// @notice Emitted when a new vesting wallet is created
    event VestingWalletCreated(address wallet, address beneficiary);
    event VestingRegistered(address indexed user, address vestingWallet);

    /// @notice Retrieves the vesting wallets for a specific user
    /// @param user The address of the user
    /// @return array of vesting wallet addresses

    function getUserVestings(address user) external view returns (address[] memory) {
        return userVestings[user];
    }

    /// @notice Retrieves all vesting wallets
    /// @return array of all vesting wallet addresses

    function getAllVestings() external view returns (address[] memory) {
        return allVestings;
    }

    // Optional: If you want to allow updating DAO, restrict access
    function setDAO(address newDAO) external onlyDAO {
        dao = newDAO;
    }

    /// @notice Creates a new vesting wallet, assigns it to the beneficiary along with the registry creation
    /// @param beneficiary The address of the beneficiary, the DAO user basically
    /// @param start The start time of the vesting, time where actual vesting period initiates
    /// @param duration The duration of the vesting, time over which tokens will be vested
    /// @param cliffDuration The cliff duration of the vesting, where cliff is nothing but how long after the tokens will be received back from the DAO
    /// @param revokeAllowed Whether revoke is allowed for this vesting wallet
    /// @return The address of the newly created vesting wallet

    function createVestingWallet(
        address beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliffDuration,
        bool revokeAllowed
    ) external returns (address) {
        // Deploy wallet with beneficiary as owner, DAO as special role for revoke
        VestingWalletBlokc wallet =
            new VestingWalletBlokc(dao, beneficiary, start, duration, cliffDuration, revokeAllowed);
        userVestings[beneficiary].push(address(wallet));
        allVestings.push(address(wallet));
        emit VestingWalletCreated(address(wallet), beneficiary);
        emit VestingRegistered(beneficiary, address(wallet));
        return address(wallet);
    }
}

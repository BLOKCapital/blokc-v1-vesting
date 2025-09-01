// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*###############################################################################

    @title Vesting Wallet test
    @author BLOK Capital DAO
    @notice This contract implements logic for Vesting Wallet testing

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖ 
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘


################################################################################*/

import "forge-std/Test.sol";
import "../src/factory/VestingWalletFactory.sol";
import "../src/VestingWallet.sol";
import "./mocks/MockERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VestingSystemTest is Test {
    VestingWalletFactory factory;
    address DAO;
    address beneficiary = address(0x2);
    uint64 start = uint64(block.timestamp + 1 days);
    uint64 duration = 30 days;
    uint64 cliff = 7 days;

    function setUp() public {
        DAO = 0x003a7E96B48Ee318DE5200Fcc9504480643237f3;
        factory = new VestingWalletFactory();
    }

    /// @notice Tests the creation of a vesting wallet and its registration

    function testFactoryCreatesVestingWalletAndRegisters() public {
        vm.prank(beneficiary);
        address walletAddr = factory.createVestingWallet(beneficiary, start, duration, cliff, true);
        // Registry functions are owner-only, so use DAO
        vm.prank(DAO);
        address[] memory userWallets = factory.getUserVestings(beneficiary);
        assertEq(userWallets.length, 1);
        assertEq(userWallets[0], walletAddr);
    }

    /// @notice Tests the delegation and revocation of tokens in a vesting wallet when revoke is not allowed

    function testVestingWalletDelegateAndRevoke_NotAllowed() public {
        // revokeAllowed = false
        vm.prank(beneficiary);
        address walletAddr = factory.createVestingWallet(beneficiary, start, duration, cliff, false);
        VestingWalletBlokc wallet = VestingWalletBlokc(payable(walletAddr));
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);
        vm.prank(beneficiary);
        wallet.delegate(address(token), beneficiary);
        assertEq(token.delegates(address(wallet)), beneficiary);
        // Test revoke fails if not allowed
        vm.prank(DAO);
        vm.expectRevert();
        wallet.revoke(address(token));
    }

    /// @notice Tests the delegation and revocation of tokens in a vesting wallet when revoke is allowed
    function testVestingWalletDelegateAndRevoke_Allowed() public {
        // revokeAllowed = true
        vm.prank(beneficiary);
        address walletAddr = factory.createVestingWallet(beneficiary, start, duration, cliff, true);
        VestingWalletBlokc wallet = VestingWalletBlokc(payable(walletAddr));
        MockERC20Votes token = new MockERC20Votes();
        token.mint(address(wallet), 1000 ether);
        vm.prank(beneficiary);
        wallet.delegate(address(token), beneficiary);
        assertEq(token.delegates(address(wallet)), beneficiary);
        // Now revoke should succeed
        vm.prank(DAO);
        wallet.revoke(address(token));
        // After revoke, unvested tokens should be transferred to DAO
        assertEq(token.balanceOf(DAO), 1000 ether);
    }

    /// @notice Tests the retrieval of vesting wallets for a specific user

    function testRegistryGlobalList() public {
        vm.prank(beneficiary);
        address walletAddr = factory.createVestingWallet(beneficiary, start, duration, cliff, true);
        // Registry functions are owner-only, so use DAO
        vm.prank(DAO);
        address[] memory allWallets = factory.getAllVestings();
        assertEq(allWallets.length, 1);
        assertEq(allWallets[0], walletAddr);
    }

    /// @notice Tests the retrieval of vesting wallets for a specific user when revoke is allowed
    function testRegistryGlobalList_True() public {
        vm.prank(beneficiary);
        address walletAddr = factory.createVestingWallet(beneficiary, start, duration, cliff, true);
        vm.prank(DAO);
        address[] memory allWallets = factory.getAllVestings();
        assertEq(allWallets.length, 1);
        assertEq(allWallets[0], walletAddr);
    }
    /// @notice Tests the retrieval of vesting wallets for a specific user when revoke is not allowed

    function testRegistryGlobalList_False() public {
        vm.prank(beneficiary);
        address walletAddr = factory.createVestingWallet(beneficiary, start, duration, cliff, false);
        vm.prank(DAO);
        address[] memory allWallets = factory.getAllVestings();
        assertEq(allWallets.length, 1);
        assertEq(allWallets[0], walletAddr);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*###############################################################################

    @title Mock ERC20 Votes
    @author BLOK Capital DAO
    @notice Test-only ERC20Votes token used by the vesting system test suite.

    ▗▄▄▖ ▗▖    ▗▄▖ ▗▖ ▗▖     ▗▄▄▖ ▗▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▖ ▗▖       ▗▄▄▄  ▗▄▖  ▗▄▖
    ▐▌ ▐▌▐▌   ▐▌ ▐▌▐▌▗▞▘    ▐▌   ▐▌ ▐▌▐▌ ▐▌ █    █ ▐▌ ▐▌▐▌       ▐▌  █▐▌ ▐▌▐▌ ▐▌
    ▐▛▀▚▖▐▌   ▐▌ ▐▌▐▛▚▖     ▐▌   ▐▛▀▜▌▐▛▀▘  █    █ ▐▛▀▜▌▐▌       ▐▌  █▐▛▀▜▌▐▌ ▐▌
    ▐▙▄▞▘▐▙▄▄▖▝▚▄▞▘▐▌ ▐▌    ▝▚▄▄▖▐▌ ▐▌▐▌  ▗▄█▄▖  █ ▐▌ ▐▌▐▙▄▄▖    ▐▙▄▄▀▐▌ ▐▌▝▚▄▞▘

################################################################################*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/// @title MockERC20Votes
/// @author BLOK Capital DAO
/// @notice Minimal ERC20 with permit + votes extensions for exercising
///         {VestingWalletBlokc.delegate} and release paths in tests.
/// @dev Not production-grade. Unrestricted {mint}; intended purely for tests.
contract MockERC20Votes is ERC20, ERC20Permit, ERC20Votes {
    /// @notice Deploy the mock token with name "MockToken" / symbol "MTK".
    constructor() ERC20("MockToken", "MTK") ERC20Permit("MockToken") {}

    /// @notice Unrestricted mint helper for test setup.
    /// @param to Recipient of the minted supply.
    /// @param amount Amount of tokens to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @inheritdoc ERC20
    /// @dev Required multi-inheritance override for OpenZeppelin v5.x — chains the
    ///      `_update` hook so checkpoint bookkeeping in {ERC20Votes} still runs on
    ///      every balance change.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /// @inheritdoc ERC20Permit
    /// @dev Disambiguates the {nonces} getter between {ERC20Permit} and {Nonces}.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

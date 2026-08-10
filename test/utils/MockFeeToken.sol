// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fee-on-transfer ERC20 (1% fee burned on every transfer) used to
///         prove the wallet rejects underfunded initialization instead of
///         overstating totalAtStart against the balance actually received.
contract MockFeeToken is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() ERC20("MockFee", "MFEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Fee applies to transfers only (not mint/burn) so test balances
    ///      are exact. The fee is taken from the sender; the receiver gets
    ///      exactly `amount - fee`.
    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
        } else {
            uint256 fee = (amount * FEE_BPS) / 10_000;
            super._update(from, to, amount - fee);
            if (fee > 0) super._update(from, address(0), fee);
        }
    }
}

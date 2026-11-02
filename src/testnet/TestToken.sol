// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title TestToken: testnet-only ERC20 that anyone can mint
/// @notice Used on Sepolia to stand in for WETH, WBTC, USDC and others. No value, no owner, no limits.
contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_, decimals_) {}

    /// @notice Mint any amount to any address. Testnet only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

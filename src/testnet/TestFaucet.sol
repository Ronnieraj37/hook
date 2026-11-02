// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestToken} from "./TestToken.sol";

/// @title TestFaucet: every test token in one transaction
/// @notice Testnet only. The test tokens are open-mint, so this contract simply mints a fixed amount of each to the
/// caller. Works with any wallet (no batching support needed).
contract TestFaucet {
    TestToken[] public tokens;
    uint256[] public amounts;

    event Dripped(address indexed to);

    constructor(TestToken[] memory tokens_, uint256[] memory amounts_) {
        require(tokens_.length == amounts_.length, "length");
        tokens = tokens_;
        amounts = amounts_;
    }

    function drip() external {
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i].mint(msg.sender, amounts[i]);
        }
        emit Dripped(msg.sender);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }
}

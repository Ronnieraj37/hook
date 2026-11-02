// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TestToken} from "../../src/testnet/TestToken.sol";

/// @notice Deploys open-mint test tokens on Sepolia and mints a large balance to the deployer.
/// Saves the addresses to deployments/sepolia-tokens.json so they are reused, not redeployed.
///   forge script script/sepolia/01_DeployTokens.s.sol --rpc-url sepolia --broadcast
contract DeployTokens is Script {
    string constant OUT = "./deployments/sepolia-tokens.json";

    function run() external {
        string[6] memory symbols = ["WETH", "WBTC", "USDC", "USDT", "DAI", "LINK"];
        string[6] memory names = [
            "Test Wrapped Ether",
            "Test Wrapped Bitcoin",
            "Test USD Coin",
            "Test Tether USD",
            "Test Dai",
            "Test Chainlink"
        ];
        uint8[6] memory decimals = [18, 8, 6, 6, 18, 18];

        vm.startBroadcast();
        address me = msg.sender;
        string memory json;
        for (uint256 i; i < symbols.length; ++i) {
            TestToken t = new TestToken(names[i], string.concat("t", symbols[i]), decimals[i]);
            t.mint(me, 1_000_000_000 * 10 ** decimals[i]);
            json = vm.serializeAddress("tokens", symbols[i], address(t));
            console.log(symbols[i], address(t));
        }
        vm.stopBroadcast();
        vm.writeJson(json, OUT);
    }
}

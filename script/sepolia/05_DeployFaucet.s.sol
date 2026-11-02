// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TestToken} from "../../src/testnet/TestToken.sol";
import {TestFaucet} from "../../src/testnet/TestFaucet.sol";

/// @notice Deploys a faucet that mints every test token in one call:
/// 100 tWETH, 5 tWBTC, 500,000 tUSDC / tUSDT / tDAI, 20,000 tLINK.
contract DeployFaucet is Script {
    function run() external {
        string memory toks = vm.readFile("./deployments/sepolia-tokens.json");
        string[6] memory syms = ["WETH", "WBTC", "USDC", "USDT", "DAI", "LINK"];
        uint256[6] memory whole = [uint256(100), 5, 500_000, 500_000, 500_000, 20_000];
        TestToken[] memory t = new TestToken[](6);
        uint256[] memory a = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            t[i] = TestToken(vm.parseJsonAddress(toks, string.concat(".", syms[i])));
            a[i] = whole[i] * 10 ** t[i].decimals();
        }
        vm.startBroadcast();
        TestFaucet f = new TestFaucet(t, a);
        vm.stopBroadcast();
        vm.writeJson(vm.serializeAddress("faucet", "faucet", address(f)), "./deployments/sepolia-faucet.json");
        console.log("TestFaucet", address(f));
    }
}

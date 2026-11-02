// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {RuleHook} from "../../src/RuleHook.sol";
import {ConditionalOrders} from "../../src/ConditionalOrders.sol";

/// @notice Deploys RuleHook (at a mined address with the right hook flags) and ConditionalOrders.
///   forge script script/sepolia/02_DeployCore.s.sol --rpc-url sepolia --broadcast
contract DeployCore is Script {
    string constant OUT = "./deployments/sepolia-core.json";

    function run() external {
        IPoolManager poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(RuleHook).creationCode, args);

        vm.startBroadcast();
        RuleHook hook = new RuleHook{salt: salt}(poolManager);
        ConditionalOrders orders = new ConditionalOrders(poolManager, hook);
        vm.stopBroadcast();
        require(address(hook) == hookAddress, "hook address mismatch");

        string memory json = vm.serializeAddress("core", "poolManager", address(poolManager));
        json = vm.serializeAddress("core", "positionManager", AddressConstants.getPositionManagerAddress(block.chainid));
        json = vm.serializeAddress("core", "swapRouter", AddressConstants.getV4SwapRouterAddress(block.chainid));
        json = vm.serializeAddress("core", "permit2", AddressConstants.getPermit2Address());
        json = vm.serializeAddress("core", "ruleHook", address(hook));
        json = vm.serializeAddress("core", "conditionalOrders", address(orders));
        json = vm.serializeUint("core", "deployBlock", block.number);
        vm.writeJson(json, OUT);
        console.log("RuleHook", address(hook));
        console.log("ConditionalOrders", address(orders));
    }
}

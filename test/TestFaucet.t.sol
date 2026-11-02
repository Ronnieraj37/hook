// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/testnet/TestToken.sol";
import {TestFaucet} from "../src/testnet/TestFaucet.sol";

contract TestFaucetTest is Test {
    function test_dripMintsEveryToken() public {
        TestToken[] memory t = new TestToken[](2);
        t[0] = new TestToken("A", "A", 18);
        t[1] = new TestToken("B", "B", 6);
        uint256[] memory a = new uint256[](2);
        a[0] = 100e18;
        a[1] = 500_000e6;
        TestFaucet f = new TestFaucet(t, a);
        address user = makeAddr("user");
        vm.prank(user);
        f.drip();
        assertEq(t[0].balanceOf(user), 100e18);
        assertEq(t[1].balanceOf(user), 500_000e6);
    }
}

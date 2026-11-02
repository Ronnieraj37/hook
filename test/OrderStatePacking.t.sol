// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {OrderState} from "../src/libraries/OrderState.sol";

/// @dev External wrapper so reverts inside the library can be caught with expectRevert.
contract Packer {
    function encode(OrderState.State memory s) external pure returns (uint256) {
        return OrderState.encode(s);
    }
}

/// @notice Proves the packed word is collision-free: every field round-trips at its extremes, writing one field never
/// changes another, the two halves never touch, and out-of-range values are rejected instead of wrapping.
contract OrderStatePackingTest is Test {
    Packer packer = new Packer();
    uint256 constant FIELDS = 11;

    // ---------------------------------------------------------------- helpers

    /// A side with every field at its largest legal value. `checker` decides which aux field is meaningful.
    function _maxSide(uint8 checker, bool negative) internal pure returns (OrderState.Side memory d) {
        d.edge = negative ? TickMath.MIN_TICK : TickMath.MAX_TICK;
        d.checker = checker;
        d.value = negative ? type(int24).min : type(int24).max;
        d.actions = 15;
        d.removeBps = 10_000;
        d.swapToToken1 = true;
        d.addMode = 3;
        d.repeat = true;
        d.shape = OrderState.MAX_SHAPE;
        if (checker == OrderState.CHECK_TICK) d.checkPool = type(uint24).max;
        if (checker == OrderState.CHECK_TIME) d.lastRun = uint32(OrderState.BASE_TIME + uint256(0xFFFFFF) * 60);
    }

    function _random(uint256 seed) internal pure returns (OrderState.Side memory d) {
        d.edge = int24(int256(bound(uint256(keccak256(abi.encode(seed, 0))), 0, 1_774_544)) - 887_272);
        d.checker = uint8(uint256(keccak256(abi.encode(seed, 1))) % 4);
        d.value = int24(uint24(uint256(keccak256(abi.encode(seed, 2)))));
        d.actions = uint8(uint256(keccak256(abi.encode(seed, 3))) % 16);
        d.removeBps = uint16(uint256(keccak256(abi.encode(seed, 4))) % 10_001);
        d.swapToToken1 = uint256(keccak256(abi.encode(seed, 5))) % 2 == 1;
        d.addMode = uint8(uint256(keccak256(abi.encode(seed, 6))) % 4);
        d.repeat = uint256(keccak256(abi.encode(seed, 7))) % 2 == 1;
        d.shape = uint24(uint256(keccak256(abi.encode(seed, 8))) % (uint256(OrderState.MAX_SHAPE) + 1));
        if (d.checker == OrderState.CHECK_TICK) d.checkPool = uint24(uint256(keccak256(abi.encode(seed, 9))));
        if (d.checker == OrderState.CHECK_TIME) {
            d.lastRun = uint32(OrderState.BASE_TIME + (uint256(keccak256(abi.encode(seed, 10))) % 0xFFFFFF + 1) * 60);
        }
    }

    /// Set field `k` of `d` to a value derived from `seed` (always legal).
    function _setField(OrderState.Side memory d, uint256 k, uint256 seed) internal pure {
        if (k == 0) d.edge = int24(int256(seed % 1_774_545) - 887_272);
        else if (k == 1) d.checker = uint8(seed % 4);
        else if (k == 2) d.value = int24(uint24(seed));
        else if (k == 3) d.actions = uint8(seed % 16);
        else if (k == 4) d.removeBps = uint16(seed % 10_001);
        else if (k == 5) d.swapToToken1 = !d.swapToToken1;
        else if (k == 6) d.addMode = uint8(seed % 4);
        else if (k == 7) d.repeat = !d.repeat;
        else if (k == 8) d.shape = uint24(seed % (uint256(OrderState.MAX_SHAPE) + 1));
        else if (k == 9 && d.checker == OrderState.CHECK_TICK) d.checkPool = uint24(seed);
        else if (k == 10 && d.checker == OrderState.CHECK_TIME) {
            d.lastRun = uint32(OrderState.BASE_TIME + (seed % 0xFFFFFF + 1) * 60);
        }
        // The aux field holds checkPool for TICK and lastRun for TIME; the other one is always zero.
        if (d.checker != OrderState.CHECK_TICK) d.checkPool = 0;
        if (d.checker != OrderState.CHECK_TIME) d.lastRun = 0;
        else if (d.lastRun == 0) d.lastRun = uint32(OrderState.BASE_TIME + 60);
    }

    function _roundTrip(OrderState.State memory st) internal pure returns (OrderState.State memory) {
        return OrderState.decode(OrderState.encode(st));
    }

    // ---------------------------------------------------------------- extremes

    function test_allFieldsAtMaximum_bothHalves() public pure {
        for (uint8 checker = 1; checker <= 3; ++checker) {
            for (uint256 n; n < 2; ++n) {
                OrderState.State memory st;
                st.lower = _maxSide(checker, n == 0);
                st.upper = _maxSide(checker, n == 1);
                assertEq(abi.encode(_roundTrip(st)), abi.encode(st));
            }
        }
    }

    /// One field set to its maximum, everything else zero: no other field may read non-zero.
    function test_eachFieldAloneDoesNotLeak() public pure {
        OrderState.Side memory full = _maxSide(OrderState.CHECK_TICK, true);
        OrderState.Side memory fullTime = _maxSide(OrderState.CHECK_TIME, false);
        for (uint256 k; k < FIELDS; ++k) {
            OrderState.Side memory one;
            if (k == 0) one.edge = full.edge;
            if (k == 1) one.checker = 15;
            if (k == 2) one.value = full.value;
            if (k == 3) one.actions = full.actions;
            if (k == 4) one.removeBps = full.removeBps;
            if (k == 5) one.swapToToken1 = true;
            if (k == 6) one.addMode = 3;
            if (k == 7) one.repeat = true;
            if (k == 8) one.shape = full.shape;
            if (k == 9) {
                one.checker = OrderState.CHECK_TICK;
                one.checkPool = full.checkPool;
            }
            if (k == 10) {
                one.checker = OrderState.CHECK_TIME;
                one.lastRun = fullTime.lastRun;
            }
            OrderState.State memory st;
            st.upper = one; // in the upper half: the lower half must stay exactly zero
            uint256 word = OrderState.encode(st);
            assertEq(word & type(uint128).max, 0, "upper field leaked into the lower half");
            assertEq(abi.encode(OrderState.decode(word).upper), abi.encode(one));

            st.upper = OrderState.Side(0, 0, 0, 0, 0, 0, false, 0, false, 0, 0);
            st.lower = one; // and the other way round
            word = OrderState.encode(st);
            assertEq(word >> 128, 0, "lower field leaked into the upper half");
            assertEq(abi.encode(OrderState.decode(word).lower), abi.encode(one));
        }
    }

    /// Exact bit positions, so the layout cannot drift from the documented one.
    function test_documentedBitPositions() public pure {
        OrderState.State memory st;
        st.upper.edge = -1; // 0xFFFFFF
        st.upper.checker = OrderState.CHECK_TICK;
        st.upper.checkPool = 0xABCDEF;
        st.upper.removeBps = 10_000;
        uint256 w = OrderState.encode(st);
        assertEq((w >> 128) & 0xFFFFFF, 0xFFFFFF); // edge at 0-23
        assertEq((w >> (128 + 24)) & 0xF, 2); // checker at 24-27
        assertEq((w >> (128 + 52)) & 0xFFFFFF, 0xABCDEF); // aux at 52-75
        assertEq((w >> (128 + 80)) & 0x3FFF, 10_000); // removeBps at 80-93
        assertEq(w >> (128 + 120), 0); // spare bits 120-127 stay zero
    }

    // ---------------------------------------------------------------- fuzz

    /// Change any one field of either side: that field changes, nothing else does.
    function testFuzz_changingOneFieldChangesOnlyThatField(uint256 seedA, uint256 seedB, uint256 k, uint256 v, bool upper)
        public
        pure
    {
        OrderState.State memory st;
        st.lower = _random(seedA);
        st.upper = _random(seedB);
        uint256 before = OrderState.encode(st);

        OrderState.State memory changed = OrderState.decode(before);
        _setField(upper ? changed.upper : changed.lower, k % FIELDS, v);
        uint256 afterWord = OrderState.encode(changed);
        OrderState.State memory back = OrderState.decode(afterWord);

        assertEq(abi.encode(back), abi.encode(changed));
        if (upper) {
            assertEq(afterWord & type(uint128).max, before & type(uint128).max, "lower half changed");
            assertEq(abi.encode(back.lower), abi.encode(st.lower));
        } else {
            assertEq(afterWord >> 128, before >> 128, "upper half changed");
            assertEq(abi.encode(back.upper), abi.encode(st.upper));
        }
    }

    function testFuzz_roundTrip(uint256 seedA, uint256 seedB) public pure {
        OrderState.State memory st;
        st.lower = _random(seedA);
        st.upper = _random(seedB);
        assertEq(abi.encode(_roundTrip(st)), abi.encode(st));
    }

    // ---------------------------------------------------------------- rejected values

    function test_outOfRangeValuesRevertInsteadOfWrapping() public {
        OrderState.State memory st;
        st.upper.checker = 16;
        vm.expectRevert(OrderState.FieldTooLarge.selector);
        packer.encode(st);

        st.upper.checker = 1;
        st.upper.actions = 16;
        vm.expectRevert(OrderState.FieldTooLarge.selector);
        packer.encode(st);

        st.upper.actions = 0;
        st.upper.removeBps = 10_001;
        vm.expectRevert(OrderState.FieldTooLarge.selector);
        packer.encode(st);

        st.upper.removeBps = 0;
        st.upper.addMode = 4;
        vm.expectRevert(OrderState.FieldTooLarge.selector);
        packer.encode(st);

        st.upper.addMode = 0;
        st.upper.shape = OrderState.MAX_SHAPE + 1;
        vm.expectRevert(OrderState.FieldTooLarge.selector);
        packer.encode(st);

        st.upper.shape = 0;
        st.upper.checker = OrderState.CHECK_TIME;
        st.upper.lastRun = uint32(OrderState.BASE_TIME - 1);
        vm.expectRevert(OrderState.TimeBeforeBase.selector);
        packer.encode(st);
    }

    /// lastRun is stored in minutes rounded up: never earlier than the real time, at most 59 s later.
    function testFuzz_lastRunNeverEarly(uint32 t) public pure {
        t = uint32(bound(t, OrderState.BASE_TIME + 1, OrderState.BASE_TIME + uint256(0xFFFFFF) * 60));
        OrderState.State memory st;
        st.upper.checker = OrderState.CHECK_TIME;
        st.upper.lastRun = t;
        uint32 back = _roundTrip(st).upper.lastRun;
        assertGe(back, t);
        assertLt(back, uint256(t) + 60);
    }
}

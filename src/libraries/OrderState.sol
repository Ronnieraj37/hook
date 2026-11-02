// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title OrderState
/// @notice Packs the part of an order that changes on every run into one 256-bit word (storage slot 1).
///
/// The word is two independent 128-bit halves:
///   bits   0-127  lower side: its edge is the position's tickLower, it fires when the price falls
///   bits 128-255  upper side: its edge is the position's tickUpper, it fires when the price rises (or on time)
/// Each half holds everything its own check needs, so checking one side never reads the other half.
///
/// Half layout (offset inside the half):
///   0-23     edge        int24  where this side of the position sits: tickLower (lower half) or tickUpper
///                               (upper half). Any sign. Moves only when the position is re-ranged.
///   24-27    checker     what wakes this side: 0 off, 1 EDGE, 2 TICK, 3 TIME
///   28-51    value       int24  the checker's number. EDGE: ticks past the edge; TICK: a price level (tick);
///                               TIME: minutes
///   52-75    aux         uint24 depends on the checker. TICK: pool index to read the price from (0 = own pool).
///                               TIME: lastRun, minutes since BASE_TIME rounded up (valid until 2057). EDGE: unused.
///   76-79    actions     bit0 keep fees in the order, bit1 remove, bit2 swap, bit3 add
///   80-93    removeBps   0-10,000
///   94       swapToToken1
///   95-96    addMode     0 same range, 1 one-sided next to the price
///   97       repeat
///   98-119   shape       with add: widthBelow (bits 0-10) + widthAbove (bits 11-21), in tick spacings
///                        without add: step in ticks for a repeating TICK side
///   120-127  spare
library OrderState {
    error FieldTooLarge();
    error TimeBeforeBase();

    uint8 internal constant CHECK_OFF = 0;
    uint8 internal constant CHECK_EDGE = 1;
    uint8 internal constant CHECK_TICK = 2;
    uint8 internal constant CHECK_TIME = 3;

    uint8 internal constant ACT_KEEP_FEES = 1;
    uint8 internal constant ACT_REMOVE = 2;
    uint8 internal constant ACT_SWAP = 4;
    uint8 internal constant ACT_ADD = 8;

    uint8 internal constant ADD_SAME_RANGE = 0;
    uint8 internal constant ADD_ONE_SIDED = 1;

    uint24 internal constant MAX_WIDTH = 2047; // 11 bits
    uint24 internal constant MAX_SHAPE = (1 << 22) - 1;

    /// @dev 2026-01-01 00:00:00 UTC. lastRun is stored as minutes after this.
    uint256 internal constant BASE_TIME = 1_767_225_600;

    struct Side {
        int24 edge;
        uint8 checker;
        int24 value;
        uint24 checkPool; // TICK only (stored in aux)
        uint8 actions;
        uint16 removeBps;
        bool swapToToken1;
        uint8 addMode;
        bool repeat;
        uint24 shape;
        uint32 lastRun; // TIME only (stored in aux), unix seconds
    }

    struct State {
        Side lower;
        Side upper;
    }

    uint256 private constant HALF_MASK = type(uint128).max;

    function encode(State memory s) internal pure returns (uint256) {
        return encodeSide(s.lower) | (encodeSide(s.upper) << 128);
    }

    function decode(uint256 word) internal pure returns (State memory s) {
        s.lower = decodeSide(word & HALF_MASK);
        s.upper = decodeSide(word >> 128);
    }

    /// @notice Read one side straight from the word, without touching the other half.
    // @change function not being used anywhere
    function side(uint256 word, bool upper) internal pure returns (Side memory) {
        return decodeSide(upper ? word >> 128 : word & HALF_MASK);
    }

    /// @notice True when a side has a condition. Reads 4 bits.
    // @change function not being used anywhere
    function isOn(uint256 word, bool upper) internal pure returns (bool) {
        return ((upper ? word >> 128 : word) >> 24) & 0xF != 0;
    }

    function encodeSide(Side memory d) internal pure returns (uint256 v) {
        if (d.checker > 15 || d.actions > 15 || d.removeBps > 10_000 || d.addMode > 3 || d.shape > MAX_SHAPE) {
            revert FieldTooLarge();
        }
        uint256 aux = d.checker == CHECK_TICK ? d.checkPool : d.checker == CHECK_TIME ? _minutes(d.lastRun) : 0;
        v = uint256(uint24(d.edge)) | (uint256(d.checker) << 24) | (uint256(uint24(d.value)) << 28) | (aux << 52)
            | (uint256(d.actions) << 76) | (uint256(d.removeBps) << 80) | (_bit(d.swapToToken1) << 94)
            | (uint256(d.addMode) << 95) | (_bit(d.repeat) << 97) | (uint256(d.shape) << 98);
    }

    function decodeSide(uint256 v) internal pure returns (Side memory d) {
        d.edge = int24(uint24(v));
        d.checker = uint8((v >> 24) & 0xF);
        d.value = int24(uint24(v >> 28));
        uint256 aux = (v >> 52) & 0xFFFFFF;
        if (d.checker == CHECK_TICK) d.checkPool = uint24(aux);
        else if (d.checker == CHECK_TIME && aux != 0) d.lastRun = uint32(BASE_TIME + aux * 60);
        d.actions = uint8((v >> 76) & 0xF);
        d.removeBps = uint16((v >> 80) & 0x3FFF);
        d.swapToToken1 = (v >> 94) & 1 == 1;
        d.addMode = uint8((v >> 95) & 0x3);
        d.repeat = (v >> 97) & 1 == 1;
        d.shape = uint24((v >> 98) & MAX_SHAPE);
    }

    function widthBelow(Side memory d) internal pure returns (uint24) {
        return d.shape & MAX_WIDTH;
    }

    function widthAbove(Side memory d) internal pure returns (uint24) {
        return (d.shape >> 11) & MAX_WIDTH;
    }

    /// @notice Clear a side's rule but keep its edge (the position's range does not change).
    function clear(Side memory d) internal pure {
        int24 edge = d.edge;
        d.checker = 0;
        d.value = 0;
        d.checkPool = 0;
        d.actions = 0;
        d.removeBps = 0;
        d.swapToToken1 = false;
        d.addMode = 0;
        d.repeat = false;
        d.shape = 0;
        d.lastRun = 0;
        d.edge = edge;
    }

    /// @dev Unix seconds -> minutes after BASE_TIME, rounded up, so a TIME rule never fires early.
    function _minutes(uint32 t) private pure returns (uint256 m) {
        if (t == 0) return 0;
        if (t < BASE_TIME) revert TimeBeforeBase();
        m = (uint256(t) - BASE_TIME + 59) / 60;
        if (m > 0xFFFFFF) revert FieldTooLarge();
    }

    function _bit(bool b) private pure returns (uint256) {
        return b ? 1 : 0;
    }
}

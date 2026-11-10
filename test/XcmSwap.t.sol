// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {XcmSwap} from "../src/XcmSwap.sol";

contract XcmSwapHarness {
    function swap(uint256 usdtAmount, uint256 minXon, bytes32 beneficiary) external pure returns (bytes memory) {
        return XcmSwap.swapUsdtForXon(usdtAmount, minXon, beneficiary);
    }

    function compact(uint256 value) external pure returns (bytes memory) {
        return XcmSwap.compact(value);
    }

    function contractAccount(address account) external pure returns (bytes32) {
        return XcmSwap.contractAccount(account);
    }
}

/// Vectors were encoded with polkadot.js (`api.createType('XcmVersionedXcm', ...)`) against
/// Xode's live metadata, for the beneficiary 0xabab...ab (20 bytes) ++ 0xeeee...ee (12 bytes).
contract XcmSwapTest is Test {
    XcmSwapHarness internal h;
    bytes32 internal constant BENEFICIARY =
        hex"ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee";

    function setUp() public {
        h = new XcmSwapHarness();
    }

    function _check(uint256 amount, uint256 minXon, bytes memory expected) internal view {
        assertEq(h.swap(amount, minXon, BENEFICIARY), expected);
    }

    function test_matchesPolkadotJs_singleByteAmounts() public view {
        _check(0, 0, hex"050c00040002043205011f00000f01010002043205011f000400000000010d01020800010100ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee");
        _check(1, 1, hex"050c00040002043205011f00040f01010002043205011f000400000004010d01020800010100ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee");
        _check(63, 64, hex"050c00040002043205011f00fc0f01010002043205011f00040000000101010d01020800010100ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee");
    }

    function test_matchesPolkadotJs_twoAndFourByteAmounts() public view {
        _check(16383, 16384, hex"050c00040002043205011f00fdff0f01010002043205011f000400000002000100010d01020800010100ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee");
        _check(1073741823, 1073741824, hex"050c00040002043205011f00feffffff0f01010002043205011f00040000000300000040010d01020800010100ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee");
    }

    function test_matchesPolkadotJs_bigIntegerAmounts() public view {
        // 2 USDT for at least 0.381652221371 XON - the amounts from the fork dry-run.
        _check(2000000, 381652221371, hex"050c00040002043205011f0002127a000f01010002043205011f000400000007bbbd3edc58010d01020800010100ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee");
        _check(type(uint64).max, uint256(type(uint64).max) + 1, hex"050c00040002043205011f0013ffffffffffffffff0f01010002043205011f000400000017000000000000000001010d01020800010100ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee");
        _check(type(uint128).max, 1 << 96, hex"050c00040002043205011f0033ffffffffffffffffffffffffffffffff0f01010002043205011f00040000002700000000000000000000000001010d01020800010100ababababababababababababababababababababeeeeeeeeeeeeeeeeeeeeeeee");
    }

    function test_compact_rejectsAboveU128() public {
        vm.expectRevert(XcmSwap.AmountTooLarge.selector);
        h.compact(uint256(type(uint128).max) + 1);
    }

    function testFuzz_compact_lengthAndPrefix(uint128 value) public view {
        bytes memory c = h.compact(value);
        uint8 mode = uint8(c[0]) & 3;
        if (value < 1 << 6) assertEq(c.length, 1);
        else if (value < 1 << 14) assertEq(mode, 1);
        else if (value < 1 << 30) assertEq(mode, 2);
        else {
            assertEq(mode, 3);
            assertEq(c.length, (uint8(c[0]) >> 2) + 4 + 1);
            assertTrue(uint8(c[c.length - 1]) != 0, "big-integer mode must use the minimal length");
        }
    }

    function test_contractAccount_isAddressThenEE() public view {
        assertEq(h.contractAccount(address(0xABaBaBaBABabABabAbAbABAbABabababaBaBABaB)), BENEFICIARY);
    }
}

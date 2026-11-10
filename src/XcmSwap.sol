// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Xode's XCM precompile (`pallet-xcm-precompiles`, fixed address 0xA0000). `execute`
/// runs an XCM program locally with the calling contract's own account as the origin.
interface IXcm {
    struct Weight {
        uint64 refTime;
        uint64 proofSize;
    }

    function execute(bytes calldata message, Weight calldata weight) external;
    function weighMessage(bytes calldata message) external view returns (Weight memory weight);
}

/// @notice Builds the XCM program that swaps USDT for native XON on Xode's DEX
/// (`pallet-asset-conversion`, reached through the runtime's XCM `AssetExchanger`):
///
///     WithdrawAsset(USDT, usdtAmount)                          from the caller's account
///     ExchangeAsset(give: all USDT, want: >= minXon XON, maximal: true)
///     DepositAsset(all, beneficiary)                            XON (and any change) to beneficiary
///
/// The bytes are a SCALE-encoded `VersionedXcm::V5`. Only the two amounts and the beneficiary
/// vary, so the rest is fixed: the encoding was produced with polkadot.js against Xode's
/// metadata, and `test/XcmSwap.t.sol` checks this library against those vectors. USDT is
/// `pallet-assets` (pallet instance 50) asset 1984; XON is the native token, `{parents: 0, Here}`.
library XcmSwap {
    address internal constant XCM_PRECOMPILE = address(0xA0000);

    error AmountTooLarge();

    // 05 V5 | 0c three instructions | 00 WithdrawAsset, 04 one asset,
    // 00 02 04 32 05 011f = {parents 0, X2[PalletInstance(50), GeneralIndex(1984)]}, 00 Fungible
    bytes private constant HEAD = hex"050c00040002043205011f00";
    // 0f ExchangeAsset | give: 01 Wild, 01 AllOf, <USDT id>, 00 Fungible |
    // want: 04 one asset, 00 00 = {parents 0, Here} (XON), 00 Fungible
    bytes private constant MID = hex"0f01010002043205011f0004000000";
    // 01 maximal = true | 0d DepositAsset, 01 Wild, 02 AllCounted, 08 = 2 |
    // beneficiary: 00 parents 0, 01 X1, 01 AccountId32, 00 network None, then the 32-byte id
    bytes private constant TAIL = hex"010d01020800010100";

    /// The XCM program above. `minXon` is in planck (XON's 12-decimal native unit).
    function swapUsdtForXon(uint256 usdtAmount, uint256 minXon, bytes32 beneficiary)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(HEAD, compact(usdtAmount), MID, compact(minXon), TAIL, beneficiary);
    }

    /// The AccountId32 `pallet-revive` gives a contract: its 20-byte address followed by twelve
    /// 0xEE bytes (`AccountId32Mapper`'s fallback account).
    function contractAccount(address account) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(account, bytes12(0xeeeeeeeeeeeeeeeeeeeeeeee)));
    }

    /// SCALE compact encoding of an unsigned integer up to `u128` (all a `Balance` can hold).
    function compact(uint256 value) internal pure returns (bytes memory out) {
        if (value > type(uint128).max) revert AmountTooLarge();
        if (value < 1 << 6) return abi.encodePacked(uint8(value << 2));
        if (value < 1 << 14) return _littleEndian((value << 2) | 1, 2);
        if (value < 1 << 30) return _littleEndian((value << 2) | 2, 4);

        uint256 len = 4;
        while (len < 16 && value >> (8 * len) != 0) len++;
        out = new bytes(len + 1);
        out[0] = bytes1(uint8(((len - 4) << 2) | 3));
        for (uint256 i = 0; i < len; i++) out[i + 1] = bytes1(uint8(value >> (8 * i)));
    }

    function _littleEndian(uint256 value, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) out[i] = bytes1(uint8(value >> (8 * i)));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Standard ERC20 interface. On Xode this is backed by `pallet_assets_precompiles::ERC20`
/// for any asset registered as a `TrustBackedAsset`/`PoolAsset` (e.g. USDT), not by a real EVM
/// contract - calls are routed by the runtime's precompile matcher instead of bytecode.
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

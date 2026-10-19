// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Stand-in for USDT on Ethereum (0xdAC17F958D2ee523a2206206994597C13D831ec7), which isn't
/// a standard ERC20 in two ways that matter to EthUsdtGateway: `transfer`/`transferFrom` return
/// nothing (no bool), and it has an owner-set fee on transfers (`basisPointsRate`, capped at
/// `maximumFee`) that's currently 0 on mainnet but can be switched on. Deliberately does NOT
/// implement IERC20, since its signatures don't match.
contract TetherLikeUsdt {
    uint8 public constant decimals = 6;

    uint256 public basisPointsRate;
    uint256 public maximumFee;
    address public feeCollector = address(0xFEE);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setParams(uint256 newBasisPoints, uint256 newMaxFee) external {
        basisPointsRate = newBasisPoints;
        maximumFee = newMaxFee;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "TetherLikeUsdt: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "TetherLikeUsdt: insufficient balance");
        uint256 fee = (amount * basisPointsRate) / 10_000;
        if (fee > maximumFee) fee = maximumFee;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        balanceOf[feeCollector] += fee;
    }
}

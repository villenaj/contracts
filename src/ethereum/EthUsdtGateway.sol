// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";

/// @notice Deployed on Ethereum (not Xode). Accepts real USDT from a depositor who wants XON on
/// Xode in return, and records which Xode address (`xodeBeneficiary`) should receive it - there is
/// no cross-chain callback here, so a separate relayer service watches `Deposited` events on this
/// contract and calls `XonVendingMachine.settleExternalPurchase` on Xode to actually pay out.
/// `depositForSwap` is the market-price variant: it emits `SwapDeposited` with the depositor's
/// minimum, and the relayer pays it with `settleExternalSwap` (a DEX swap on Xode) or refunds it.
///
/// This contract is a custodial escrow, not a bridge: USDT deposited here just sits in this
/// contract's balance under `owner`'s control (via `withdraw`) until manually moved - there is no
/// on-chain mechanism connecting Ethereum and Xode (Xode has no live Snowbridge connection as of
/// writing). The XON payout on Xode is entirely a promise kept by whoever runs the relayer and
/// controls `owner`/`relayer` here and the corresponding `relayer` role on `XonVendingMachine` -
/// securing those keys (and this contract's `owner` key, which can drain the whole USDT balance)
/// is the actual security boundary of this leg, not this contract's code.
contract EthUsdtGateway {
    IERC20 public immutable usdt;
    address public owner;
    bool public paused;
    uint256 public depositNonce;

    uint256 private _locked;

    event Deposited(
        address indexed depositor,
        address indexed xodeBeneficiary,
        uint256 usdtAmount,
        uint256 indexed depositNonce
    );
    /// A deposit to be paid at the Xode DEX's market price (`XonVendingMachine.settleExternalSwap`)
    /// rather than the vending contract's fixed rate. `minXonOut` (18-decimal units) is the least
    /// XON the depositor accepts; if the pool can't give that much, the relayer refunds them.
    event SwapDeposited(
        address indexed depositor,
        address indexed xodeBeneficiary,
        uint256 usdtAmount,
        uint256 indexed depositNonce,
        uint256 minXonOut
    );
    event Withdrawn(address indexed to, uint256 amount);
    event PausedSet(bool paused);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error IsPaused();
    error ZeroAddress();
    error ZeroAmount();
    error UsdtTransferFailed();
    error Reentrant();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked == 1) revert Reentrant();
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor(address usdtToken, address owner_) {
        if (usdtToken == address(0) || owner_ == address(0)) revert ZeroAddress();
        usdt = IERC20(usdtToken);
        owner = owner_;
    }

    /// Deposits `usdtAmount` USDT (requires a prior `usdt.approve(address(this), usdtAmount)`)
    /// and records `xodeBeneficiary` as who should receive the resulting XON on Xode. The relayer
    /// picks this up from the `Deposited` event and pays out for its `usdtAmount` - which is what
    /// actually arrived in this contract, not what was asked for, so a token that takes a fee on
    /// transfer (Ethereum USDT has a fee switch, currently off) can never be paid out above what
    /// the gateway really holds.
    function deposit(uint256 usdtAmount, address xodeBeneficiary) external whenNotPaused nonReentrant {
        (uint256 received, uint256 nonce) = _pull(usdtAmount, xodeBeneficiary);
        emit Deposited(msg.sender, xodeBeneficiary, received, nonce);
    }

    /// Like `deposit`, but asks to be paid at the Xode DEX's market price, receiving at least
    /// `minXonOut` XON (18-decimal units, as Solidity sees native XON on Xode) or a refund. Set it
    /// from a fresh quote minus your slippage tolerance. If USDT ever charges a transfer fee, the
    /// swap is for what arrived, so a tight minimum may then be refunded instead.
    function depositForSwap(uint256 usdtAmount, address xodeBeneficiary, uint256 minXonOut)
        external
        whenNotPaused
        nonReentrant
    {
        if (minXonOut == 0) revert ZeroAmount();
        (uint256 received, uint256 nonce) = _pull(usdtAmount, xodeBeneficiary);
        emit SwapDeposited(msg.sender, xodeBeneficiary, received, nonce, minXonOut);
    }

    /// Takes `usdtAmount` from the caller; returns what actually arrived and the deposit's nonce.
    function _pull(uint256 usdtAmount, address xodeBeneficiary) private returns (uint256 received, uint256 nonce) {
        if (xodeBeneficiary == address(0)) revert ZeroAddress();
        if (usdtAmount == 0) revert ZeroAmount();

        uint256 balanceBefore = usdt.balanceOf(address(this));
        _callUsdt(abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), usdtAmount)));
        received = usdt.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        nonce = depositNonce++;
    }

    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _callUsdt(abi.encodeCall(IERC20.transfer, (to, amount)));
        emit Withdrawn(to, amount);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// Calls `transfer`/`transferFrom` on USDT, accepting tokens that return nothing. Ethereum's
    /// USDT is one: its `transfer`/`transferFrom` have no return value, so calling them through
    /// `IERC20` (which expects a bool) would revert on every deposit and withdrawal. A token that
    /// does return a value must return true.
    function _callUsdt(bytes memory data) private {
        (bool ok, bytes memory returned) = address(usdt).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returned, 32), mload(returned))
            }
        }
        if (returned.length != 0 && !abi.decode(returned, (bool))) revert UsdtTransferFailed();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {Custodial} from "../Custodial.sol";

/// @notice Deployed on Ethereum (not Xode). Accepts real USDT from a depositor who wants XON on
/// Xode in return, and records which Xode address (`xodeBeneficiary`) should receive it - there is
/// no cross-chain callback here, so a separate relayer service watches `Deposited` events on this
/// contract and calls `XonVendingMachine.settleExternalPurchase` on Xode to actually pay out.
/// `depositForSwap` is the market-price variant: it emits `SwapDeposited` with the depositor's
/// minimum, and the relayer pays it with `settleExternalSwap` (a DEX swap on Xode) or refunds it.
///
/// This contract is a custodial escrow, not a bridge: USDT deposited here sits in this contract's
/// balance until the owner moves it - there is no on-chain mechanism connecting Ethereum and Xode
/// (Xode has no live Snowbridge connection as of writing). The XON payout on Xode is a promise kept
/// by whoever runs the relayer. What bounds a compromised owner (the custody rules in `Custodial`):
///  - `withdraw` only ever pays the `treasury` (meant to be a separate, cold multisig); changing the
///    treasury waits `TREASURY_DELAY`, during which the `guardian` can cancel it and pause.
///  - `refund` only pays a deposit back to the account that made it, once (deposits are recorded).
///  - Ownership moves in two steps, so a wrong owner address can never take the gateway.
contract EthUsdtGateway is Custodial {
    IERC20 public immutable usdt;
    uint256 public depositNonce;

    /// keccak256(abi.encode(depositor, usdtAmount)) per deposit nonce, until it's refunded.
    mapping(uint256 => bytes32) public depositRecords;

    uint256 private _locked;

    event Deposited(
        address indexed depositor,
        address indexed xodeBeneficiary,
        uint256 usdtAmount,
        uint256 indexed depositNonce
    );
    /// A deposit to be paid at the Xode DEX's market price (`XonVendingMachine.settleExternalSwap`)
    /// rather than the vending contract's fixed rate. `minXonOut` (18-decimal units) is the least
    /// XON the depositor accepts; if the pool can't give that much, it's refunded.
    event SwapDeposited(
        address indexed depositor,
        address indexed xodeBeneficiary,
        uint256 usdtAmount,
        uint256 indexed depositNonce,
        uint256 minXonOut
    );
    event Withdrawn(address indexed to, uint256 amount);
    event Refunded(uint256 indexed depositNonce, address indexed depositor, uint256 amount);

    error ZeroAmount();
    error UsdtTransferFailed();
    error Reentrant();
    error UnknownDeposit();

    modifier nonReentrant() {
        if (_locked == 1) revert Reentrant();
        _locked = 1;
        _;
        _locked = 0;
    }

    /// `treasury_` is where withdrawals go (a cold multisig in production) and `guardian_` the key or
    /// multisig that can pause and veto treasury changes - both may start as `owner_` in development.
    constructor(address usdtToken, address owner_, address treasury_, address guardian_)
        Custodial(owner_, treasury_, guardian_)
    {
        if (usdtToken == address(0)) revert ZeroAddress();
        usdt = IERC20(usdtToken);
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
        depositRecords[nonce] = keccak256(abi.encode(msg.sender, received));
    }

    /// Moves custodied USDT to the treasury - the only place it can go besides a refund.
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _callUsdt(abi.encodeCall(IERC20.transfer, (treasury, amount)));
        emit Withdrawn(treasury, amount);
    }

    /// Pays deposit `nonce` back to the account that made it, in full and only once - for a deposit
    /// that can't be paid out on Xode (e.g. a market-price minimum the pool couldn't meet).
    /// `depositor` and `usdtAmount` must match the deposit's event; they're checked against the record.
    function refund(uint256 nonce, address depositor, uint256 usdtAmount) external onlyOwner nonReentrant {
        bytes32 record = depositRecords[nonce];
        if (record == bytes32(0) || record != keccak256(abi.encode(depositor, usdtAmount))) revert UnknownDeposit();
        delete depositRecords[nonce];
        _callUsdt(abi.encodeCall(IERC20.transfer, (depositor, usdtAmount)));
        emit Refunded(nonce, depositor, usdtAmount);
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

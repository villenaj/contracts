// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Holds a native-XON reserve the owner pre-funds, and pays it out at a fixed,
/// owner-set rate to anyone who pays USDT (an ERC20 precompile over a pallet-assets
/// `TrustBackedAsset` on Xode). Two ways to buy:
///  - `buy`: buyer `usdt.approve(this, amount)` then calls `buy` - one contract, two signatures
///    the first time, one signature (`buy`) on every purchase after a max approval.
///  - `settlePurchase`: buyer just `usdt.transfer(this, amount)` directly - a single signature,
///    every time, no approval ever - but someone has to notice the transfer and call
///    `settlePurchase` on the buyer's behalf, since plain ERC20 `transfer` has no callback hook.
///    That's `relayer`'s job (see the off-chain watcher in client/relayXonVendingMachine.js).
///
/// `settlePurchase` trusts `relayer` to report the right buyer/amount/txHash, but never trusts it
/// with the contract's actual funds: it only ever pays out XON backed by USDT that has genuinely,
/// verifiably landed in this contract's own balance (`accountedUsdt` tracks how much of the
/// current USDT balance is already spoken for by a completed purchase, across both paths). A
/// compromised relayer key can misattribute a real deposit to the wrong buyer; it can never
/// manufacture a payout with no matching deposit.
///
/// A third path, `settleExternalPurchase`, pays out XON for USDT paid on a *different* chain
/// (AssetHub, or Ethereum via the sibling `EthUsdtGateway` contract) - see the standalone relayer
/// service that watches all three sources. This one is honestly NOT backed by the same on-chain
/// guarantee as `settlePurchase`: the USDT never touches this contract's own balance (it sits in
/// an AssetHub collector account, or in `EthUsdtGateway` on Ethereum), so there is no local balance
/// to verify against. `relayer` is fully trusted for this path - a compromised relayer key here
/// really can manufacture payouts, unlike the native-USDT paths above. What bounds that is the
/// owner-set external limits: `maxExternalPerDeposit` per payout, and `maxExternalPerDay` - an
/// allowance that refills continuously at that much per 24 hours, so a stolen relayer key can take
/// at most about one day's allowance before the owner notices and pauses. Both start at zero, so
/// the external path pays nothing until the owner opts in with `setExternalLimits`. Keep the
/// relayer key and the custody it implies (the AssetHub/Ethereum gateways' owner keys) secured
/// accordingly.
///
/// `rate` is XON paid out per 1 whole USDT, expressed the way Solidity sees native value on
/// Xode: `pallet_revive`'s `NativeToEthRatio` (1e18/1e12 = 1_000_000) rescales the chain's
/// 12-decimal native `Balance` up to standard 18-decimal EVM/"ether" units at the call boundary,
/// so `msg.value`/`.balance`/`.call{value:}` all use 18 decimals here regardless of the chain's
/// underlying native decimals. USDT (a 6-decimal pallet-assets token) is unaffected by that
/// ratio - its precompile reports raw pallet-assets balances. E.g. rate = 5 ether pays 5 XON/USDT.
contract XonVendingMachine {
    IERC20 public immutable usdt;
    address public owner;
    address public relayer;
    uint256 public rate;
    bool public paused;
    uint256 public accountedUsdt;

    /// Limits on `settleExternalPurchase`, in raw USDT units - see the contract docs.
    uint256 public maxExternalPerDeposit;
    uint256 public maxExternalPerDay;
    /// The external allowance as of `_externalAllowanceAt`; `externalAvailable()` adds the refill since.
    uint256 private _externalAllowance;
    uint256 private _externalAllowanceAt;

    uint256 private constant USDT_SCALE = 1e6;
    uint256 private constant EXTERNAL_WINDOW = 1 days;
    uint256 private _locked;

    mapping(bytes32 => bool) public settledDeposits;
    mapping(bytes32 => bool) public externalSettledDeposits;

    event Bought(address indexed buyer, uint256 usdtIn, uint256 xonOut);
    event Settled(address indexed buyer, bytes32 indexed depositTxHash, uint256 usdtIn, uint256 xonOut);
    event ExternalSettled(
        address indexed buyer,
        string sourceChain,
        bytes32 indexed depositId,
        uint256 usdtIn,
        uint256 xonOut
    );
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event PausedSet(bool paused);
    event XonWithdrawn(address indexed to, uint256 amount);
    event UsdtWithdrawn(address indexed to, uint256 amount);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event RelayerUpdated(address indexed previousRelayer, address indexed newRelayer);
    event ExternalLimitsSet(uint256 maxPerDeposit, uint256 maxPerDay);
    event Deposited(address indexed from, uint256 amount);

    error NotOwner();
    error NotRelayer();
    error IsPaused();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientReserve();
    error UsdtTransferFailed();
    error XonTransferFailed();
    error Reentrant();
    error AlreadySettled();
    error UnverifiedDeposit();
    error AlreadyExternallySettled();
    error OverExternalDepositLimit();
    error OverExternalDailyLimit();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer();
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

    constructor(address usdtToken, address owner_, uint256 initialRate, address relayer_) {
        if (usdtToken == address(0) || owner_ == address(0)) revert ZeroAddress();
        usdt = IERC20(usdtToken);
        owner = owner_;
        rate = initialRate;
        relayer = relayer_;
    }

    /// Lets the owner (or anyone) top up the native XON reserve by sending value directly.
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// Buys XON with `usdtAmount` USDT at the current `rate`. Requires a prior
    /// `usdt.approve(address(this), usdtAmount)` from the caller.
    function buy(uint256 usdtAmount) external whenNotPaused nonReentrant {
        if (usdtAmount == 0) revert ZeroAmount();

        uint256 xonOut = quote(usdtAmount);
        if (xonOut == 0) revert ZeroAmount();
        if (address(this).balance < xonOut) revert InsufficientReserve();

        if (!usdt.transferFrom(msg.sender, address(this), usdtAmount)) {
            revert UsdtTransferFailed();
        }
        accountedUsdt += usdtAmount;

        (bool sent, ) = msg.sender.call{value: xonOut}("");
        if (!sent) revert XonTransferFailed();

        emit Bought(msg.sender, usdtAmount, xonOut);
    }

    /// Settles a purchase for a buyer who paid by sending USDT directly (`usdt.transfer`) instead
    /// of going through `buy`. Callable only by `relayer`, which is expected to call this once per
    /// genuine incoming `Transfer` it observes, identified by that transfer's transaction hash.
    /// Safe against a malicious/compromised relayer manufacturing payouts: this only ever succeeds
    /// while `accountedUsdt + usdtAmount` stays within the contract's *actual* USDT balance, so a
    /// bad relayer can at most misattribute a real deposit, never invent one.
    function settlePurchase(
        address buyer,
        uint256 usdtAmount,
        bytes32 depositTxHash
    ) external onlyRelayer whenNotPaused nonReentrant {
        if (buyer == address(0)) revert ZeroAddress();
        if (usdtAmount == 0) revert ZeroAmount();
        if (settledDeposits[depositTxHash]) revert AlreadySettled();
        if (accountedUsdt + usdtAmount > usdt.balanceOf(address(this))) revert UnverifiedDeposit();

        uint256 xonOut = quote(usdtAmount);
        if (xonOut == 0) revert ZeroAmount();
        if (address(this).balance < xonOut) revert InsufficientReserve();

        settledDeposits[depositTxHash] = true;
        accountedUsdt += usdtAmount;

        (bool sent, ) = buyer.call{value: xonOut}("");
        if (!sent) revert XonTransferFailed();

        emit Settled(buyer, depositTxHash, usdtAmount, xonOut);
    }

    /// Settles a purchase paid on a *different* chain - `sourceChain` is a free-form label
    /// ("assethub", "ethereum") for logs/events, and `depositId` should be something the relayer
    /// derives uniquely from that chain's deposit (e.g. `keccak256(abi.encode(sourceChain, txHash))`)
    /// so ids from different sources can never collide. Unlike `settlePurchase`, there is no local
    /// USDT balance to check this against - see the contract-level docs on the trust this implies.
    /// Bounded by the external limits: over `maxExternalPerDeposit` reverts
    /// `OverExternalDepositLimit` (the owner has to raise it for that deposit to ever be paid); over
    /// what's left of the daily allowance reverts `OverExternalDailyLimit` (it refills over time).
    function settleExternalPurchase(
        address buyer,
        uint256 usdtAmount,
        string calldata sourceChain,
        bytes32 depositId
    ) external onlyRelayer whenNotPaused nonReentrant {
        if (buyer == address(0)) revert ZeroAddress();
        if (usdtAmount == 0) revert ZeroAmount();
        if (externalSettledDeposits[depositId]) revert AlreadyExternallySettled();
        if (usdtAmount > maxExternalPerDeposit) revert OverExternalDepositLimit();
        uint256 available = externalAvailable();
        if (usdtAmount > available) revert OverExternalDailyLimit();

        uint256 xonOut = quote(usdtAmount);
        if (xonOut == 0) revert ZeroAmount();
        if (address(this).balance < xonOut) revert InsufficientReserve();

        externalSettledDeposits[depositId] = true;
        _externalAllowance = available - usdtAmount;
        _externalAllowanceAt = block.timestamp;

        (bool sent, ) = buyer.call{value: xonOut}("");
        if (!sent) revert XonTransferFailed();

        emit ExternalSettled(buyer, sourceChain, depositId, usdtAmount, xonOut);
    }

    /// Amount of XON `usdtAmount` USDT would currently buy, at zero cost/side effects.
    function quote(uint256 usdtAmount) public view returns (uint256) {
        return (usdtAmount * rate) / USDT_SCALE;
    }

    /// USDT that `settleExternalPurchase` can still pay for right now: the allowance left after
    /// recent payouts, refilled at `maxExternalPerDay` per 24 hours, never above `maxExternalPerDay`.
    function externalAvailable() public view returns (uint256) {
        uint256 cap = maxExternalPerDay;
        uint256 allowance = _externalAllowance;
        uint256 elapsed = block.timestamp - _externalAllowanceAt;
        if (allowance >= cap || elapsed >= EXTERNAL_WINDOW) return cap;
        // cap * elapsed / EXTERNAL_WINDOW, split up so even cap = type(uint256).max can't overflow.
        uint256 refill = (cap / EXTERNAL_WINDOW) * elapsed + ((cap % EXTERNAL_WINDOW) * elapsed) / EXTERNAL_WINDOW;
        return refill >= cap - allowance ? cap : allowance + refill;
    }

    /// Sets the external limits (raw USDT units; 0 turns the external path off). What's been paid
    /// out against the daily allowance carries over: raising the cap adds the difference to what's
    /// available now, lowering it takes it away.
    function setExternalLimits(uint256 maxPerDeposit, uint256 maxPerDay) external onlyOwner {
        uint256 used = maxExternalPerDay - externalAvailable();
        maxExternalPerDeposit = maxPerDeposit;
        maxExternalPerDay = maxPerDay;
        _externalAllowance = maxPerDay > used ? maxPerDay - used : 0;
        _externalAllowanceAt = block.timestamp;
        emit ExternalLimitsSet(maxPerDeposit, maxPerDay);
    }

    function setRate(uint256 newRate) external onlyOwner {
        emit RateUpdated(rate, newRate);
        rate = newRate;
    }

    function setRelayer(address newRelayer) external onlyOwner {
        emit RelayerUpdated(relayer, newRelayer);
        relayer = newRelayer;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function withdrawXon(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (address(this).balance < amount) revert InsufficientReserve();
        (bool sent, ) = to.call{value: amount}("");
        if (!sent) revert XonTransferFailed();
        emit XonWithdrawn(to, amount);
    }

    /// Rescues USDT sitting in the contract (e.g. surplus beyond what buyers paid for).
    /// Draws down `accountedUsdt` first so `settlePurchase`'s balance check stays meaningful
    /// after a withdrawal instead of being permanently blocked by funds that already left.
    function withdrawUsdt(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        accountedUsdt -= amount > accountedUsdt ? accountedUsdt : amount;
        if (!usdt.transfer(to, amount)) revert UsdtTransferFailed();
        emit UsdtWithdrawn(to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IXcm, XcmSwap} from "./XcmSwap.sol";
import {Custodial} from "./Custodial.sol";

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
/// to verify against. Instead, an external payout needs `attestationThreshold` of the owner-appointed
/// attesters - independent relayers, each watching the source chains with its own key and RPCs - to
/// vote for that exact deposit (`attestExternalPurchase` / `attestExternalSwap`); only then can an
/// attester execute it. With a threshold above one, a single stolen relayer key can't manufacture a
/// payout. Votes are for the deposit's exact parameters, so attesters that disagree never add up.
/// What bounds a quorum gone bad is the owner-set external limits: `maxExternalPerDeposit` per payout, and `maxExternalPerDay` - an
/// allowance that refills continuously at that much per 24 hours, so a stolen relayer key can take
/// at most about one day's allowance before the owner notices and pauses. Both start at zero, so
/// the external path pays nothing until the owner opts in with `setExternalLimits`. A deposit the
/// owner refunds on its source chain is first cancelled here (`cancelExternalDeposit`, which fails
/// if it was already paid), so it can never be both refunded and paid.
///
/// Per-address limits (`maxPerAddressPerDay`) cap what any one buyer / beneficiary takes per day
/// across every path, so one party can't use up the shared daily allowances alone. The fixed-rate
/// paths (`buy`, `settlePurchase`, `settleExternalPurchase`) can be paused on their own - by the
/// owner, the guardian, or the rate keeper when the DEX price runs away from `rate` - while the
/// market-price swap keeps working.
///
/// `settleExternalSwap` is the market-price version of `settleExternalPurchase`: instead of paying
/// XON from the reserve at `rate`, it spends the same amount of USDT from this contract's own
/// USDT inventory on Xode, swaps it for XON through Xode's DEX pool (via the XCM precompile and
/// the runtime's XCM `AssetExchanger`), and pays the buyer whatever the swap returned, provided it
/// is at least the buyer's `minXonOut`. It's bounded by the same external limits and trusts the
/// relayer the same way, but there's no XON reserve to drain at a stale rate, and the price is the
/// pool's. It only ever spends `accountedUsdt` - USDT already paid for by completed purchases or
/// added with `fundUsdtInventory` - never a native deposit that hasn't been settled yet.
///
/// The fixed `rate` can drift from the DEX price, and anyone can then buy here and sell there.
/// Two things bound that: the Xode-native paths (`buy`, `settlePurchase`) have their own
/// per-purchase limit and refilling daily allowance (`setNativeLimits`, starting at zero like the
/// external ones), and an optional `rateKeeper` - a key that isn't the owner - may move `rate`
/// toward the market by at most `maxRateStepBps` per `minRateUpdateInterval` (`updateRate`).
///
/// `rate` is XON paid out per 1 whole USDT, expressed the way Solidity sees native value on
/// Xode: `pallet_revive`'s `NativeToEthRatio` (1e18/1e12 = 1_000_000) rescales the chain's
/// 12-decimal native `Balance` up to standard 18-decimal EVM/"ether" units at the call boundary,
/// so `msg.value`/`.balance`/`.call{value:}` all use 18 decimals here regardless of the chain's
/// underlying native decimals. USDT (a 6-decimal pallet-assets token) is unaffected by that
/// ratio - its precompile reports raw pallet-assets balances. E.g. rate = 5 ether pays 5 XON/USDT.
contract XonVendingMachine is Custodial {
    IERC20 public immutable usdt;
    address public relayer;
    uint256 public rate;
    uint256 public accountedUsdt;

    /// Limits on `settleExternalPurchase`, in raw USDT units - see the contract docs.
    uint256 public maxExternalPerDeposit;
    uint256 public maxExternalPerDay;
    /// The external allowance as of `_externalAllowanceAt`; `externalAvailable()` adds the refill since.
    uint256 private _externalAllowance;
    uint256 private _externalAllowanceAt;

    /// Limits on the Xode-native paths (`buy`, `settlePurchase`), in raw USDT units, working like
    /// the external ones. They bound what arbitrage against the fixed `rate` can take when the DEX
    /// price moves away from it. Both start at zero: native purchases are off until the owner sets them.
    uint256 public maxNativePerPurchase;
    uint256 public maxNativePerDay;
    uint256 private _nativeAllowance;
    uint256 private _nativeAllowanceAt;

    /// May nudge `rate` toward the market (`updateRate`), by at most `maxRateStepBps` per update and
    /// at most once per `minRateUpdateInterval` seconds - so a keeper key on a server can track the
    /// DEX price without being able to move the rate far or fast if it's stolen. Unset: no keeper.
    address public rateKeeper;
    uint256 public maxRateStepBps;
    uint256 public minRateUpdateInterval;
    uint256 public lastRateUpdate;

    /// Independent relayers whose votes an external payout needs - see the contract docs.
    mapping(address => bool) public isAttester;
    uint256 public attesterCount;
    uint256 public attestationThreshold;
    /// Bumped when an attester is removed, so votes it cast on still-open deposits stop counting.
    uint256 public attesterEpoch;
    /// keccak256(epoch, depositId) -> attester -> voted (once per deposit, whatever the parameters).
    mapping(bytes32 => mapping(address => bool)) private _attested;
    /// keccak256(keccak256(epoch, depositId), parameters) -> votes.
    mapping(bytes32 => uint256) private _votes;
    /// Deposits the owner cancelled before refunding them on their source chain.
    mapping(bytes32 => bool) public externalCancelled;

    /// Per buyer / beneficiary, across all paths, in raw USDT units; 0 = no per-address limit.
    uint256 public maxPerAddressPerDay;
    mapping(address => uint256) private _addressAllowance;
    mapping(address => uint256) private _addressAllowanceAt;

    /// The fixed-rate paths' own pause, set by the owner / guardian, or by the rate keeper.
    bool public fixedRatePausedByOwner;
    bool public fixedRatePausedByKeeper;

    uint256 private constant USDT_SCALE = 1e6;
    /// `pallet_revive`'s `NativeToEthRatio` on Xode: 1 planck (XON's 12-decimal native unit) is
    /// 1e6 of the 18-decimal units Solidity sees.
    uint256 private constant NATIVE_TO_ETH_RATIO = 1e6;
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
    event XonWithdrawn(address indexed to, uint256 amount);
    event UsdtWithdrawn(address indexed to, uint256 amount);
    event RelayerUpdated(address indexed previousRelayer, address indexed newRelayer);
    event ExternalLimitsSet(uint256 maxPerDeposit, uint256 maxPerDay);
    event NativeLimitsSet(uint256 maxPerPurchase, uint256 maxPerDay);
    event RateKeeperSet(address indexed keeper, uint256 maxStepBps, uint256 minInterval);
    event Deposited(address indexed from, uint256 amount);
    event ExternalSwapSettled(
        address indexed buyer,
        string sourceChain,
        bytes32 indexed depositId,
        uint256 usdtIn,
        uint256 xonOut
    );
    event UsdtInventoryFunded(address indexed from, uint256 amount);
    event ExternalAttested(bytes32 indexed depositId, address indexed attester, bytes32 params, uint256 votes);
    event AttesterAdded(address indexed attester);
    event AttesterRemoved(address indexed attester);
    event AttestationThresholdSet(uint256 threshold);
    event DepositCancelled(bytes32 indexed depositId);
    event AddressLimitSet(uint256 maxPerDay);
    event FixedRatePauseSet(bool byOwner, bool byKeeper);

    error NotRelayer();
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
    error OverNativePurchaseLimit();
    error OverNativeDailyLimit();
    error NotRateKeeper();
    error RateStepTooLarge();
    error RateUpdateTooSoon();
    error InsufficientUsdtInventory();
    error SlippageExceeded();
    error NotAttester();
    error AlreadyAttester();
    error AlreadyAttested();
    error AwaitingQuorum();
    error InvalidThreshold();
    error DepositIsCancelled();
    error OverAddressDailyLimit();
    error FixedRatePaused();

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer();
        _;
    }

    modifier whenFixedRateOpen() {
        if (fixedRatePaused()) revert FixedRatePaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked == 1) revert Reentrant();
        _locked = 1;
        _;
        _locked = 0;
    }

    /// `treasury_` is the only place the owner can withdraw XON / USDT to (a cold multisig in
    /// production) and `guardian_` the key or multisig that can pause and veto treasury changes -
    /// see `Custodial`. Both may start as `owner_` in development.
    constructor(address usdtToken, address owner_, uint256 initialRate, address relayer_, address treasury_, address guardian_)
        Custodial(owner_, treasury_, guardian_)
    {
        if (usdtToken == address(0)) revert ZeroAddress();
        usdt = IERC20(usdtToken);
        rate = initialRate;
        relayer = relayer_;
        attestationThreshold = 1;
        if (relayer_ != address(0)) {
            isAttester[relayer_] = true;
            attesterCount = 1;
            emit AttesterAdded(relayer_);
        }
    }

    /// Lets the owner (or anyone) top up the native XON reserve by sending value directly.
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// Buys XON with `usdtAmount` USDT at the current `rate`. Requires a prior
    /// `usdt.approve(address(this), usdtAmount)` from the caller.
    function buy(uint256 usdtAmount) external whenNotPaused whenFixedRateOpen nonReentrant {
        if (usdtAmount == 0) revert ZeroAmount();
        _useNativeAllowance(usdtAmount);
        _useAddressAllowance(msg.sender, usdtAmount);

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
    ) external onlyRelayer whenNotPaused whenFixedRateOpen nonReentrant {
        if (buyer == address(0)) revert ZeroAddress();
        if (usdtAmount == 0) revert ZeroAmount();
        if (settledDeposits[depositTxHash]) revert AlreadySettled();
        if (accountedUsdt + usdtAmount > usdt.balanceOf(address(this))) revert UnverifiedDeposit();
        _useNativeAllowance(usdtAmount);
        _useAddressAllowance(buyer, usdtAmount);

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
    /// Needs `attestationThreshold` votes for exactly these parameters (`attestExternalPurchase`)
    /// and is executed by an attester; without a quorum it reverts `AwaitingQuorum`.
    /// Bounded by the external limits: over `maxExternalPerDeposit` reverts
    /// `OverExternalDepositLimit` (the owner has to raise it for that deposit to ever be paid); over
    /// what's left of the daily allowance reverts `OverExternalDailyLimit` (it refills over time).
    function settleExternalPurchase(
        address buyer,
        uint256 usdtAmount,
        string calldata sourceChain,
        bytes32 depositId
    ) external whenNotPaused whenFixedRateOpen nonReentrant {
        _requireOpen(buyer, usdtAmount, depositId);
        _requireQuorum(depositId, purchaseParams(buyer, usdtAmount, sourceChain));
        _useExternalAllowance(buyer, usdtAmount);

        uint256 xonOut = quote(usdtAmount);
        if (xonOut == 0) revert ZeroAmount();
        if (address(this).balance < xonOut) revert InsufficientReserve();

        externalSettledDeposits[depositId] = true;

        (bool sent, ) = buyer.call{value: xonOut}("");
        if (!sent) revert XonTransferFailed();

        emit ExternalSettled(buyer, sourceChain, depositId, usdtAmount, xonOut);
    }

    /// Like `settleExternalPurchase`, but at the DEX's market price instead of `rate`: swaps
    /// `usdtAmount` of this contract's USDT inventory for XON through Xode's pool and pays the buyer
    /// everything the swap returned. `minXonOut` (18-decimal units, like `rate`) is the least the
    /// buyer accepts; it should come from the buyer's own deposit, not the relayer. If the pool
    /// can't give that much, the whole call reverts and nothing is marked settled, so the deposit
    /// can be retried or refunded. Same external limits and quorum (`attestExternalSwap`) as
    /// `settleExternalPurchase`; the two share `externalSettledDeposits`, so a deposit can only ever
    /// be paid one way.
    function settleExternalSwap(
        address buyer,
        uint256 usdtAmount,
        uint256 minXonOut,
        string calldata sourceChain,
        bytes32 depositId
    ) external whenNotPaused nonReentrant {
        if (minXonOut == 0) revert ZeroAmount();
        _requireOpen(buyer, usdtAmount, depositId);
        _requireQuorum(depositId, swapParams(buyer, usdtAmount, minXonOut, sourceChain));
        if (usdtAmount > accountedUsdt) revert InsufficientUsdtInventory();
        _useExternalAllowance(buyer, usdtAmount);

        externalSettledDeposits[depositId] = true;
        accountedUsdt -= usdtAmount;

        uint256 xonOut = _swapUsdtForXon(usdtAmount, minXonOut);
        (bool sent, ) = buyer.call{value: xonOut}("");
        if (!sent) revert XonTransferFailed();

        emit ExternalSwapSettled(buyer, sourceChain, depositId, usdtAmount, xonOut);
    }

    // --- attestations: an external payout needs a quorum of attesters -----------------------------

    /// An attester's vote that a fixed-rate deposit with exactly these parameters happened.
    function attestExternalPurchase(address buyer, uint256 usdtAmount, string calldata sourceChain, bytes32 depositId)
        external
        whenNotPaused
    {
        _requireOpen(buyer, usdtAmount, depositId);
        _attest(depositId, purchaseParams(buyer, usdtAmount, sourceChain));
    }

    /// An attester's vote that a market-price deposit with exactly these parameters happened.
    function attestExternalSwap(
        address buyer,
        uint256 usdtAmount,
        uint256 minXonOut,
        string calldata sourceChain,
        bytes32 depositId
    ) external whenNotPaused {
        if (minXonOut == 0) revert ZeroAmount();
        _requireOpen(buyer, usdtAmount, depositId);
        _attest(depositId, swapParams(buyer, usdtAmount, minXonOut, sourceChain));
    }

    function purchaseParams(address buyer, uint256 usdtAmount, string calldata sourceChain) public pure returns (bytes32) {
        return keccak256(abi.encode("purchase", buyer, usdtAmount, sourceChain));
    }

    function swapParams(address buyer, uint256 usdtAmount, uint256 minXonOut, string calldata sourceChain)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("swap", buyer, usdtAmount, minXonOut, sourceChain));
    }

    /// Votes so far (from current attesters) for `depositId` with parameters `params`.
    function attestations(bytes32 depositId, bytes32 params) public view returns (uint256) {
        return _votes[keccak256(abi.encode(_round(depositId), params))];
    }

    function hasAttested(bytes32 depositId, address attester) external view returns (bool) {
        return _attested[_round(depositId)][attester];
    }

    function _round(bytes32 depositId) private view returns (bytes32) {
        return keccak256(abi.encode(attesterEpoch, depositId));
    }

    function _requireOpen(address buyer, uint256 usdtAmount, bytes32 depositId) private view {
        if (buyer == address(0)) revert ZeroAddress();
        if (usdtAmount == 0) revert ZeroAmount();
        if (externalSettledDeposits[depositId]) revert AlreadyExternallySettled();
        if (externalCancelled[depositId]) revert DepositIsCancelled();
    }

    function _attest(bytes32 depositId, bytes32 params) private {
        if (!isAttester[msg.sender]) revert NotAttester();
        bytes32 round = _round(depositId);
        if (_attested[round][msg.sender]) revert AlreadyAttested();
        _attested[round][msg.sender] = true;
        uint256 votes = ++_votes[keccak256(abi.encode(round, params))];
        emit ExternalAttested(depositId, msg.sender, params, votes);
    }

    /// Lets an attester execute a payout once enough attesters voted for exactly these parameters.
    /// Execution stays with attesters (not anyone) so nobody can pick the moment of a market-price
    /// swap to sandwich it inside one transaction.
    function _requireQuorum(bytes32 depositId, bytes32 params) private view {
        if (!isAttester[msg.sender]) revert NotAttester();
        if (attestations(depositId, params) < attestationThreshold) revert AwaitingQuorum();
    }

    /// External limits plus the buyer's per-address limit, checked and used together.
    function _useExternalAllowance(address buyer, uint256 usdtAmount) private {
        if (usdtAmount > maxExternalPerDeposit) revert OverExternalDepositLimit();
        uint256 available = externalAvailable();
        if (usdtAmount > available) revert OverExternalDailyLimit();
        _externalAllowance = available - usdtAmount;
        _externalAllowanceAt = block.timestamp;
        _useAddressAllowance(buyer, usdtAmount);
    }

    /// Marks an unpaid external deposit as never to be paid, so it can be refunded on its source
    /// chain without any risk of also paying it here. Reverts if it was already paid.
    function cancelExternalDeposit(bytes32 depositId) external onlyOwner {
        if (externalSettledDeposits[depositId]) revert AlreadyExternallySettled();
        if (externalCancelled[depositId]) revert DepositIsCancelled();
        externalCancelled[depositId] = true;
        emit DepositCancelled(depositId);
    }

    /// Adding an attester is a queued change (see `Custodial`).
    function addAttester(address attester) external onlyOwner {
        _requireQueued();
        if (attester == address(0)) revert ZeroAddress();
        if (isAttester[attester]) revert AlreadyAttester();
        isAttester[attester] = true;
        attesterCount++;
        emit AttesterAdded(attester);
    }

    /// Removing one is instant, and the guardian can do it too (a key thought stolen) - as long as
    /// enough attesters remain to reach the threshold. Its votes on open deposits stop counting.
    function removeAttester(address attester) external {
        if (msg.sender != owner && msg.sender != guardian) revert NotGuardian();
        if (!isAttester[attester]) revert NotAttester();
        if (attesterCount - 1 < attestationThreshold) revert InvalidThreshold();
        isAttester[attester] = false;
        attesterCount--;
        attesterEpoch++;
        emit AttesterRemoved(attester);
    }

    /// Raising the threshold is instant; lowering it is a queued change.
    function setAttestationThreshold(uint256 threshold) external onlyOwner {
        if (threshold == 0 || threshold > attesterCount) revert InvalidThreshold();
        if (threshold < attestationThreshold) _requireQueued();
        attestationThreshold = threshold;
        emit AttestationThresholdSet(threshold);
    }

    // --- per-address limit ----------------------------------------------------------------------

    /// USDT `account` can still buy / be paid for right now (max uint when there's no per-address limit).
    function addressAvailable(address account) public view returns (uint256) {
        if (maxPerAddressPerDay == 0) return type(uint256).max;
        uint256 at = _addressAllowanceAt[account];
        if (at == 0) return maxPerAddressPerDay; // never used: the full allowance
        return _available(maxPerAddressPerDay, _addressAllowance[account], at);
    }

    function _useAddressAllowance(address account, uint256 usdtAmount) private {
        if (maxPerAddressPerDay == 0) return;
        uint256 available = addressAvailable(account);
        if (usdtAmount > available) revert OverAddressDailyLimit();
        _addressAllowance[account] = available - usdtAmount;
        _addressAllowanceAt[account] = block.timestamp;
    }

    /// Tightening (or setting a first limit) is instant; loosening or removing it is a queued change.
    function setAddressLimit(uint256 maxPerDay) external onlyOwner {
        uint256 old = maxPerAddressPerDay;
        if (old != 0 && (maxPerDay == 0 || maxPerDay > old)) _requireQueued();
        maxPerAddressPerDay = maxPerDay;
        emit AddressLimitSet(maxPerDay);
    }

    // --- fixed-rate pause -------------------------------------------------------------------------

    function fixedRatePaused() public view returns (bool) {
        return fixedRatePausedByOwner || fixedRatePausedByKeeper;
    }

    /// The owner pauses or resumes the fixed-rate paths; the guardian can only pause them.
    function setFixedRatePaused(bool paused_) external {
        if (msg.sender != owner && !(msg.sender == guardian && paused_)) revert NotGuardian();
        fixedRatePausedByOwner = paused_;
        emit FixedRatePauseSet(fixedRatePausedByOwner, fixedRatePausedByKeeper);
    }

    /// The rate keeper's own pause, for while the DEX price is too far from `rate` to follow it
    /// safely. It can lift only this one, never the owner's.
    function keeperPauseFixedRate(bool paused_) external {
        if (msg.sender != rateKeeper || rateKeeper == address(0)) revert NotRateKeeper();
        fixedRatePausedByKeeper = paused_;
        emit FixedRatePauseSet(fixedRatePausedByOwner, fixedRatePausedByKeeper);
    }

    /// Swaps `usdtAmount` of this contract's USDT for at least `minXonOut` XON on Xode's DEX. The
    /// XCM program deposits the XON into this contract's own account; returns what arrived.
    function _swapUsdtForXon(uint256 usdtAmount, uint256 minXonOut) private returns (uint256 xonOut) {
        uint256 balanceBefore = address(this).balance;
        uint256 minPlanck = (minXonOut + NATIVE_TO_ETH_RATIO - 1) / NATIVE_TO_ETH_RATIO;
        bytes memory message =
            XcmSwap.swapUsdtForXon(usdtAmount, minPlanck, XcmSwap.contractAccount(address(this)));
        IXcm xcm = IXcm(XcmSwap.XCM_PRECOMPILE);
        xcm.execute(message, xcm.weighMessage(message));
        xonOut = address(this).balance - balanceBefore;
        // The XCM program already enforces the minimum; this guards against it paying elsewhere.
        if (xonOut < minXonOut) revert SlippageExceeded();
    }

    /// Adds USDT to the inventory `settleExternalSwap` spends from (needs a prior
    /// `usdt.approve(address(this), amount)`). A plain transfer would look like a native purchase
    /// waiting to be settled, so inventory goes through here and is counted in `accountedUsdt`.
    function fundUsdtInventory(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!usdt.transferFrom(msg.sender, address(this), amount)) revert UsdtTransferFailed();
        accountedUsdt += amount;
        emit UsdtInventoryFunded(msg.sender, amount);
    }

    /// Amount of XON `usdtAmount` USDT would currently buy, at zero cost/side effects.
    function quote(uint256 usdtAmount) public view returns (uint256) {
        return (usdtAmount * rate) / USDT_SCALE;
    }

    /// USDT that `settleExternalPurchase` can still pay for right now: the allowance left after
    /// recent payouts, refilled at `maxExternalPerDay` per 24 hours, never above `maxExternalPerDay`.
    function externalAvailable() public view returns (uint256) {
        return _available(maxExternalPerDay, _externalAllowance, _externalAllowanceAt);
    }

    /// USDT that `buy` / `settlePurchase` can still take right now, refilled the same way.
    function nativeAvailable() public view returns (uint256) {
        return _available(maxNativePerDay, _nativeAllowance, _nativeAllowanceAt);
    }

    /// `allowance` as of `at`, refilled at `cap` per 24 hours, never above `cap`.
    function _available(uint256 cap, uint256 allowance, uint256 at) private view returns (uint256) {
        uint256 elapsed = block.timestamp - at;
        if (allowance >= cap || elapsed >= EXTERNAL_WINDOW) return cap;
        // cap * elapsed / EXTERNAL_WINDOW, split up so even cap = type(uint256).max can't overflow.
        uint256 refill = (cap / EXTERNAL_WINDOW) * elapsed + ((cap % EXTERNAL_WINDOW) * elapsed) / EXTERNAL_WINDOW;
        return refill >= cap - allowance ? cap : allowance + refill;
    }

    /// Spends `usdtAmount` of the native allowance: over the per-purchase limit reverts
    /// `OverNativePurchaseLimit` (never payable until the owner raises it), over what's left of the
    /// daily allowance reverts `OverNativeDailyLimit` (it refills over time).
    function _useNativeAllowance(uint256 usdtAmount) private {
        if (usdtAmount > maxNativePerPurchase) revert OverNativePurchaseLimit();
        uint256 available = nativeAvailable();
        if (usdtAmount > available) revert OverNativeDailyLimit();
        _nativeAllowance = available - usdtAmount;
        _nativeAllowanceAt = block.timestamp;
    }

    /// Sets the native limits (raw USDT units; 0 turns `buy` / `settlePurchase` off), carrying over
    /// what's been used today the same way `setExternalLimits` does.
    function setNativeLimits(uint256 maxPerPurchase, uint256 maxPerDay) external onlyOwner {
        if (maxPerPurchase > maxNativePerPurchase || maxPerDay > maxNativePerDay) _requireQueued();
        uint256 used = maxNativePerDay - nativeAvailable();
        maxNativePerPurchase = maxPerPurchase;
        maxNativePerDay = maxPerDay;
        _nativeAllowance = maxPerDay > used ? maxPerDay - used : 0;
        _nativeAllowanceAt = block.timestamp;
        emit NativeLimitsSet(maxPerPurchase, maxPerDay);
    }

    /// Sets the external limits (raw USDT units; 0 turns the external path off). What's been paid
    /// out against the daily allowance carries over: raising the cap adds the difference to what's
    /// available now, lowering it takes it away.
    function setExternalLimits(uint256 maxPerDeposit, uint256 maxPerDay) external onlyOwner {
        if (maxPerDeposit > maxExternalPerDeposit || maxPerDay > maxExternalPerDay) _requireQueued();
        uint256 used = maxExternalPerDay - externalAvailable();
        maxExternalPerDeposit = maxPerDeposit;
        maxExternalPerDay = maxPerDay;
        _externalAllowance = maxPerDay > used ? maxPerDay - used : 0;
        _externalAllowanceAt = block.timestamp;
        emit ExternalLimitsSet(maxPerDeposit, maxPerDay);
    }

    /// Lowering the rate (less XON per USDT) is instant; raising it is a queued change.
    function setRate(uint256 newRate) external onlyOwner {
        if (newRate > rate) _requireQueued();
        emit RateUpdated(rate, newRate);
        rate = newRate;
        lastRateUpdate = block.timestamp;
    }

    /// Appoints the keeper allowed to call `updateRate`, and its bounds (`address(0)` removes it).
    function setRateKeeper(address keeper, uint256 maxStepBps, uint256 minInterval) external onlyOwner {
        if (keeper != address(0)) _requireQueued();
        if (keeper == address(0)) fixedRatePausedByKeeper = false;
        rateKeeper = keeper;
        maxRateStepBps = maxStepBps;
        minRateUpdateInterval = minInterval;
        emit RateKeeperSet(keeper, maxStepBps, minInterval);
    }

    /// The keeper moves `rate` toward the market: by at most `maxRateStepBps` of the current rate,
    /// and no sooner than `minRateUpdateInterval` after the last change (by anyone).
    function updateRate(uint256 newRate) external {
        if (msg.sender != rateKeeper || rateKeeper == address(0)) revert NotRateKeeper();
        if (newRate == 0) revert ZeroAmount();
        if (block.timestamp < lastRateUpdate + minRateUpdateInterval) revert RateUpdateTooSoon();
        uint256 step = newRate > rate ? newRate - rate : rate - newRate;
        if (step * 10_000 > rate * maxRateStepBps) revert RateStepTooLarge();
        emit RateUpdated(rate, newRate);
        rate = newRate;
        lastRateUpdate = block.timestamp;
    }

    /// The Xode-native settler (`settlePurchase`). Removing it is instant; appointing one is queued.
    function setRelayer(address newRelayer) external onlyOwner {
        if (newRelayer != address(0)) _requireQueued();
        emit RelayerUpdated(relayer, newRelayer);
        relayer = newRelayer;
    }

    /// Moves XON from the reserve to the treasury - the only place it can go.
    function withdrawXon(uint256 amount) external onlyOwner nonReentrant {
        if (address(this).balance < amount) revert InsufficientReserve();
        (bool sent, ) = payable(treasury).call{value: amount}("");
        if (!sent) revert XonTransferFailed();
        emit XonWithdrawn(treasury, amount);
    }

    /// Moves USDT to the treasury (e.g. inventory or proceeds). Draws down `accountedUsdt` first so
    /// `settlePurchase`'s balance check stays meaningful after a withdrawal instead of being
    /// permanently blocked by funds that already left.
    function withdrawUsdt(uint256 amount) external onlyOwner nonReentrant {
        accountedUsdt -= amount > accountedUsdt ? accountedUsdt : amount;
        if (!usdt.transfer(treasury, amount)) revert UsdtTransferFailed();
        emit UsdtWithdrawn(treasury, amount);
    }
}

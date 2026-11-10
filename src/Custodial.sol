// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Custody rules shared by the contracts that hold users' funds (XonVendingMachine on Xode,
/// EthUsdtGateway on Ethereum / Asset Hub), so they're implemented - and reviewed - once:
///  - Two-step ownership: `transferOwnership` only nominates; the nominee takes over by calling
///    `acceptOwnership`. A mistyped or wrongly derived owner address (say, a Safe on the wrong
///    chain) can never take - or lose - the contract.
///  - A treasury: the only place the owner can move funds to (the inheriting contract's withdraw
///    functions pay `treasury`). Changing it waits `TREASURY_DELAY`.
///  - A guardian, meant to be a different key or multisig than the owner: it can pause the contract
///    and cancel a pending treasury change - nothing else - and only it can hand its role on, so a
///    compromised owner can't redirect funds before the guardian can step in.
///  - A change queue for settings that could hand out funds (raising limits or the rate, changing
///    who may settle payouts, ...): once setup is finished, such a call only goes through if its
///    exact calldata was queued with `queueChange` at least `CHANGE_DELAY` earlier, and the guardian
///    can cancel it meanwhile. So taking over the owner (say, two of an ops Safe's signers) buys an
///    attacker 48 public hours, not an instant drain. Changes that only make things safer
///    (lowering a limit, pausing) stay instant.
abstract contract Custodial {
    address public owner;
    /// Nominated by `transferOwnership`; becomes owner once it calls `acceptOwnership`.
    address public pendingOwner;
    bool public paused;

    address public treasury;
    address public pendingTreasury;
    uint256 public pendingTreasuryReadyAt;
    uint256 public constant TREASURY_DELAY = 2 days;

    address public guardian;

    /// Until `finishSetup` (or the first `transferOwnership`), the deployer configures the contract
    /// freely; after it, the risky setters need a queued change.
    bool public setupFinished;
    uint256 public constant CHANGE_DELAY = 2 days;
    /// keccak256(calldata) of a queued call -> when it may run (0: not queued).
    mapping(bytes32 => uint256) public queuedChangeReadyAt;

    event PausedSet(bool paused);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event TreasuryChangeProposed(address indexed treasury, uint256 readyAt);
    event TreasuryChangeCancelled(address indexed treasury);
    event TreasuryChanged(address indexed previousTreasury, address indexed treasury);
    event GuardianTransferred(address indexed previousGuardian, address indexed guardian);
    event SetupFinished();
    event ChangeQueued(bytes32 indexed id, bytes call, uint256 readyAt);
    event ChangeCancelled(bytes32 indexed id);
    event ChangeApplied(bytes32 indexed id);

    error NotOwner();
    error NotPendingOwner();
    error NotGuardian();
    error IsPaused();
    error ZeroAddress();
    error NoPendingTreasury();
    error TreasuryChangeNotReady();
    error ChangeNotQueued();
    error ChangeNotReady();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    constructor(address owner_, address treasury_, address guardian_) {
        if (owner_ == address(0) || treasury_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        owner = owner_;
        treasury = treasury_;
        guardian = guardian_;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// The guardian can stop the contract (not restart it - that's the owner's `setPaused(false)`).
    function guardianPause() external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = true;
        emit PausedSet(true);
    }

    // --- treasury: changes wait TREASURY_DELAY, and the guardian can stop them ---------------

    function proposeTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        pendingTreasury = newTreasury;
        pendingTreasuryReadyAt = block.timestamp + TREASURY_DELAY;
        emit TreasuryChangeProposed(newTreasury, pendingTreasuryReadyAt);
    }

    function applyTreasury() external onlyOwner {
        address next = pendingTreasury;
        if (next == address(0)) revert NoPendingTreasury();
        if (block.timestamp < pendingTreasuryReadyAt) revert TreasuryChangeNotReady();
        emit TreasuryChanged(treasury, next);
        treasury = next;
        pendingTreasury = address(0);
        pendingTreasuryReadyAt = 0;
    }

    /// The owner withdrawing its own proposal, or the guardian stopping one it didn't expect.
    function cancelTreasuryChange() external {
        if (msg.sender != owner && msg.sender != guardian) revert NotGuardian();
        if (pendingTreasury == address(0)) revert NoPendingTreasury();
        emit TreasuryChangeCancelled(pendingTreasury);
        pendingTreasury = address(0);
        pendingTreasuryReadyAt = 0;
    }

    // --- delayed changes: queued with their exact calldata, cancellable by the guardian ---------

    /// Ends the setup phase: from now on the risky setters need `queueChange`. Irreversible.
    function finishSetup() external onlyOwner {
        _finishSetup();
    }

    function _finishSetup() private {
        if (setupFinished) return;
        setupFinished = true;
        emit SetupFinished();
    }

    /// Queues `call` - the exact calldata of a later call to this contract - to be allowed after
    /// `CHANGE_DELAY`. Its id is `keccak256(call)`; watch `ChangeQueued` to see what's coming.
    function queueChange(bytes calldata call) external onlyOwner {
        bytes32 id = keccak256(call);
        uint256 readyAt = block.timestamp + CHANGE_DELAY;
        queuedChangeReadyAt[id] = readyAt;
        emit ChangeQueued(id, call, readyAt);
    }

    /// The owner withdrawing a queued change, or the guardian stopping one.
    function cancelChange(bytes32 id) external {
        if (msg.sender != owner && msg.sender != guardian) revert NotGuardian();
        if (queuedChangeReadyAt[id] == 0) revert ChangeNotQueued();
        delete queuedChangeReadyAt[id];
        emit ChangeCancelled(id);
    }

    /// Called by a setter for a change that must wait: lets the current call through only if its
    /// calldata was queued and the delay has passed, and uses the queued entry up.
    function _requireQueued() internal {
        if (!setupFinished) return;
        bytes32 id = keccak256(msg.data);
        uint256 readyAt = queuedChangeReadyAt[id];
        if (readyAt == 0) revert ChangeNotQueued();
        if (block.timestamp < readyAt) revert ChangeNotReady();
        delete queuedChangeReadyAt[id];
        emit ChangeApplied(id);
    }

    // --- guardian ---------------------------------------------------------------------------------

    function transferGuardian(address newGuardian) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (newGuardian == address(0)) revert ZeroAddress();
        emit GuardianTransferred(guardian, newGuardian);
        guardian = newGuardian;
    }

    // --- ownership, in two steps ------------------------------------------------------------------

    /// Nominates `newOwner`, who becomes owner by calling `acceptOwnership`. `address(0)` cancels.
    /// Handing the contract over also ends its setup phase.
    function transferOwnership(address newOwner) external onlyOwner {
        _finishSetup();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotPendingOwner();
        emit OwnerTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}

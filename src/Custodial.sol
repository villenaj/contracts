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

    event PausedSet(bool paused);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event TreasuryChangeProposed(address indexed treasury, uint256 readyAt);
    event TreasuryChangeCancelled(address indexed treasury);
    event TreasuryChanged(address indexed previousTreasury, address indexed treasury);
    event GuardianTransferred(address indexed previousGuardian, address indexed guardian);

    error NotOwner();
    error NotPendingOwner();
    error NotGuardian();
    error IsPaused();
    error ZeroAddress();
    error NoPendingTreasury();
    error TreasuryChangeNotReady();

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

    // --- guardian ---------------------------------------------------------------------------------

    function transferGuardian(address newGuardian) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (newGuardian == address(0)) revert ZeroAddress();
        emit GuardianTransferred(guardian, newGuardian);
        guardian = newGuardian;
    }

    // --- ownership, in two steps ------------------------------------------------------------------

    /// Nominates `newOwner`, who becomes owner by calling `acceptOwnership`. `address(0)` cancels.
    function transferOwnership(address newOwner) external onlyOwner {
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Custodial} from "../src/Custodial.sol";
import {EthUsdtGateway} from "../src/ethereum/EthUsdtGateway.sol";
import {XonVendingMachine} from "../src/XonVendingMachine.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// Two-step ownership (gateway + vending), and the gateway's treasury / guardian / refund rules.
contract CustodyHardeningTest is Test {
    EthUsdtGateway gateway;
    XonVendingMachine vending;
    MockUSDT usdt;

    address owner = makeAddr("owner");
    address safe = makeAddr("opsSafe");
    address coldTreasury = makeAddr("coldTreasury");
    address guardian = makeAddr("guardianSafe");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address beneficiary = makeAddr("beneficiary");

    function setUp() public {
        usdt = new MockUSDT();
        gateway = new EthUsdtGateway(address(usdt), owner, owner, owner);
        vending = new XonVendingMachine(address(usdt), owner, 0.2 ether, makeAddr("relayer"), owner, owner);
        vm.startPrank(owner);
        vending.setSource("ethereum", 1, address(0xE7));
        vending.setSource("assethub", 420420419, address(0xA7));
        vm.stopPrank();
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            usdt.mint(who, 100e6);
            vm.prank(who);
            usdt.approve(address(gateway), type(uint256).max);
        }
    }

    function _release(uint256 nonce, address who, uint256 amount) internal {
        uint256[] memory nonces = new uint256[](1);
        address[] memory depositors = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (nonces[0], depositors[0], amounts[0]) = (nonce, who, amount);
        vm.prank(owner);
        gateway.release(nonces, depositors, amounts);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 nonce) {
        nonce = gateway.depositNonce();
        vm.prank(who);
        gateway.deposit(amount, beneficiary, 1);
    }

    // --- two-step ownership --------------------------------------------------------------------

    function test_constructorDefaults() public view {
        assertEq(gateway.owner(), owner);
        assertEq(gateway.treasury(), owner);
        assertEq(gateway.guardian(), owner);
        assertEq(gateway.pendingOwner(), address(0));
    }

    function test_aWrongNomineeNeverTakesOver_andCanBeReplaced() public {
        vm.prank(owner);
        gateway.transferOwnership(makeAddr("typo"));
        vm.prank(attacker);
        vm.expectRevert(Custodial.NotPendingOwner.selector);
        gateway.acceptOwnership();

        // The owner still has full control and can nominate the right address.
        vm.prank(owner);
        gateway.transferOwnership(safe);
        vm.prank(makeAddr("typo"));
        vm.expectRevert(Custodial.NotPendingOwner.selector);
        gateway.acceptOwnership();
        vm.prank(safe);
        gateway.acceptOwnership();
        assertEq(gateway.owner(), safe);
    }

    function test_nominatingZeroCancels_andNobodyCanAcceptThen() public {
        vm.startPrank(owner);
        gateway.transferOwnership(safe);
        gateway.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(safe);
        vm.expectRevert(Custodial.NotPendingOwner.selector);
        gateway.acceptOwnership();
        vm.prank(address(0));
        vm.expectRevert(Custodial.NotPendingOwner.selector);
        gateway.acceptOwnership();
        assertEq(gateway.owner(), owner);
    }

    function test_vending_twoStepOwnership() public {
        vm.prank(owner);
        vending.transferOwnership(safe);
        assertEq(vending.owner(), owner);
        vm.prank(attacker);
        vm.expectRevert(Custodial.NotPendingOwner.selector);
        vending.acceptOwnership();
        vm.prank(safe);
        vending.acceptOwnership();
        assertEq(vending.owner(), safe);
        vm.prank(owner);
        vm.expectRevert(Custodial.NotOwner.selector);
        vending.withdrawXon(0);
    }

    // --- treasury --------------------------------------------------------------------------------

    function test_withdrawOnlyPaysTheTreasury() public {
        _deposit(alice, 10e6);
        _release(0, alice, 10e6); // paid on Xode: no longer owed
        vm.prank(owner);
        gateway.withdraw(4e6);
        assertEq(usdt.balanceOf(owner), 4e6, "the treasury (the deploying owner, by default)");
        vm.prank(owner);
        vm.expectRevert(EthUsdtGateway.ZeroAmount.selector);
        gateway.withdraw(0);
    }

    function test_treasuryChangeWaitsTheDelay() public {
        _deposit(alice, 10e6);
        vm.startPrank(owner);
        gateway.proposeTreasury(coldTreasury);
        assertEq(gateway.treasury(), owner, "nothing changes yet");

        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(Custodial.TreasuryChangeNotReady.selector);
        gateway.applyTreasury();

        vm.warp(block.timestamp + 1);
        gateway.applyTreasury();
        usdt.mint(address(gateway), 10e6); // proceeds that aren't owed to anyone
        gateway.withdraw(10e6);
        vm.stopPrank();
        assertEq(gateway.treasury(), coldTreasury);
        assertEq(usdt.balanceOf(coldTreasury), 10e6);
        assertEq(gateway.pendingTreasury(), address(0));
    }

    function test_compromisedOwner_isStoppedByTheGuardian() public {
        // Setup done right: guardian is a separate multisig, owner is the ops Safe.
        vm.prank(owner);
        gateway.transferGuardian(guardian);
        _deposit(alice, 50e6);

        // The owner key is stolen. The attacker can't withdraw to themselves...
        usdt.mint(address(gateway), 2e6); // proceeds that aren't owed to anyone
        vm.startPrank(owner);
        gateway.withdraw(1e6); // ...only to the treasury
        assertEq(usdt.balanceOf(attacker), 0);
        // ...so they try to make themselves the treasury.
        gateway.proposeTreasury(attacker);
        // ...and can't remove the guardian.
        vm.expectRevert(Custodial.NotGuardian.selector);
        gateway.transferGuardian(attacker);
        vm.stopPrank();

        // Within the delay, the guardian sees TreasuryChangeProposed, cancels it and pauses.
        vm.startPrank(guardian);
        gateway.cancelTreasuryChange();
        gateway.guardianPause();
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        vm.expectRevert(Custodial.NoPendingTreasury.selector);
        gateway.applyTreasury();
        assertEq(gateway.treasury(), owner);
        assertTrue(gateway.paused());
        assertEq(usdt.balanceOf(attacker), 0);
    }

    function test_guardianPowersAreNarrow() public {
        vm.prank(owner);
        gateway.transferGuardian(guardian);
        _deposit(alice, 10e6);
        vm.startPrank(guardian);
        vm.expectRevert(Custodial.NotOwner.selector);
        gateway.withdraw(1);
        vm.expectRevert(Custodial.NotOwner.selector);
        gateway.setPaused(false);
        vm.expectRevert(Custodial.NotOwner.selector);
        gateway.proposeTreasury(guardian);
        vm.expectRevert(Custodial.NotOwner.selector);
        gateway.refund(0, alice, 10e6, false);
        vm.expectRevert(Custodial.NoPendingTreasury.selector);
        gateway.cancelTreasuryChange();
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(Custodial.NotGuardian.selector);
        gateway.guardianPause();
        vm.prank(attacker);
        vm.expectRevert(Custodial.NotGuardian.selector);
        gateway.cancelTreasuryChange();

        // Only the guardian can hand on its role.
        vm.prank(guardian);
        gateway.transferGuardian(bob);
        assertEq(gateway.guardian(), bob);
    }

    // --- refunds ----------------------------------------------------------------------------------

    function test_refundPaysTheDepositorBack_once() public {
        uint256 nonce = _deposit(alice, 10e6);
        assertEq(gateway.depositRecords(nonce), keccak256(abi.encode(alice, uint256(10e6))));

        vm.expectEmit(address(gateway));
        emit EthUsdtGateway.Refunded(nonce, alice, alice, 10e6, 0);
        vm.prank(owner);
        gateway.refund(nonce, alice, 10e6, false);
        assertEq(usdt.balanceOf(alice), 100e6);

        vm.prank(owner);
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.refund(nonce, alice, 10e6, false);
    }

    function test_refundCantBeRedirectedOrInflated() public {
        uint256 nonce = _deposit(alice, 10e6);
        _deposit(bob, 30e6);
        vm.startPrank(owner);
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.refund(nonce, attacker, 10e6, false); // someone else
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.refund(nonce, alice, 30e6, false); // more than she paid
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.refund(99, alice, 10e6, false); // no such deposit
        vm.stopPrank();
    }

    function test_swapDepositsAreRefundableToo() public {
        uint256 nonce = gateway.depositNonce();
        vm.prank(alice);
        gateway.depositForSwap(7e6, beneficiary, 1 ether);
        vm.prank(owner);
        gateway.refund(nonce, alice, 7e6, false);
        assertEq(usdt.balanceOf(alice), 100e6);
    }

    // --- the vending contract: same custody rules for the XON reserve and USDT inventory ---------

    function _vendingWithSeparateRoles() internal returns (XonVendingMachine v) {
        v = new XonVendingMachine(address(usdt), owner, 0.2 ether, makeAddr("relayer"), coldTreasury, guardian);
        vm.startPrank(owner);
        v.setSource("ethereum", 1, address(0xE7));
        v.setSource("assethub", 420420419, address(0xA7));
        vm.stopPrank();
        vm.deal(address(v), 100 ether);
        usdt.mint(owner, 50e6);
        vm.startPrank(owner);
        usdt.approve(address(v), 50e6);
        v.fundUsdtInventory(50e6);
        vm.stopPrank();
    }

    function test_vending_withdrawalsOnlyReachTheTreasury() public {
        XonVendingMachine v = _vendingWithSeparateRoles();
        vm.startPrank(owner);
        v.withdrawXon(40 ether);
        v.withdrawUsdt(20e6);
        vm.stopPrank();
        assertEq(coldTreasury.balance, 40 ether);
        assertEq(usdt.balanceOf(coldTreasury), 20e6);
        assertEq(v.accountedUsdt(), 30e6);
        assertEq(owner.balance, 0, "nothing reaches the caller");
    }

    function test_vending_compromisedOwner_isStoppedByTheGuardian() public {
        XonVendingMachine v = _vendingWithSeparateRoles();
        vm.prank(owner);
        v.proposeTreasury(attacker);
        vm.prank(owner);
        vm.expectRevert(Custodial.NotGuardian.selector);
        v.transferGuardian(attacker);

        vm.startPrank(guardian);
        v.cancelTreasuryChange();
        v.guardianPause();
        vm.stopPrank();
        assertTrue(v.paused(), "payouts stopped");
        vm.prank(makeAddr("relayer"));
        vm.expectRevert(Custodial.IsPaused.selector);
        v.settleExternalPurchase(beneficiary, 1e6, 1, "ethereum", keccak256("x"));

        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        vm.expectRevert(Custodial.NoPendingTreasury.selector);
        v.applyTreasury();
        vm.prank(owner);
        v.withdrawXon(1 ether);
        assertEq(attacker.balance, 0);
        assertEq(coldTreasury.balance, 1 ether);
    }

    function test_constructorsRejectZeroTreasuryOrGuardian() public {
        vm.expectRevert(Custodial.ZeroAddress.selector);
        new EthUsdtGateway(address(usdt), owner, address(0), guardian);
        vm.expectRevert(Custodial.ZeroAddress.selector);
        new EthUsdtGateway(address(usdt), owner, coldTreasury, address(0));
        vm.expectRevert(Custodial.ZeroAddress.selector);
        new XonVendingMachine(address(usdt), owner, 0.2 ether, makeAddr("relayer"), address(0), guardian);
        vm.expectRevert(Custodial.ZeroAddress.selector);
        new XonVendingMachine(address(usdt), owner, 0.2 ether, makeAddr("relayer"), coldTreasury, address(0));
    }
}

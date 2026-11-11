// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Custodial} from "../src/Custodial.sol";
import {EthUsdtGateway} from "../src/ethereum/EthUsdtGateway.sol";
import {XonVendingMachine} from "../src/XonVendingMachine.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// The fixes for the loopholes review: the change queue, attester quorum, cancel-before-refund,
/// refund fee / refund address / minimum deposit, the fixed-rate pause, and per-address limits.
contract LoopholeFixesTest is Test {
    XonVendingMachine vending;
    EthUsdtGateway gateway;
    MockUSDT usdt;

    address owner = makeAddr("opsSafe");
    address guardian = makeAddr("guardianSafe");
    address treasury = makeAddr("treasurySafe");
    address relayerA = makeAddr("relayerA");
    address relayerB = makeAddr("relayerB");
    address relayerC = makeAddr("relayerC");
    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant USDT = 1e6;
    bytes32 constant DEP = keccak256("ethereum:0xabc:0");

    function setUp() public {
        usdt = new MockUSDT();
        vending = new XonVendingMachine(address(usdt), owner, 0.2 ether, relayerA, treasury, guardian);
        gateway = new EthUsdtGateway(address(usdt), owner, treasury, guardian);
        vm.deal(address(vending), 1_000 ether);

        // Setup phase: everything is instant for the deployer.
        vm.startPrank(owner);
        vending.setExternalLimits(100 * USDT, 1_000 * USDT);
        vending.setNativeLimits(100 * USDT, 1_000 * USDT);
        vending.addAttester(relayerB);
        vending.addAttester(relayerC);
        vending.setAttestationThreshold(2);
        vending.setRateKeeper(keeper, 200, 600);
        gateway.setMinDeposit(1 * USDT);
        gateway.setRefundFee(0.5e6);
        vending.finishSetup();
        gateway.finishSetup();
        vm.stopPrank();

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            usdt.mint(who, 1_000 * USDT);
            vm.startPrank(who);
            usdt.approve(address(gateway), type(uint256).max);
            usdt.approve(address(vending), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _vote(address attester, address buyer, uint256 amount, bytes32 id) internal {
        vm.prank(attester);
        vending.attestExternalPurchase(buyer, amount, "ethereum", id);
    }

    function _settle(address attester, address buyer, uint256 amount, bytes32 id) internal {
        vm.prank(attester);
        vending.settleExternalPurchase(buyer, amount, "ethereum", id);
    }

    // --- #1 the change queue ----------------------------------------------------------------------

    function test_queue_riskyChangesWaitTwoDays() public {
        bytes memory raise = abi.encodeCall(vending.setExternalLimits, (1_000_000 * USDT, 1_000_000 * USDT));

        vm.prank(owner);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setExternalLimits(1_000_000 * USDT, 1_000_000 * USDT);

        vm.prank(owner);
        vending.queueChange(raise);
        vm.warp(block.timestamp + 2 days - 1);
        vm.prank(owner);
        vm.expectRevert(Custodial.ChangeNotReady.selector);
        vending.setExternalLimits(1_000_000 * USDT, 1_000_000 * USDT);

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        vending.setExternalLimits(1_000_000 * USDT, 1_000_000 * USDT);
        assertEq(vending.maxExternalPerDay(), 1_000_000 * USDT);

        // A queued change is used up: it can't be replayed later (say, after a lowering).
        vm.startPrank(owner);
        vending.setExternalLimits(1 * USDT, 1 * USDT);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setExternalLimits(1_000_000 * USDT, 1_000_000 * USDT);
        vm.stopPrank();
    }

    function test_queue_onlyTheExactQueuedCallGoesThrough() public {
        vm.prank(owner);
        vending.queueChange(abi.encodeCall(vending.setExternalLimits, (200 * USDT, 2_000 * USDT)));
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setExternalLimits(200 * USDT, 2_000 * USDT + 1);
    }

    function test_queue_guardianCancels() public {
        bytes memory call = abi.encodeCall(vending.setRate, (5 ether));
        vm.prank(owner);
        vending.queueChange(call);
        vm.prank(guardian);
        vending.cancelChange(keccak256(call));
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setRate(5 ether);

        vm.prank(attacker);
        vm.expectRevert(Custodial.NotGuardian.selector);
        vending.cancelChange(keccak256(call));
        vm.prank(attacker);
        vm.expectRevert(Custodial.NotOwner.selector);
        vending.queueChange(call);
    }

    function test_queue_safeChangesStayInstant() public {
        vm.startPrank(owner);
        vending.setExternalLimits(1 * USDT, 10 * USDT);
        vending.setNativeLimits(0, 0);
        vending.setRate(0.1 ether);
        vending.setRelayer(address(0));
        vending.setRateKeeper(address(0), 0, 0);
        vending.setAttestationThreshold(3);
        vending.setAddressLimit(5 * USDT);
        gateway.setRefundFee(0);
        vm.stopPrank();
        assertEq(vending.rate(), 0.1 ether);
        assertEq(vending.attestationThreshold(), 3);
    }

    function test_queue_everyRiskySetterIsGated() public {
        vm.startPrank(owner);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setNativeLimits(101 * USDT, 1_000 * USDT);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setRate(0.3 ether);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setRelayer(attacker);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setRateKeeper(attacker, 10_000, 0);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.addAttester(attacker);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setAttestationThreshold(1);
        vending.setAddressLimit(5 * USDT);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setAddressLimit(0);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        gateway.setRefundFee(10 * USDT);
        vm.stopPrank();
    }

    function test_queue_handoverEndsSetup() public {
        XonVendingMachine fresh = new XonVendingMachine(address(usdt), owner, 0.2 ether, relayerA, treasury, guardian);
        vm.startPrank(owner);
        fresh.setRate(1 ether); // setup: instant
        fresh.transferOwnership(makeAddr("newOwner"));
        assertTrue(fresh.setupFinished());
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        fresh.setRate(2 ether);
        vm.stopPrank();
    }

    // --- #2 attester quorum -----------------------------------------------------------------------

    function test_quorum_oneStolenKeyCantPay() public {
        _vote(relayerA, attacker, 100 * USDT, DEP);
        vm.expectRevert(XonVendingMachine.AwaitingQuorum.selector);
        _settle(relayerA, attacker, 100 * USDT, DEP);
        assertEq(attacker.balance, 0);
    }

    function test_quorum_paysOnceEnoughAttestersAgree() public {
        _vote(relayerA, alice, 10 * USDT, DEP);
        assertEq(vending.attestations(DEP, vending.purchaseParams(alice, 10 * USDT, "ethereum")), 1);
        _vote(relayerB, alice, 10 * USDT, DEP);
        _settle(relayerC, alice, 10 * USDT, DEP); // any attester may execute
        assertEq(alice.balance, 2 ether);
        assertTrue(vending.externalSettledDeposits(DEP));
    }

    function test_quorum_disagreeingVotesDontAddUp() public {
        _vote(relayerA, attacker, 10 * USDT, DEP); // the stolen key's version
        _vote(relayerB, alice, 10 * USDT, DEP);
        vm.expectRevert(XonVendingMachine.AwaitingQuorum.selector);
        _settle(relayerB, alice, 10 * USDT, DEP);
        vm.expectRevert(XonVendingMachine.AwaitingQuorum.selector);
        _settle(relayerA, attacker, 10 * USDT, DEP);
        _vote(relayerC, alice, 10 * USDT, DEP);
        _settle(relayerB, alice, 10 * USDT, DEP);
        assertEq(attacker.balance, 0);
    }

    function test_quorum_oneVoteEachAndOnlyAttestersExecute() public {
        _vote(relayerA, alice, 10 * USDT, DEP);
        vm.expectRevert(XonVendingMachine.AlreadyAttested.selector);
        _vote(relayerA, alice, 10 * USDT, DEP);
        vm.expectRevert(XonVendingMachine.NotAttester.selector);
        _vote(attacker, alice, 10 * USDT, DEP);
        _vote(relayerB, alice, 10 * USDT, DEP);
        // Even with a quorum in place, nobody else can pick the moment it executes.
        vm.expectRevert(XonVendingMachine.NotAttester.selector);
        _settle(attacker, alice, 10 * USDT, DEP);
    }

    function test_quorum_removingAnAttesterVoidsItsOpenVotes() public {
        _vote(relayerA, alice, 10 * USDT, DEP);
        _vote(relayerB, alice, 10 * USDT, DEP);
        vm.prank(guardian); // a key thought stolen: the guardian can act at once
        vending.removeAttester(relayerA);
        vm.expectRevert(XonVendingMachine.AwaitingQuorum.selector);
        _settle(relayerB, alice, 10 * USDT, DEP);
        // The remaining attesters vote again.
        _vote(relayerB, alice, 10 * USDT, DEP);
        _vote(relayerC, alice, 10 * USDT, DEP);
        _settle(relayerC, alice, 10 * USDT, DEP);
        assertEq(alice.balance, 2 ether);

        // Never below the threshold.
        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.InvalidThreshold.selector);
        vending.removeAttester(relayerB);
        vm.prank(attacker);
        vm.expectRevert(Custodial.NotGuardian.selector);
        vending.removeAttester(relayerB);
    }

    // --- #3 cancel on Xode before refunding -------------------------------------------------------

    function test_cancel_blocksAnyLaterPayout() public {
        _vote(relayerA, alice, 10 * USDT, DEP);
        vm.prank(owner);
        vending.cancelExternalDeposit(DEP);
        vm.expectRevert(XonVendingMachine.DepositIsCancelled.selector);
        _vote(relayerB, alice, 10 * USDT, DEP);
        vm.expectRevert(XonVendingMachine.DepositIsCancelled.selector);
        _settle(relayerA, alice, 10 * USDT, DEP);
    }

    function test_cancel_refusedOnceTheDepositWasPaid() public {
        _vote(relayerA, alice, 10 * USDT, DEP);
        _vote(relayerB, alice, 10 * USDT, DEP);
        _settle(relayerA, alice, 10 * USDT, DEP);
        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.AlreadyExternallySettled.selector);
        vending.cancelExternalDeposit(DEP);
        vm.prank(guardian);
        vm.expectRevert(Custodial.NotOwner.selector);
        vending.cancelExternalDeposit(keccak256("other"));
    }

    function test_cancelNative_refundLeavesNoPhantomBalance() public {
        bytes32 tx1 = keccak256("xode:0x111");
        // Alice transfers 10 USDT straight in; it's held (say, over her limit) and refunded instead.
        vm.prank(alice);
        usdt.transfer(address(vending), 10 * USDT);

        vm.prank(owner);
        vending.cancelNativeDeposit(tx1, 10 * USDT);
        assertTrue(vending.nativeCancelled(tx1));
        assertEq(vending.accountedUsdt(), 10 * USDT);

        // The refund leaves via the treasury, and nothing unaccounted remains to settle against.
        vm.prank(owner);
        vending.withdrawUsdt(10 * USDT);
        assertEq(usdt.balanceOf(treasury), 10 * USDT);
        assertEq(usdt.balanceOf(address(vending)), vending.accountedUsdt());

        vm.prank(relayerA);
        vm.expectRevert(XonVendingMachine.DepositIsCancelled.selector);
        vending.settlePurchase(alice, 10 * USDT, tx1);
        // Nor can the relayer pin it on another id: there's no unaccounted USDT left.
        vm.prank(relayerA);
        vm.expectRevert(XonVendingMachine.UnverifiedDeposit.selector);
        vending.settlePurchase(attacker, 10 * USDT, keccak256("made-up"));
    }

    function test_cancelNative_onlyUnpaidUnaccountedOwnerOnly() public {
        bytes32 tx1 = keccak256("xode:0x111");
        vm.prank(alice);
        usdt.transfer(address(vending), 10 * USDT);

        vm.prank(guardian);
        vm.expectRevert(Custodial.NotOwner.selector);
        vending.cancelNativeDeposit(tx1, 10 * USDT);
        // More than is unaccounted.
        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.UnverifiedDeposit.selector);
        vending.cancelNativeDeposit(tx1, 11 * USDT);

        vm.prank(relayerA);
        vending.settlePurchase(alice, 10 * USDT, tx1);
        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.AlreadySettled.selector);
        vending.cancelNativeDeposit(tx1, 10 * USDT);

        bytes32 tx2 = keccak256("xode:0x222");
        vm.prank(alice);
        usdt.transfer(address(vending), 5 * USDT);
        vm.startPrank(owner);
        vending.cancelNativeDeposit(tx2, 5 * USDT);
        vm.expectRevert(XonVendingMachine.DepositIsCancelled.selector);
        vending.cancelNativeDeposit(tx2, 5 * USDT);
        vm.stopPrank();
    }

    // --- #4 / #5 / blacklist: the gateway ----------------------------------------------------------

    function test_gateway_minimumDeposit() public {
        vm.startPrank(alice);
        vm.expectRevert(EthUsdtGateway.BelowMinimumDeposit.selector);
        gateway.deposit(1 * USDT - 1, bob);
        vm.expectRevert(EthUsdtGateway.BelowMinimumDeposit.selector);
        gateway.depositForSwap(1 * USDT - 1, bob, 1);
        gateway.depositForSwap(1 * USDT, bob, 1);
        vm.stopPrank();
    }

    function test_gateway_refundFeeOnlyWhenCharged() public {
        vm.startPrank(alice);
        gateway.depositForSwap(10 * USDT, bob, 1 ether); // nonce 0
        gateway.depositForSwap(10 * USDT, bob, 1 ether); // nonce 1
        vm.stopPrank();
        uint256 before = usdt.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(gateway));
        emit EthUsdtGateway.Refunded(0, alice, alice, 9.5e6, 0.5e6);
        vm.prank(owner);
        gateway.refund(0, alice, 10 * USDT, true); // her minimum wasn't met
        vm.prank(owner);
        gateway.refund(1, alice, 10 * USDT, false); // our failure: in full
        assertEq(usdt.balanceOf(alice) - before, 19.5e6);
        assertEq(usdt.balanceOf(address(gateway)), 0.5e6, "the fee stays, for the treasury");
    }

    function test_gateway_depositorNamesTheRefundAddress() public {
        vm.prank(alice);
        gateway.deposit(10 * USDT, bob);
        address fresh = makeAddr("aliceFreshWallet");

        vm.prank(attacker);
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.setRefundAddress(0, 10 * USDT, attacker);
        vm.prank(alice);
        gateway.setRefundAddress(0, 10 * USDT, fresh);

        vm.prank(owner);
        gateway.refund(0, alice, 10 * USDT, false);
        assertEq(usdt.balanceOf(fresh), 10 * USDT);
        assertEq(gateway.refundAddress(0), address(0));
    }

    // --- #7 fixed-rate pause ----------------------------------------------------------------------

    function test_fixedRatePause_keeperStopsFixedPathsOnly() public {
        vm.prank(keeper);
        vending.keeperPauseFixedRate(true);
        vm.prank(alice);
        vm.expectRevert(XonVendingMachine.FixedRatePaused.selector);
        vending.buy(1 * USDT);
        _vote(relayerA, alice, 10 * USDT, DEP);
        _vote(relayerB, alice, 10 * USDT, DEP);
        vm.expectRevert(XonVendingMachine.FixedRatePaused.selector);
        _settle(relayerA, alice, 10 * USDT, DEP);

        vm.prank(keeper);
        vending.keeperPauseFixedRate(false);
        _settle(relayerA, alice, 10 * USDT, DEP);
    }

    function test_fixedRatePause_keeperCantLiftTheOwners() public {
        vm.prank(guardian);
        vending.setFixedRatePaused(true);
        vm.prank(keeper);
        vending.keeperPauseFixedRate(false);
        assertTrue(vending.fixedRatePaused());
        vm.prank(guardian);
        vm.expectRevert(Custodial.NotGuardian.selector);
        vending.setFixedRatePaused(false);
        vm.prank(attacker);
        vm.expectRevert(XonVendingMachine.NotRateKeeper.selector);
        vending.keeperPauseFixedRate(true);
        vm.prank(owner);
        vending.setFixedRatePaused(false);
        assertFalse(vending.fixedRatePaused());
    }

    // --- #8 per-address limit ---------------------------------------------------------------------

    function test_addressLimit_oneBuyerCantTakeEveryonesAllowance() public {
        vm.prank(owner);
        vending.setAddressLimit(20 * USDT);

        vm.startPrank(alice);
        vending.buy(15 * USDT);
        vm.expectRevert(XonVendingMachine.OverAddressDailyLimit.selector);
        vending.buy(6 * USDT);
        vm.stopPrank();
        vm.prank(bob);
        vending.buy(20 * USDT);

        // The same allowance covers external payouts to that address.
        _vote(relayerA, alice, 6 * USDT, DEP);
        _vote(relayerB, alice, 6 * USDT, DEP);
        vm.expectRevert(XonVendingMachine.OverAddressDailyLimit.selector);
        _settle(relayerA, alice, 6 * USDT, DEP);

        vm.warp(block.timestamp + 1 days);
        _settle(relayerA, alice, 6 * USDT, DEP);
    }
}

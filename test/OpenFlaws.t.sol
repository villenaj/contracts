// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Custodial} from "../src/Custodial.sol";
import {EthUsdtGateway} from "../src/ethereum/EthUsdtGateway.sol";
import {XonVendingMachine} from "../src/XonVendingMachine.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// The buyer's minimum on fixed-rate deposits, registered deposit sources, the gateway's reserve
/// for unpaid deposits, and refunds authorised by the attesters instead of the owner.
contract OpenFlawsTest is Test {
    XonVendingMachine vending;
    EthUsdtGateway gateway;
    MockUSDT usdt;

    address owner = makeAddr("opsSafe");
    address guardian = makeAddr("guardianSafe");
    address treasury = makeAddr("treasurySafe");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address anyone = makeAddr("anyone");

    // Attesters need real keys: they sign refunds.
    uint256 constant KEY_A = 0xA11CE;
    uint256 constant KEY_B = 0xB0B;
    uint256 constant KEY_C = 0xC0C0A;
    uint256 constant KEY_X = 0xBAD;
    address attA = vm.addr(KEY_A);
    address attB = vm.addr(KEY_B);
    address attC = vm.addr(KEY_C);

    uint256 constant USDT = 1e6;
    bytes32 constant DEP = keccak256("ethereum:0xabc:0");

    function setUp() public {
        usdt = new MockUSDT();
        vending = new XonVendingMachine(address(usdt), owner, 0.2 ether, attA, treasury, guardian);
        gateway = new EthUsdtGateway(address(usdt), owner, treasury, guardian);
        vm.deal(address(vending), 1_000 ether);

        vm.startPrank(owner);
        vending.setSource("ethereum", block.chainid, address(gateway));
        vending.setExternalLimits(100 * USDT, 1_000 * USDT);
        vending.addAttester(attB);
        vending.addAttester(attC);
        vending.setAttestationThreshold(2);
        gateway.setMinDeposit(1 * USDT);
        gateway.setRefundFee(0.5e6);
        gateway.addAttester(attA);
        gateway.addAttester(attB);
        gateway.addAttester(attC);
        gateway.setAttestationThreshold(2);
        vending.finishSetup();
        gateway.finishSetup();
        vm.stopPrank();

        usdt.mint(alice, 1_000 * USDT);
        vm.prank(alice);
        usdt.approve(address(gateway), type(uint256).max);
    }

    // --- 1. the buyer's minimum on a fixed-rate deposit ------------------------------------------

    function _votePurchase(address attester, uint256 amount, uint256 minXonOut) internal {
        vm.prank(attester);
        vending.attestExternalPurchase(bob, amount, minXonOut, "ethereum", DEP);
    }

    function test_fixedRate_paysWhenTheRateStillMeetsTheMinimum() public {
        _votePurchase(attA, 10 * USDT, 2 ether); // 10 USDT at 0.2 = exactly 2 XON
        _votePurchase(attB, 10 * USDT, 2 ether);
        vm.prank(attA);
        vending.settleExternalPurchase(bob, 10 * USDT, 2 ether, "ethereum", DEP);
        assertEq(bob.balance, 2 ether);
    }

    function test_fixedRate_isNotPaidBelowTheBuyersMinimum() public {
        _votePurchase(attA, 10 * USDT, 2 ether);
        _votePurchase(attB, 10 * USDT, 2 ether);
        // The rate is cut after the deposit was made (lowering is instant).
        vm.prank(owner);
        vending.setRate(0.19 ether);
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.BelowMinimum.selector);
        vending.settleExternalPurchase(bob, 10 * USDT, 2 ether, "ethereum", DEP);
        assertEq(bob.balance, 0);
        assertFalse(vending.externalSettledDeposits(DEP), "still open: it can be cancelled and refunded");
        assertEq(vending.externalAvailable(), 1_000 * USDT, "and it used none of the allowance");
    }

    function test_fixedRate_theMinimumIsPartOfTheVote() public {
        _votePurchase(attA, 10 * USDT, 2 ether);
        _votePurchase(attB, 10 * USDT, 2 ether);
        // An executor can't settle with a lower minimum than the attesters voted for.
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.AwaitingQuorum.selector);
        vending.settleExternalPurchase(bob, 10 * USDT, 1, "ethereum", DEP);
    }

    function test_gatewayDeposit_needsAMinimumAndPublishesIt() public {
        vm.prank(alice);
        vm.expectRevert(EthUsdtGateway.ZeroAmount.selector);
        gateway.deposit(10 * USDT, bob, 0);

        vm.expectEmit(true, true, true, true);
        emit EthUsdtGateway.Deposited(alice, bob, 10 * USDT, 0, 1.98 ether);
        vm.prank(alice);
        gateway.deposit(10 * USDT, bob, 1.98 ether);
    }

    // --- 3. registered sources ----------------------------------------------------------------------

    function test_source_unregisteredLabelCantBeAttestedOrPaid() public {
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.UnknownSource.selector);
        vending.attestExternalPurchase(bob, 10 * USDT, 1, "testnet", DEP);
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.UnknownSource.selector);
        vending.attestExternalSwap(bob, 10 * USDT, 1, "testnet", DEP);
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.UnknownSource.selector);
        vending.settleExternalPurchase(bob, 10 * USDT, 1, "testnet", DEP);
    }

    function test_source_isPublishedForAttestersToCheckTheirRpcAgainst() public view {
        (uint256 chainId, address gw) = vending.source("ethereum");
        assertEq(chainId, block.chainid);
        assertEq(gw, address(gateway));
        (chainId, gw) = vending.source("assethub");
        assertEq(gw, address(0), "not registered");
    }

    function test_source_registeringIsQueued_removingIsInstant_andOldVotesStopCounting() public {
        _votePurchase(attA, 10 * USDT, 1);
        _votePurchase(attB, 10 * USDT, 1);

        // Pointing the label at another contract waits in the queue...
        bytes memory change = abi.encodeCall(vending.setSource, ("ethereum", block.chainid, address(0xBAD)));
        vm.startPrank(owner);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        vending.setSource("ethereum", block.chainid, address(0xBAD));
        vending.queueChange(change);
        vm.expectRevert(Custodial.ChangeNotReady.selector);
        vending.setSource("ethereum", block.chainid, address(0xBAD));
        vm.warp(block.timestamp + 48 hours + 1);
        vending.setSource("ethereum", block.chainid, address(0xBAD));
        vm.stopPrank();

        // ...and the votes cast for the old registration don't carry over.
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.AwaitingQuorum.selector);
        vending.settleExternalPurchase(bob, 10 * USDT, 1, "ethereum", DEP);

        // Removing a source is instant.
        vm.prank(owner);
        vending.setSource("ethereum", 0, address(0));
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.UnknownSource.selector);
        vending.settleExternalPurchase(bob, 10 * USDT, 1, "ethereum", DEP);
    }

    // --- 2. the gateway's reserve ---------------------------------------------------------------------

    function _one(uint256 nonce, address who, uint256 amount) internal pure returns (uint256[] memory n, address[] memory d, uint256[] memory a) {
        n = new uint256[](1);
        d = new address[](1);
        a = new uint256[](1);
        (n[0], d[0], a[0]) = (nonce, who, amount);
    }

    function test_reserve_unpaidDepositsCantBeWithdrawn() public {
        vm.startPrank(alice);
        gateway.deposit(10 * USDT, bob, 1);
        gateway.deposit(20 * USDT, bob, 1);
        vm.stopPrank();
        assertEq(gateway.owed(), 30 * USDT);
        assertEq(gateway.withdrawable(), 0);

        vm.prank(owner);
        vm.expectRevert(EthUsdtGateway.OwedToDepositors.selector);
        gateway.withdraw(1);

        // Deposit 0 was paid on Xode: the owner releases it, and exactly that much can leave.
        (uint256[] memory n, address[] memory d, uint256[] memory a) = _one(0, alice, 10 * USDT);
        vm.prank(alice);
        vm.expectRevert(Custodial.NotOwner.selector);
        gateway.release(n, d, a);
        vm.prank(owner);
        gateway.release(n, d, a);
        assertEq(gateway.withdrawable(), 10 * USDT);
        vm.startPrank(owner);
        vm.expectRevert(EthUsdtGateway.OwedToDepositors.selector);
        gateway.withdraw(10 * USDT + 1);
        gateway.withdraw(10 * USDT);
        vm.stopPrank();
        assertEq(usdt.balanceOf(treasury), 10 * USDT);

        // The other deposit can still be refunded in full, whatever was withdrawn.
        vm.prank(owner);
        gateway.refund(1, alice, 20 * USDT, false);
        assertEq(gateway.owed(), 0);
    }

    function test_reserve_aReleasedDepositCantBeRefunded_norReleasedTwice_norWithWrongDetails() public {
        vm.prank(alice);
        gateway.deposit(10 * USDT, bob, 1);
        (uint256[] memory n, address[] memory d, uint256[] memory a) = _one(0, alice, 10 * USDT + 1);
        vm.startPrank(owner);
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.release(n, d, a);
        (n, d, a) = _one(0, alice, 10 * USDT);
        gateway.release(n, d, a);
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.release(n, d, a);
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.refund(0, alice, 10 * USDT, false);
        vm.stopPrank();
    }

    function test_reserve_aRefundFeeBecomesWithdrawable() public {
        vm.prank(alice);
        gateway.depositForSwap(10 * USDT, bob, 1 ether);
        vm.prank(owner);
        gateway.refund(0, alice, 10 * USDT, true);
        assertEq(gateway.owed(), 0);
        assertEq(gateway.withdrawable(), 0.5e6);
    }

    // --- 4. refunds authorised by the attesters ---------------------------------------------------

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)));
        return abi.encodePacked(r, s, v);
    }

    /// Signatures by `k1` and `k2`, ordered by signer address as the gateway wants them.
    function _two(uint256 k1, uint256 k2, bytes32 digest) internal pure returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        (uint256 lo, uint256 hi) = vm.addr(k1) < vm.addr(k2) ? (k1, k2) : (k2, k1);
        sigs[0] = _sign(lo, digest);
        sigs[1] = _sign(hi, digest);
    }

    function test_cancel_byAttesterQuorum_fixesTheFee_andStopsThePayout() public {
        vm.prank(anyone);
        vm.expectRevert(XonVendingMachine.NotAttester.selector);
        vending.attestExternalCancel(DEP, true);

        vm.prank(attA);
        vending.attestExternalCancel(DEP, true);
        assertFalse(vending.externalCancelled(DEP), "one vote isn't a quorum");
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.AlreadyAttested.selector);
        vending.attestExternalCancel(DEP, true);

        // A vote for a different fee doesn't add to it.
        vm.prank(attB);
        vending.attestExternalCancel(DEP, false);
        assertFalse(vending.externalCancelled(DEP));

        vm.prank(attC);
        vending.attestExternalCancel(DEP, true);
        assertTrue(vending.externalCancelled(DEP));
        assertTrue(vending.cancelChargesFee(DEP));

        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.DepositIsCancelled.selector);
        vending.attestExternalPurchase(bob, 10 * USDT, 1, "ethereum", DEP);
    }

    function test_cancel_aPaidDepositCantBeCancelled() public {
        _votePurchase(attA, 10 * USDT, 1);
        _votePurchase(attB, 10 * USDT, 1);
        vm.prank(attA);
        vending.settleExternalPurchase(bob, 10 * USDT, 1, "ethereum", DEP);
        vm.prank(attB);
        vm.expectRevert(XonVendingMachine.AlreadyExternallySettled.selector);
        vending.attestExternalCancel(DEP, false);
    }

    function test_refundSignature_isOnlyPublishedOnceTheDepositIsCancelled() public {
        vm.prank(attA);
        vm.expectRevert(XonVendingMachine.NotCancelled.selector);
        vending.publishRefundSignature(DEP, hex"00");

        vm.prank(attA);
        vending.attestExternalCancel(DEP, false);
        vm.prank(attB);
        vending.attestExternalCancel(DEP, false);

        vm.prank(anyone);
        vm.expectRevert(XonVendingMachine.NotAttester.selector);
        vending.publishRefundSignature(DEP, hex"00");
        vm.expectEmit(true, true, true, true);
        emit XonVendingMachine.RefundSigned(DEP, attA, hex"1234");
        vm.prank(attA);
        vending.publishRefundSignature(DEP, hex"1234");
    }

    function test_refundAttested_anyoneSubmitsAQuorumOfSignatures() public {
        vm.prank(alice);
        gateway.depositForSwap(10 * USDT, bob, 1 ether);
        bytes32 digest = gateway.refundDigest(0, alice, 10 * USDT, true);

        uint256 before = usdt.balanceOf(alice);
        vm.prank(anyone);
        gateway.refundAttested(0, alice, 10 * USDT, true, _two(KEY_A, KEY_C, digest));
        assertEq(usdt.balanceOf(alice) - before, 9.5e6, "refunded less the fee the attesters signed for");
        assertEq(gateway.owed(), 0);

        // Once.
        vm.prank(anyone);
        vm.expectRevert(EthUsdtGateway.UnknownDeposit.selector);
        gateway.refundAttested(0, alice, 10 * USDT, true, _two(KEY_A, KEY_C, digest));
    }

    function test_refundAttested_needsAQuorumOfDistinctAttesters_forExactlyTheseTerms() public {
        vm.prank(alice);
        gateway.deposit(10 * USDT, bob, 1);
        bytes32 digest = gateway.refundDigest(0, alice, 10 * USDT, false);

        bytes[] memory one = new bytes[](1);
        one[0] = _sign(KEY_A, digest);
        vm.expectRevert(EthUsdtGateway.AwaitingQuorum.selector);
        gateway.refundAttested(0, alice, 10 * USDT, false, one);

        // The same attester twice.
        bytes[] memory twice = new bytes[](2);
        twice[0] = _sign(KEY_A, digest);
        twice[1] = _sign(KEY_A, digest);
        vm.expectRevert(EthUsdtGateway.InvalidSignatures.selector);
        gateway.refundAttested(0, alice, 10 * USDT, false, twice);

        // One attester and one outsider.
        vm.expectRevert(EthUsdtGateway.AwaitingQuorum.selector);
        gateway.refundAttested(0, alice, 10 * USDT, false, _two(KEY_A, KEY_X, digest));

        // Signatures for "no fee" don't authorise charging one, a different amount, or another gateway.
        bytes[] memory good = _two(KEY_A, KEY_B, digest);
        vm.expectRevert(); // they recover to strangers: no quorum (or not even in order)
        gateway.refundAttested(0, alice, 10 * USDT, true, good);
        EthUsdtGateway other = new EthUsdtGateway(address(usdt), owner, treasury, guardian);
        assertTrue(other.refundDigest(0, alice, 10 * USDT, false) != digest);

        gateway.refundAttested(0, alice, 10 * USDT, false, good);
        assertEq(usdt.balanceOf(alice), 1_000 * USDT);
    }

    function test_refundAttested_isOffWithoutAThreshold_andStoppedByAPause() public {
        EthUsdtGateway fresh = new EthUsdtGateway(address(usdt), owner, treasury, guardian);
        vm.expectRevert(EthUsdtGateway.AwaitingQuorum.selector);
        fresh.refundAttested(0, alice, 10 * USDT, false, new bytes[](0));

        vm.prank(alice);
        gateway.deposit(10 * USDT, bob, 1);
        bytes[] memory sigs = _two(KEY_A, KEY_B, gateway.refundDigest(0, alice, 10 * USDT, false));
        vm.prank(guardian);
        gateway.guardianPause();
        vm.expectRevert(Custodial.IsPaused.selector);
        gateway.refundAttested(0, alice, 10 * USDT, false, sigs);
    }

    function test_gatewayAttesters_addingIsQueued_removingIsInstant() public {
        address newcomer = makeAddr("newcomer");
        vm.startPrank(owner);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        gateway.addAttester(newcomer);
        vm.expectRevert(Custodial.ChangeNotQueued.selector);
        gateway.setAttestationThreshold(1); // lowering waits too
        gateway.setAttestationThreshold(3); // raising is instant
        vm.expectRevert(EthUsdtGateway.InvalidThreshold.selector);
        gateway.removeAttester(attC); // would leave fewer attesters than the threshold
        vm.stopPrank();
    }
}

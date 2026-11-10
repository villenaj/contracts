// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Custodial} from "../src/Custodial.sol";
import {XonVendingMachine} from "../src/XonVendingMachine.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// The Xode-native limits on `buy` / `settlePurchase`, and the rate keeper's bounded `updateRate`.
contract XonVendingMachineLimitsTest is Test {
    uint256 constant ONE_USDT = 1e6;
    uint256 constant RATE = 0.2 ether; // 1 XON = 5 USDT

    XonVendingMachine vending;
    MockUSDT usdt;
    address owner = makeAddr("owner");
    address relayer = makeAddr("relayer");
    address keeper = makeAddr("keeper");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdt = new MockUSDT();
        vending = new XonVendingMachine(address(usdt), owner, RATE, relayer, owner, owner);
        vm.deal(address(vending), 1_000 ether);
        usdt.mint(buyer, 10_000 * ONE_USDT);
        vm.prank(buyer);
        usdt.approve(address(vending), type(uint256).max);
    }

    function _buy(uint256 amount) internal {
        vm.prank(buyer);
        vending.buy(amount);
    }

    function _directDeposit(uint256 amount, bytes32 txHash) internal {
        vm.prank(buyer);
        usdt.transfer(address(vending), amount);
        vm.prank(relayer);
        vending.settlePurchase(buyer, amount, txHash);
    }

    // --- native limits -------------------------------------------------------------------------

    function test_nativePurchasesStartClosed() public {
        vm.expectRevert(XonVendingMachine.OverNativePurchaseLimit.selector);
        _buy(ONE_USDT);

        vm.prank(buyer);
        usdt.transfer(address(vending), ONE_USDT);
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverNativePurchaseLimit.selector);
        vending.settlePurchase(buyer, ONE_USDT, keccak256("tx"));
    }

    function test_perPurchaseLimit_onBothNativePaths() public {
        vm.prank(owner);
        vending.setNativeLimits(10 * ONE_USDT, 1_000 * ONE_USDT);

        _buy(10 * ONE_USDT);
        assertEq(buyer.balance, 2 ether);
        vm.expectRevert(XonVendingMachine.OverNativePurchaseLimit.selector);
        _buy(10 * ONE_USDT + 1);

        vm.prank(buyer);
        usdt.transfer(address(vending), 11 * ONE_USDT);
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverNativePurchaseLimit.selector);
        vending.settlePurchase(buyer, 11 * ONE_USDT, keccak256("big"));
    }

    function test_dailyAllowance_isSharedByBothPaths_andRefills() public {
        vm.prank(owner);
        vending.setNativeLimits(50 * ONE_USDT, 100 * ONE_USDT);

        _buy(50 * ONE_USDT);
        _directDeposit(50 * ONE_USDT, keccak256("a"));
        assertEq(vending.nativeAvailable(), 0);

        vm.expectRevert(XonVendingMachine.OverNativeDailyLimit.selector);
        _buy(ONE_USDT);

        // A quarter of a day refills a quarter of the cap.
        vm.warp(block.timestamp + 6 hours);
        assertEq(vending.nativeAvailable(), 25 * ONE_USDT);
        _buy(25 * ONE_USDT);

        vm.warp(block.timestamp + 1 days);
        assertEq(vending.nativeAvailable(), 100 * ONE_USDT);
    }

    function test_arbitrageDrainIsBoundedByTheDailyAllowance() public {
        // The DEX prices XON far above the fixed rate: an arbitrageur buys as much as they can.
        vm.prank(owner);
        vending.setNativeLimits(100 * ONE_USDT, 200 * ONE_USDT);
        uint256 reserveBefore = address(vending).balance;
        _buy(100 * ONE_USDT);
        _buy(100 * ONE_USDT);
        vm.expectRevert(XonVendingMachine.OverNativeDailyLimit.selector);
        _buy(100 * ONE_USDT);
        assertEq(reserveBefore - address(vending).balance, vending.quote(200 * ONE_USDT), "at most one day's allowance");
    }

    function test_nativeLimits_failedPurchaseUsesNoAllowance() public {
        vm.prank(owner);
        vending.setNativeLimits(50 * ONE_USDT, 100 * ONE_USDT);
        vm.deal(address(vending), 0); // reserve empty: the purchase reverts as a whole
        vm.expectRevert(XonVendingMachine.InsufficientReserve.selector);
        _buy(10 * ONE_USDT);
        assertEq(vending.nativeAvailable(), 100 * ONE_USDT);
    }

    function test_setNativeLimits_onlyOwner_andEmits() public {
        vm.prank(relayer);
        vm.expectRevert(Custodial.NotOwner.selector);
        vending.setNativeLimits(1, 1);

        vm.expectEmit(address(vending));
        emit XonVendingMachine.NativeLimitsSet(1, 2);
        vm.prank(owner);
        vending.setNativeLimits(1, 2);
    }

    function test_nativeAndExternalAllowancesAreIndependent() public {
        vm.startPrank(owner);
        vending.setNativeLimits(10 * ONE_USDT, 10 * ONE_USDT);
        vending.setExternalLimits(10 * ONE_USDT, 10 * ONE_USDT);
        vm.stopPrank();
        _buy(10 * ONE_USDT);
        assertEq(vending.externalAvailable(), 10 * ONE_USDT);
        if (!vending.hasAttested(keccak256("eth"), relayer)) {
            vm.prank(relayer);
            vending.attestExternalPurchase(buyer, 10 * ONE_USDT, "ethereum", keccak256("eth"));
        }
        vm.prank(relayer);
        vending.settleExternalPurchase(buyer, 10 * ONE_USDT, "ethereum", keccak256("eth"));
        assertEq(vending.externalAvailable(), 0);
    }

    // --- rate keeper ---------------------------------------------------------------------------

    function _appointKeeper(uint256 maxStepBps, uint256 minInterval) internal {
        vm.prank(owner);
        vending.setRateKeeper(keeper, maxStepBps, minInterval);
    }

    function test_keeper_movesRateWithinItsBounds() public {
        _appointKeeper(200, 1 hours); // 2% per update, at most hourly
        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(address(vending));
        emit XonVendingMachine.RateUpdated(RATE, 0.204 ether);
        vm.prank(keeper);
        vending.updateRate(0.204 ether); // +2%
        assertEq(vending.rate(), 0.204 ether);
    }

    function test_keeper_cantStepTooFar_eitherWay() public {
        _appointKeeper(200, 0);
        vm.startPrank(keeper);
        vm.expectRevert(XonVendingMachine.RateStepTooLarge.selector);
        vending.updateRate(0.204 ether + 1);
        vm.expectRevert(XonVendingMachine.RateStepTooLarge.selector);
        vending.updateRate(0.196 ether - 1);
        vending.updateRate(0.196 ether); // exactly -2% is fine
        vm.stopPrank();
    }

    function test_keeper_cantUpdateTooOften_includingRightAfterTheOwner() public {
        _appointKeeper(200, 1 hours);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        vending.updateRate(0.201 ether);

        vm.warp(block.timestamp + 59 minutes);
        vm.prank(keeper);
        vm.expectRevert(XonVendingMachine.RateUpdateTooSoon.selector);
        vending.updateRate(0.202 ether);

        // The owner's own change restarts the interval too.
        vm.warp(block.timestamp + 1 hours);
        vm.prank(owner);
        vending.setRate(0.2 ether);
        vm.prank(keeper);
        vm.expectRevert(XonVendingMachine.RateUpdateTooSoon.selector);
        vending.updateRate(0.201 ether);
    }

    function test_onlyTheKeeper_andNotOnceRemoved() public {
        _appointKeeper(200, 0);
        address[3] memory others = [owner, relayer, buyer];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(XonVendingMachine.NotRateKeeper.selector);
            vending.updateRate(0.201 ether);
        }
        vm.prank(owner);
        vending.setRateKeeper(address(0), 200, 0);
        vm.prank(keeper);
        vm.expectRevert(XonVendingMachine.NotRateKeeper.selector);
        vending.updateRate(0.201 ether);
        vm.prank(address(0));
        vm.expectRevert(XonVendingMachine.NotRateKeeper.selector);
        vending.updateRate(0.201 ether);
    }

    function test_keeper_cantZeroTheRate_andSetRateKeeperIsOwnerOnly() public {
        _appointKeeper(10_000, 0); // even a 100% step can't reach zero
        vm.prank(keeper);
        vm.expectRevert(XonVendingMachine.ZeroAmount.selector);
        vending.updateRate(0);

        vm.prank(keeper);
        vm.expectRevert(Custodial.NotOwner.selector);
        vending.setRateKeeper(keeper, 10_000, 0);
    }

    function testFuzz_keeperStepNeverExceedsTheBound(uint256 newRate, uint16 stepBps) public {
        uint256 bound = uint256(stepBps) % 10_001;
        _appointKeeper(bound, 0);
        newRate = bound_(newRate, 1, 2 * RATE);
        vm.prank(keeper);
        try vending.updateRate(newRate) {
            uint256 step = newRate > RATE ? newRate - RATE : RATE - newRate;
            assertLe(step * 10_000, RATE * bound);
        } catch {}
    }

    function bound_(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }
}

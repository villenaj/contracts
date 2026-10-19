// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EthUsdtGateway} from "../src/ethereum/EthUsdtGateway.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {TetherLikeUsdt} from "./mocks/TetherLikeUsdt.sol";

contract EthUsdtGatewayTest is Test {
    EthUsdtGateway gateway;
    MockUSDT usdt;

    address owner = makeAddr("owner");
    address depositor = makeAddr("depositor");
    address xodeBeneficiary = makeAddr("xodeBeneficiary");

    function setUp() public {
        usdt = new MockUSDT();
        gateway = new EthUsdtGateway(address(usdt), owner);
        usdt.mint(depositor, 1_000_000_000); // 1,000 USDT
    }

    function test_deposit_pullsUsdtAndEmitsBeneficiary() public {
        uint256 amount = 20_000_000; // 20 USDT

        vm.startPrank(depositor);
        require(usdt.approve(address(gateway), amount));
        vm.expectEmit(true, true, false, true);
        emit EthUsdtGateway.Deposited(depositor, xodeBeneficiary, amount, 0);
        gateway.deposit(amount, xodeBeneficiary);
        vm.stopPrank();

        assertEq(usdt.balanceOf(address(gateway)), amount);
        assertEq(usdt.balanceOf(depositor), 1_000_000_000 - amount);
        assertEq(gateway.depositNonce(), 1);
    }

    function test_deposit_incrementsNonceAcrossDeposits() public {
        vm.startPrank(depositor);
        require(usdt.approve(address(gateway), 30_000_000));
        gateway.deposit(10_000_000, xodeBeneficiary);
        gateway.deposit(20_000_000, xodeBeneficiary);
        vm.stopPrank();

        assertEq(gateway.depositNonce(), 2);
    }

    function test_deposit_revertsOnZeroBeneficiary() public {
        vm.startPrank(depositor);
        require(usdt.approve(address(gateway), 10_000_000));
        vm.expectRevert(EthUsdtGateway.ZeroAddress.selector);
        gateway.deposit(10_000_000, address(0));
        vm.stopPrank();
    }

    function test_deposit_revertsWithoutApproval() public {
        vm.prank(depositor);
        vm.expectRevert("MockUSDT: insufficient allowance");
        gateway.deposit(10_000_000, xodeBeneficiary);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(owner);
        gateway.setPaused(true);

        vm.startPrank(depositor);
        require(usdt.approve(address(gateway), 10_000_000));
        vm.expectRevert(EthUsdtGateway.IsPaused.selector);
        gateway.deposit(10_000_000, xodeBeneficiary);
        vm.stopPrank();
    }

    function test_onlyOwner_canWithdraw() public {
        vm.startPrank(depositor);
        require(usdt.approve(address(gateway), 10_000_000));
        gateway.deposit(10_000_000, xodeBeneficiary);
        vm.stopPrank();

        vm.prank(depositor);
        vm.expectRevert(EthUsdtGateway.NotOwner.selector);
        gateway.withdraw(depositor, 10_000_000);

        vm.prank(owner);
        gateway.withdraw(owner, 10_000_000);
        assertEq(usdt.balanceOf(owner), 10_000_000);
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(depositor);
        vm.expectRevert(EthUsdtGateway.NotOwner.selector);
        gateway.transferOwnership(newOwner);

        vm.prank(owner);
        gateway.transferOwnership(newOwner);
        assertEq(gateway.owner(), newOwner);

        vm.prank(owner);
        vm.expectRevert(EthUsdtGateway.NotOwner.selector);
        gateway.setPaused(true);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(EthUsdtGateway.ZeroAddress.selector);
        new EthUsdtGateway(address(0), owner);

        vm.expectRevert(EthUsdtGateway.ZeroAddress.selector);
        new EthUsdtGateway(address(usdt), address(0));
    }

    // --- Ethereum's real USDT: no return values, optional transfer fee ---

    function _tetherGateway() internal returns (EthUsdtGateway tetherGateway, TetherLikeUsdt tether) {
        tether = new TetherLikeUsdt();
        tetherGateway = new EthUsdtGateway(address(tether), owner);
        tether.mint(depositor, 1_000_000_000);
    }

    function test_deposit_worksWithUsdtThatReturnsNothing() public {
        (EthUsdtGateway tetherGateway, TetherLikeUsdt tether) = _tetherGateway();

        vm.startPrank(depositor);
        tether.approve(address(tetherGateway), 20_000_000);
        vm.expectEmit(true, true, true, true);
        emit EthUsdtGateway.Deposited(depositor, xodeBeneficiary, 20_000_000, 0);
        tetherGateway.deposit(20_000_000, xodeBeneficiary);
        vm.stopPrank();

        assertEq(tether.balanceOf(address(tetherGateway)), 20_000_000);
    }

    function test_withdraw_worksWithUsdtThatReturnsNothing() public {
        (EthUsdtGateway tetherGateway, TetherLikeUsdt tether) = _tetherGateway();
        vm.startPrank(depositor);
        tether.approve(address(tetherGateway), 10_000_000);
        tetherGateway.deposit(10_000_000, xodeBeneficiary);
        vm.stopPrank();

        vm.prank(owner);
        tetherGateway.withdraw(owner, 10_000_000);
        assertEq(tether.balanceOf(owner), 10_000_000);
    }

    function test_deposit_recordsWhatArrived_whenUsdtChargesAFee() public {
        (EthUsdtGateway tetherGateway, TetherLikeUsdt tether) = _tetherGateway();
        tether.setParams(10, 1_000_000); // 0.1%, capped at 1 USDT

        vm.startPrank(depositor);
        tether.approve(address(tetherGateway), 20_000_000);
        vm.expectEmit(true, true, true, true);
        emit EthUsdtGateway.Deposited(depositor, xodeBeneficiary, 19_980_000, 0); // 20 USDT minus 0.02 fee
        tetherGateway.deposit(20_000_000, xodeBeneficiary);
        vm.stopPrank();

        assertEq(tether.balanceOf(address(tetherGateway)), 19_980_000);
    }

    function test_deposit_bubblesUpTheTokensRevertReason() public {
        (EthUsdtGateway tetherGateway, ) = _tetherGateway();
        vm.prank(depositor);
        vm.expectRevert("TetherLikeUsdt: insufficient allowance");
        tetherGateway.deposit(10_000_000, xodeBeneficiary);
    }

    function test_withdraw_revertsWhenTheTokenReturnsFalse() public {
        vm.mockCall(address(usdt), abi.encodeWithSelector(MockUSDT.transfer.selector), abi.encode(false));
        vm.prank(owner);
        vm.expectRevert(EthUsdtGateway.UsdtTransferFailed.selector);
        gateway.withdraw(owner, 1);
    }
}

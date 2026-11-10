// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Custodial} from "../src/Custodial.sol";
import {XonVendingMachine} from "../src/XonVendingMachine.sol";
import {IXcm, XcmSwap} from "../src/XcmSwap.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

contract BurnableMockUSDT is MockUSDT {
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}

/// Stands in for Xode's XCM precompile at 0xA0000. `execute` does what the real swap does to
/// balances: takes `usdtIn` USDT from the caller (WithdrawAsset) and pays `xonOut` native XON to
/// `payTo` (DepositAsset; the caller unless set). It can also refuse, like a `NoDeal` exchange.
contract MockXcmPrecompile is IXcm {
    BurnableMockUSDT public usdt;
    uint256 public usdtIn;
    uint256 public xonOut;
    address public payTo;
    bool public refuse;
    bytes public lastMessage;
    uint64 public lastRefTime;

    function configure(BurnableMockUSDT usdt_, uint256 usdtIn_, uint256 xonOut_, address payTo_, bool refuse_) external {
        (usdt, usdtIn, xonOut, payTo, refuse) = (usdt_, usdtIn_, xonOut_, payTo_, refuse_);
    }

    function weighMessage(bytes calldata) external pure returns (Weight memory) {
        return Weight(3_000_000_000, 196_608);
    }

    function execute(bytes calldata message, Weight calldata weight) external {
        if (refuse) revert("LocalExecutionIncomplete: NoDeal");
        lastMessage = message;
        lastRefTime = weight.refTime;
        usdt.burn(msg.sender, usdtIn);
        (bool ok, ) = (payTo == address(0) ? msg.sender : payTo).call{value: xonOut}("");
        require(ok, "mock payout failed");
    }
}

contract XonVendingMachineSwapTest is Test {
    uint256 constant RATE = 5 ether;
    uint256 constant ONE_USDT = 1e6;
    // What 2 USDT bought in the fork dry-run: 0.381652221371 XON = 381652221371 planck.
    uint256 constant SWAP_OUT = 381_652_221_371 * 1e6;

    XonVendingMachine vending;
    BurnableMockUSDT usdt;
    MockXcmPrecompile xcm;

    address owner = makeAddr("owner");
    address relayer = makeAddr("relayer");
    address buyer = makeAddr("buyer");
    bytes32 constant DEPOSIT = keccak256("ethereum-deposit-1");

    function setUp() public {
        usdt = new BurnableMockUSDT();
        vending = new XonVendingMachine(address(usdt), owner, RATE, relayer, owner, owner);

        vm.etch(XcmSwap.XCM_PRECOMPILE, address(new MockXcmPrecompile()).code);
        xcm = MockXcmPrecompile(XcmSwap.XCM_PRECOMPILE);
        vm.deal(address(xcm), 1_000 ether);
        xcm.configure(usdt, 2 * ONE_USDT, SWAP_OUT, address(0), false);

        vm.startPrank(owner);
        vending.setExternalLimits(100 * ONE_USDT, 1_000 * ONE_USDT);
        usdt.mint(owner, 50 * ONE_USDT);
        usdt.approve(address(vending), 50 * ONE_USDT);
        vending.fundUsdtInventory(50 * ONE_USDT);
        vm.stopPrank();
    }

    function _swap(uint256 usdtAmount, uint256 minXonOut, bytes32 depositId) internal {
        vm.prank(relayer);
        vending.settleExternalSwap(buyer, usdtAmount, minXonOut, "ethereum", depositId);
    }

    // --- the happy path -----------------------------------------------------------------------

    function test_paysBuyerWhatTheSwapReturned() public {
        uint256 allowanceBefore = vending.externalAvailable();

        vm.expectEmit(true, true, true, true, address(vending));
        emit XonVendingMachine.ExternalSwapSettled(buyer, "ethereum", DEPOSIT, 2 * ONE_USDT, SWAP_OUT);
        _swap(2 * ONE_USDT, 0.38 ether, DEPOSIT);

        assertEq(buyer.balance, SWAP_OUT, "buyer gets the full swap output, not a rate quote");
        assertEq(address(vending).balance, 0, "nothing is kept back");
        assertTrue(vending.externalSettledDeposits(DEPOSIT));
        assertEq(vending.accountedUsdt(), 48 * ONE_USDT, "inventory spent");
        assertEq(usdt.balanceOf(address(vending)), 48 * ONE_USDT, "balance and accounting agree");
        assertEq(vending.externalAvailable(), allowanceBefore - 2 * ONE_USDT, "daily allowance used");
    }

    function test_sendsTheExactXcmProgram_withMinimumRoundedUpToPlanck() public {
        // 0.38 XON plus 1 wei: the minimum in planck must round *up*, never let less through.
        _swap(2 * ONE_USDT, 0.38 ether + 1, DEPOSIT);

        uint256 minPlanck = 380_000_000_001; // ceil((0.38e18 + 1) / 1e6)
        bytes memory expected = XcmSwap.swapUsdtForXon(
            2 * ONE_USDT, minPlanck, XcmSwap.contractAccount(address(vending))
        );
        assertEq(xcm.lastMessage(), expected);
        assertEq(xcm.lastRefTime(), 3_000_000_000, "uses the weight the precompile reported");
    }

    function test_doesNotTouchTheXonReserve() public {
        vm.deal(address(vending), 100 ether); // the fixed-rate reserve
        _swap(2 * ONE_USDT, 0.38 ether, DEPOSIT);
        assertEq(address(vending).balance, 100 ether);
        assertEq(buyer.balance, SWAP_OUT);
    }

    // --- the swap failing ---------------------------------------------------------------------

    function test_refusedSwap_revertsEverything() public {
        xcm.configure(usdt, 2 * ONE_USDT, SWAP_OUT, address(0), true);
        uint256 allowanceBefore = vending.externalAvailable();

        vm.prank(relayer);
        vm.expectRevert(bytes("LocalExecutionIncomplete: NoDeal"));
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 1 ether, "ethereum", DEPOSIT);

        assertFalse(vending.externalSettledDeposits(DEPOSIT), "can be retried or refunded");
        assertEq(vending.accountedUsdt(), 50 * ONE_USDT);
        assertEq(vending.externalAvailable(), allowanceBefore);
        assertEq(buyer.balance, 0);
    }

    function test_swapPayingLessThanMinimum_reverts() public {
        // The XCM program enforces the minimum itself; this is the contract's own backstop, e.g.
        // if the XON ever landed somewhere other than this contract.
        xcm.configure(usdt, 2 * ONE_USDT, SWAP_OUT, makeAddr("elsewhere"), false);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.SlippageExceeded.selector);
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 0.38 ether, "ethereum", DEPOSIT);
        assertFalse(vending.externalSettledDeposits(DEPOSIT));
    }

    // --- what it may spend --------------------------------------------------------------------

    function test_neverSpendsAPendingNativeDeposit() public {
        // A buyer's direct transfer that the relayer hasn't settled yet isn't inventory.
        address nativeBuyer = makeAddr("nativeBuyer");
        usdt.mint(nativeBuyer, 30 * ONE_USDT);
        vm.prank(nativeBuyer);
        usdt.transfer(address(vending), 30 * ONE_USDT);

        // 60 USDT is more than the 50 of inventory, though the balance (80) would cover it.
        xcm.configure(usdt, 60 * ONE_USDT, SWAP_OUT, address(0), false);
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.InsufficientUsdtInventory.selector);
        vending.settleExternalSwap(buyer, 60 * ONE_USDT, 1 ether, "ethereum", DEPOSIT);

        // Spend all 50 of inventory; the pending deposit still settles afterwards.
        xcm.configure(usdt, 50 * ONE_USDT, SWAP_OUT, address(0), false);
        _swap(50 * ONE_USDT, 0.38 ether, DEPOSIT);
        vm.deal(address(vending), 1_000 ether);
        vm.prank(owner);
        vending.setNativeLimits(100 * ONE_USDT, 1_000 * ONE_USDT);
        vm.prank(relayer);
        vending.settlePurchase(nativeBuyer, 30 * ONE_USDT, keccak256("native-tx"));
        assertEq(nativeBuyer.balance, vending.quote(30 * ONE_USDT));
    }

    function test_fundUsdtInventory_onlyOwner() public {
        usdt.mint(relayer, ONE_USDT);
        vm.startPrank(relayer);
        usdt.approve(address(vending), ONE_USDT);
        vm.expectRevert(Custodial.NotOwner.selector);
        vending.fundUsdtInventory(ONE_USDT);
        vm.stopPrank();
    }

    function test_fundUsdtInventory_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.ZeroAmount.selector);
        vending.fundUsdtInventory(0);
    }

    // --- the same guards as settleExternalPurchase ---------------------------------------------

    function test_onlyRelayer() public {
        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.NotRelayer.selector);
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 1 ether, "ethereum", DEPOSIT);
    }

    function test_revertsWhenPaused() public {
        vm.prank(owner);
        vending.setPaused(true);
        vm.prank(relayer);
        vm.expectRevert(Custodial.IsPaused.selector);
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 1 ether, "ethereum", DEPOSIT);
    }

    function test_rejectsZeroAmounts_andZeroBuyer() public {
        vm.startPrank(relayer);
        vm.expectRevert(XonVendingMachine.ZeroAmount.selector);
        vending.settleExternalSwap(buyer, 0, 1 ether, "ethereum", DEPOSIT);
        vm.expectRevert(XonVendingMachine.ZeroAmount.selector);
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 0, "ethereum", DEPOSIT);
        vm.expectRevert(Custodial.ZeroAddress.selector);
        vending.settleExternalSwap(address(0), 2 * ONE_USDT, 1 ether, "ethereum", DEPOSIT);
        vm.stopPrank();
    }

    function test_externalLimitsApply() public {
        vm.prank(owner);
        vending.setExternalLimits(ONE_USDT, 1_000 * ONE_USDT);
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverExternalDepositLimit.selector);
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 1 ether, "ethereum", DEPOSIT);

        vm.prank(owner);
        vending.setExternalLimits(100 * ONE_USDT, ONE_USDT);
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverExternalDailyLimit.selector);
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 1 ether, "ethereum", DEPOSIT);
    }

    function test_aDepositIsPaidOnlyOnce_acrossBothExternalPaths() public {
        vm.deal(address(vending), 100 ether);
        vm.prank(relayer);
        vending.settleExternalPurchase(buyer, 2 * ONE_USDT, "ethereum", DEPOSIT);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.AlreadyExternallySettled.selector);
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 1 ether, "ethereum", DEPOSIT);

        _swap(2 * ONE_USDT, 0.38 ether, keccak256("ethereum-deposit-2"));
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.AlreadyExternallySettled.selector);
        vending.settleExternalSwap(buyer, 2 * ONE_USDT, 1 ether, "ethereum", keccak256("ethereum-deposit-2"));
    }
}

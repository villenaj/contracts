// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {XonVendingMachine} from "../src/XonVendingMachine.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

contract XonVendingMachineTest is Test {
    // 5 XON per 1 USDT. Solidity sees native XON in 18-decimal "ether" units (`NativeToEthRatio`
    // rescales the chain's 12-decimal native Balance up to that at the pallet_revive boundary),
    // so this is a plain `5 ether`, not a 12-decimal quantity.
    uint256 constant RATE = 5 ether;
    uint256 constant ONE_XON = 1 ether;

    XonVendingMachine vending;
    MockUSDT usdt;

    address owner = makeAddr("owner");
    address relayer = makeAddr("relayer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdt = new MockUSDT();
        vending = new XonVendingMachine(address(usdt), owner, RATE, relayer);

        vm.deal(owner, 1_000 * ONE_XON);
        vm.prank(owner);
        (bool ok, ) = address(vending).call{value: 100 * ONE_XON}("");
        require(ok, "seed reserve failed");

        usdt.mint(buyer, 1_000_000_000); // 1,000 USDT

        // External payouts are off until the owner sets limits - open them up for the tests below.
        vm.prank(owner);
        vending.setExternalLimits(100_000_000, 1_000_000_000); // 100 USDT per deposit, 1,000 per day
    }

    function test_buy_transfersUsdtInAndXonOut() public {
        uint256 usdtIn = 10_000_000; // 10 USDT
        uint256 expectedXon = vending.quote(usdtIn);

        vm.startPrank(buyer);
        require(usdt.approve(address(vending), usdtIn));
        vending.buy(usdtIn);
        vm.stopPrank();

        assertEq(usdt.balanceOf(address(vending)), usdtIn);
        assertEq(usdt.balanceOf(buyer), 1_000_000_000 - usdtIn);
        assertEq(buyer.balance, expectedXon);
        assertEq(expectedXon, 50 ether); // 10 USDT * 5 XON/USDT
        assertEq(vending.accountedUsdt(), usdtIn);
    }

    function test_buy_revertsWithoutApproval() public {
        // MockUSDT (like most ERC20s) reverts with its own reason on insufficient allowance
        // rather than returning false, so `buy` never reaches its own `UsdtTransferFailed` check.
        vm.prank(buyer);
        vm.expectRevert("MockUSDT: insufficient allowance");
        vending.buy(10_000_000);
    }

    function test_buy_revertsWhenReserveInsufficient() public {
        vm.prank(owner);
        vending.withdrawXon(payable(owner), 100 * ONE_XON);

        vm.startPrank(buyer);
        require(usdt.approve(address(vending), 10_000_000));
        vm.expectRevert(XonVendingMachine.InsufficientReserve.selector);
        vending.buy(10_000_000);
        vm.stopPrank();
    }

    function test_buy_revertsWhenPaused() public {
        vm.prank(owner);
        vending.setPaused(true);

        vm.startPrank(buyer);
        require(usdt.approve(address(vending), 10_000_000));
        vm.expectRevert(XonVendingMachine.IsPaused.selector);
        vending.buy(10_000_000);
        vm.stopPrank();
    }

    function test_onlyOwner_canSetRate() public {
        vm.prank(buyer);
        vm.expectRevert(XonVendingMachine.NotOwner.selector);
        vending.setRate(1);

        vm.prank(owner);
        vending.setRate(1);
        assertEq(vending.rate(), 1);
    }

    function test_onlyOwner_canWithdrawXon() public {
        vm.prank(buyer);
        vm.expectRevert(XonVendingMachine.NotOwner.selector);
        vending.withdrawXon(payable(buyer), 1 * ONE_XON);

        uint256 before = owner.balance;
        vm.prank(owner);
        vending.withdrawXon(payable(owner), 1 * ONE_XON);
        assertEq(owner.balance, before + 1 * ONE_XON);
    }

    function test_onlyOwner_canWithdrawUsdt() public {
        vm.startPrank(buyer);
        require(usdt.approve(address(vending), 10_000_000));
        vending.buy(10_000_000);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(XonVendingMachine.NotOwner.selector);
        vending.withdrawUsdt(buyer, 10_000_000);

        vm.prank(owner);
        vending.withdrawUsdt(owner, 10_000_000);
        assertEq(usdt.balanceOf(owner), 10_000_000);
        assertEq(vending.accountedUsdt(), 0);
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(buyer);
        vm.expectRevert(XonVendingMachine.NotOwner.selector);
        vending.transferOwnership(newOwner);

        vm.prank(owner);
        vending.transferOwnership(newOwner);
        assertEq(vending.owner(), newOwner);

        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.NotOwner.selector);
        vending.setRate(2);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(XonVendingMachine.ZeroAddress.selector);
        new XonVendingMachine(address(0), owner, RATE, relayer);

        vm.expectRevert(XonVendingMachine.ZeroAddress.selector);
        new XonVendingMachine(address(usdt), address(0), RATE, relayer);
    }

    // --- settlePurchase (push/relayer path) ---

    function _depositUsdtDirectly(uint256 amount) internal returns (bytes32 txHash) {
        vm.prank(buyer);
        require(usdt.transfer(address(vending), amount));
        // Stand in for a real transaction hash the relayer would read from the Transfer log.
        return keccak256(abi.encode(buyer, amount, block.number));
    }

    function test_settlePurchase_paysOutForDirectTransfer() public {
        uint256 usdtIn = 10_000_000; // 10 USDT, sent directly - no approve at all
        bytes32 depositTxHash = _depositUsdtDirectly(usdtIn);
        uint256 expectedXon = vending.quote(usdtIn);

        vm.prank(relayer);
        vending.settlePurchase(buyer, usdtIn, depositTxHash);

        assertEq(buyer.balance, expectedXon);
        assertEq(vending.accountedUsdt(), usdtIn);
        assertTrue(vending.settledDeposits(depositTxHash));
    }

    function test_settlePurchase_onlyRelayer() public {
        bytes32 depositTxHash = _depositUsdtDirectly(10_000_000);

        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.NotRelayer.selector);
        vending.settlePurchase(buyer, 10_000_000, depositTxHash);

        vm.prank(buyer);
        vm.expectRevert(XonVendingMachine.NotRelayer.selector);
        vending.settlePurchase(buyer, 10_000_000, depositTxHash);
    }

    function test_settlePurchase_revertsOnDoubleSettle() public {
        bytes32 depositTxHash = _depositUsdtDirectly(10_000_000);

        vm.prank(relayer);
        vending.settlePurchase(buyer, 10_000_000, depositTxHash);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.AlreadySettled.selector);
        vending.settlePurchase(buyer, 10_000_000, depositTxHash);
    }

    /// The core safety property: a relayer cannot claim a deposit that was never actually sent -
    /// only funds that are verifiably already sitting in the contract's real USDT balance.
    function test_settlePurchase_revertsWithoutMatchingDeposit() public {
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.UnverifiedDeposit.selector);
        vending.settlePurchase(buyer, 10_000_000, keccak256("fabricated"));
    }

    /// Same property, adversarial framing: relayer tries to over-claim against one real deposit
    /// by reusing it (different claimed txHash) for more than was actually sent.
    function test_settlePurchase_cannotOverclaimBeyondRealBalance() public {
        uint256 realDeposit = 10_000_000; // 10 USDT actually sent
        _depositUsdtDirectly(realDeposit);

        vm.prank(relayer);
        vending.settlePurchase(buyer, realDeposit, keccak256("first-claim"));

        // No more USDT has actually arrived - a second claim of any size must fail.
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.UnverifiedDeposit.selector);
        vending.settlePurchase(buyer, 1, keccak256("second-claim"));
    }

    function test_settlePurchase_revertsWhenPaused() public {
        bytes32 depositTxHash = _depositUsdtDirectly(10_000_000);

        vm.prank(owner);
        vending.setPaused(true);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.IsPaused.selector);
        vending.settlePurchase(buyer, 10_000_000, depositTxHash);
    }

    function test_onlyOwner_canSetRelayer() public {
        address newRelayer = makeAddr("newRelayer");

        vm.prank(buyer);
        vm.expectRevert(XonVendingMachine.NotOwner.selector);
        vending.setRelayer(newRelayer);

        vm.prank(owner);
        vending.setRelayer(newRelayer);
        assertEq(vending.relayer(), newRelayer);

        // The old relayer key is no longer authorized.
        bytes32 depositTxHash = _depositUsdtDirectly(10_000_000);
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.NotRelayer.selector);
        vending.settlePurchase(buyer, 10_000_000, depositTxHash);
    }

    /// `withdrawUsdt` draws down `accountedUsdt` too, so it doesn't permanently block
    /// `settlePurchase` for later, genuinely new deposits after proceeds are withdrawn.
    function test_withdrawUsdt_doesNotBlockLaterSettlement() public {
        bytes32 firstDeposit = _depositUsdtDirectly(10_000_000);
        vm.prank(relayer);
        vending.settlePurchase(buyer, 10_000_000, firstDeposit);

        vm.prank(owner);
        vending.withdrawUsdt(owner, 10_000_000);
        assertEq(vending.accountedUsdt(), 0);

        usdt.mint(buyer, 5_000_000);
        bytes32 secondDeposit = _depositUsdtDirectly(5_000_000);
        vm.prank(relayer);
        vending.settlePurchase(buyer, 5_000_000, secondDeposit);

        assertEq(vending.accountedUsdt(), 5_000_000);
    }

    // --- settleExternalPurchase (cross-chain: AssetHub, Ethereum via EthUsdtGateway) ---

    function test_settleExternalPurchase_paysOutOnRelayerAttestationAlone() public {
        // No USDT ever touches this contract - unlike settlePurchase, there's nothing to deposit
        // locally first. The relayer's claim is the only input.
        uint256 usdtIn = 20_000_000; // 20 USDT, as reported from Ethereum/AssetHub
        bytes32 depositId = keccak256(abi.encode("ethereum", keccak256("some-eth-tx-hash")));
        uint256 expectedXon = vending.quote(usdtIn);

        vm.prank(relayer);
        vending.settleExternalPurchase(buyer, usdtIn, "ethereum", depositId);

        assertEq(buyer.balance, expectedXon);
        assertTrue(vending.externalSettledDeposits(depositId));
        // Crucially, this path never touches accountedUsdt - it isn't backed by this contract's
        // own USDT balance, so it must not be able to loosen settlePurchase's real check either.
        assertEq(vending.accountedUsdt(), 0);
    }

    function test_settleExternalPurchase_onlyRelayer() public {
        bytes32 depositId = keccak256("assethub-deposit-1");

        vm.prank(owner);
        vm.expectRevert(XonVendingMachine.NotRelayer.selector);
        vending.settleExternalPurchase(buyer, 10_000_000, "assethub", depositId);
    }

    function test_settleExternalPurchase_revertsOnDoubleSettle() public {
        bytes32 depositId = keccak256("assethub-deposit-1");

        vm.prank(relayer);
        vending.settleExternalPurchase(buyer, 10_000_000, "assethub", depositId);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.AlreadyExternallySettled.selector);
        vending.settleExternalPurchase(buyer, 10_000_000, "assethub", depositId);
    }

    function test_settleExternalPurchase_revertsWhenPaused() public {
        vm.prank(owner);
        vending.setPaused(true);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.IsPaused.selector);
        vending.settleExternalPurchase(buyer, 10_000_000, "ethereum", keccak256("x"));
    }

    /// settlePurchase's and settleExternalPurchase's id namespaces are independent - a native
    /// deposit and an external one could theoretically share a bytes32 id without either blocking
    /// the other (in practice the relayer namespaces external ids by source chain to avoid this
    /// entirely, but the contract doesn't rely on that for its own correctness).
    function test_settlementNamespaces_areIndependent() public {
        bytes32 sharedId = keccak256("collision");
        bytes32 nativeDeposit = _depositUsdtDirectly(10_000_000);

        vm.prank(relayer);
        vending.settleExternalPurchase(buyer, 5_000_000, "ethereum", sharedId);

        // The native deposit's own hash is unrelated to `sharedId` - settle it normally too.
        vm.prank(relayer);
        vending.settlePurchase(buyer, 10_000_000, nativeDeposit);

        assertTrue(vending.externalSettledDeposits(sharedId));
        assertTrue(vending.settledDeposits(nativeDeposit));
    }

    // --- External limits (bound what a stolen relayer key can take via settleExternalPurchase) ---

    uint256 constant USDT = 1_000_000;
    uint256 constant USDT_SCALE_RATE = 1_000_000;

    function _settleExternal(uint256 usdtIn, bytes32 depositId) internal {
        vm.prank(relayer);
        vending.settleExternalPurchase(buyer, usdtIn, "ethereum", depositId);
    }

    function _setLimits(uint256 maxPerDeposit, uint256 maxPerDay) internal {
        vm.prank(owner);
        vending.setExternalLimits(maxPerDeposit, maxPerDay);
        vm.deal(address(vending), 1_000_000 * ONE_XON); // reserve is never the limit here
    }

    function test_externalLimits_startClosed() public {
        XonVendingMachine fresh = new XonVendingMachine(address(usdt), owner, RATE, relayer);
        vm.deal(address(fresh), 100 * ONE_XON);
        assertEq(fresh.externalAvailable(), 0);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverExternalDepositLimit.selector);
        fresh.settleExternalPurchase(buyer, 1 * USDT, "ethereum", keccak256("d"));
    }

    function test_externalLimits_perDeposit() public {
        _setLimits(50 * USDT, 1_000 * USDT);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverExternalDepositLimit.selector);
        vending.settleExternalPurchase(buyer, 50 * USDT + 1, "ethereum", keccak256("big"));

        _settleExternal(50 * USDT, keccak256("exactly-the-cap"));
        assertEq(buyer.balance, vending.quote(50 * USDT));
    }

    function test_externalLimits_dailyAllowanceIsSpentAndRefillsOverTime() public {
        _setLimits(100 * USDT, 150 * USDT);
        _settleExternal(100 * USDT, keccak256("a"));
        assertEq(vending.externalAvailable(), 50 * USDT);

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverExternalDailyLimit.selector);
        vending.settleExternalPurchase(buyer, 60 * USDT, "ethereum", keccak256("b"));

        // Refills at 150 USDT per 24h: half a day later, 50 + 75 is available.
        vm.warp(block.timestamp + 12 hours);
        assertEq(vending.externalAvailable(), 125 * USDT);
        _settleExternal(60 * USDT, keccak256("b"));
        assertEq(vending.externalAvailable(), 65 * USDT);

        // Never refills past the daily cap.
        vm.warp(block.timestamp + 3 days);
        assertEq(vending.externalAvailable(), 150 * USDT);
    }

    function test_externalLimits_aStolenKeyGetsAboutOneDaysAllowance() public {
        _setLimits(100 * USDT, 300 * USDT);
        for (uint256 i = 0; i < 3; i++) _settleExternal(100 * USDT, keccak256(abi.encode("drain", i)));

        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverExternalDailyLimit.selector);
        vending.settleExternalPurchase(buyer, 1 * USDT, "ethereum", keccak256("one-more"));
    }

    function test_setExternalLimits_carriesOverWhatsBeenPaid() public {
        _setLimits(100 * USDT, 150 * USDT);
        _settleExternal(100 * USDT, keccak256("a"));

        _setLimits(100 * USDT, 300 * USDT); // raising adds the difference
        assertEq(vending.externalAvailable(), 200 * USDT);

        _setLimits(100 * USDT, 50 * USDT); // lowering below what's been paid leaves nothing for now
        assertEq(vending.externalAvailable(), 0);

        _setLimits(0, 0); // and 0 turns the path off
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.OverExternalDepositLimit.selector);
        vending.settleExternalPurchase(buyer, 1, "ethereum", keccak256("c"));
    }

    function test_setExternalLimits_onlyOwner_andEmits() public {
        vm.prank(relayer);
        vm.expectRevert(XonVendingMachine.NotOwner.selector);
        vending.setExternalLimits(1, 1);

        vm.expectEmit(false, false, false, true);
        emit XonVendingMachine.ExternalLimitsSet(5 * USDT, 10 * USDT);
        vm.prank(owner);
        vending.setExternalLimits(5 * USDT, 10 * USDT);
        assertEq(vending.maxExternalPerDeposit(), 5 * USDT);
        assertEq(vending.maxExternalPerDay(), 10 * USDT);
    }

    function test_externalLimits_unlimitedDoesNotOverflow() public {
        _setLimits(type(uint256).max, type(uint256).max);
        _settleExternal(100 * USDT, keccak256("a"));
        vm.warp(block.timestamp + 1 hours);
        assertGt(vending.externalAvailable(), type(uint256).max - 100 * USDT);
        _settleExternal(100 * USDT, keccak256("b"));
    }

    function testFuzz_externalAvailable_neverExceedsTheCap(uint256 maxPerDay, uint256 spent, uint256 elapsed) public {
        maxPerDay = bound(maxPerDay, 1, type(uint128).max);
        spent = bound(spent, 1, maxPerDay);
        elapsed = bound(elapsed, 0, 10 days);
        _setLimits(maxPerDay, maxPerDay);
        vm.deal(address(vending), type(uint128).max);
        vm.prank(owner);
        vending.setRate(USDT_SCALE_RATE); // 1 wei of XON per USDT unit: never rounds to 0, fits the reserve
        _settleExternal(spent, keccak256("fuzz"));
        vm.warp(block.timestamp + elapsed);
        uint256 available = vending.externalAvailable();
        assertLe(available, maxPerDay);
        assertGe(available, maxPerDay - spent);
    }
}

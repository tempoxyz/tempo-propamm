// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { IPriceOracle } from "../src/interfaces/IPriceOracle.sol";
import { ITIP20 } from "../src/interfaces/ITIP20.sol";
import { DirectPropAMMRebalanceController } from "../src/DirectPropAMMRebalanceController.sol";
import { IDirectPropAMM } from "../src/interfaces/IDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockOracle } from "./mocks/MockOracle.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";
import { ManagedPoolFixture } from "./managed/utils/ManagedPoolFixture.sol";
import { VirtualAddress } from "./v2/utils/VirtualAddress.sol";

contract DirectPropAMMRebalanceControllerTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant PRICE = 1e8; // 1 quote per base with 8 decimals.
    uint256 internal constant INVENTORY = 8_000_000 * UNIT;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal taker = makeAddr("taker");
    address internal baseLiquidationAddress = makeAddr("baseLiquidationAddress");
    address internal quoteLiquidationAddress = makeAddr("quoteLiquidationAddress");

    MockTIP20 internal base;
    MockTIP20 internal quote;
    MockOracle internal oracle;
    MockAddressRegistry internal registry;
    DirectPropAMM internal pool;
    DirectPropAMMRebalanceController internal controller;

    // Base at index 0, quote at index 1. Expected balances come from actions, never from contract reads.
    struct WorkflowLedger {
        uint256[2] inventory;
        uint256[2] pending;
        uint256[2] escrow;
        uint256[2] taker;
        bool paused;
    }

    struct WorkflowStep {
        uint256 seed;
        uint256 side;
        uint256 other;
        uint256 action;
        uint256 amount;
    }

    function setUp() external {
        vm.warp(1_000_000);
        registry = new MockAddressRegistry();
        base = new MockTIP20("BASE", 6);
        quote = new MockTIP20("QUOTE", 6);
        oracle = new MockOracle(8, PRICE, block.timestamp);

        pool = new DirectPropAMM(base, quote, oracle, registry, address(this), guardian, 90_000, 50);
        vm.expectEmit();
        emit DirectPropAMMRebalanceController.LiquidationAddressSet(address(base), baseLiquidationAddress);
        vm.expectEmit();
        emit DirectPropAMMRebalanceController.LiquidationAddressSet(address(quote), quoteLiquidationAddress);
        vm.expectEmit();
        emit DirectPropAMMRebalanceController.KeeperUpdated(address(0), keeper);
        controller = new DirectPropAMMRebalanceController(
            IDirectPropAMM(address(pool)),
            owner,
            keeper,
            _two(address(base), address(quote)),
            _two(baseLiquidationAddress, quoteLiquidationAddress)
        );
        pool.transferOwnership(address(controller));

        vm.startPrank(owner);
        controller.execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ()));
        controller.execute(abi.encodeCall(DirectPropAMM.unpause, ()));
        vm.stopPrank();

        base.mint(address(pool), INVENTORY);
        quote.mint(address(pool), INVENTORY);
    }

    function test_constructorBindsPoolTokensAndLiquidationAddresses() external view {
        assertEq(controller.owner(), owner);
        assertEq(address(controller.pool()), address(pool));
        assertEq(controller.keeper(), keeper);
        address[] memory tokens = controller.tokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(base));
        assertEq(tokens[1], address(quote));
        assertEq(controller.liquidationAddress(address(base)), baseLiquidationAddress);
        assertEq(controller.liquidationAddress(address(quote)), quoteLiquidationAddress);
        assertEq(controller.liquidationAddress(address(0xBEEF)), address(0));
    }

    function test_constructorRejectsBadAddresses() external {
        address[] memory tokens = _two(address(base), address(quote));
        // Zero, the pool, or the controller itself: the pool refuses the first two, and the controller can't move
        // what it receives.
        for (uint256 i; i < 6; ++i) {
            address bad = i % 3 == 0 ? address(0) : i % 3 == 1 ? address(pool) : _nextControllerAddress();
            address[] memory destinations =
                i < 3 ? _two(baseLiquidationAddress, bad) : _two(bad, quoteLiquidationAddress);
            vm.expectRevert(DirectPropAMMRebalanceController.InvalidAddress.selector);
            _newController(tokens, destinations);
        }

        vm.expectRevert(DirectPropAMMRebalanceController.InvalidAddress.selector);
        _newController(_two(address(base), address(0)), _two(baseLiquidationAddress, quoteLiquidationAddress));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DirectPropAMMRebalanceController(
            IDirectPropAMM(address(pool)),
            address(0),
            keeper,
            tokens,
            _two(baseLiquidationAddress, quoteLiquidationAddress)
        );

        // The controller reads nothing from the pool, so it checks that the pool has code.
        address[2] memory badPools = [address(0), makeAddr("eoaPool")];
        for (uint256 i; i < badPools.length; ++i) {
            vm.expectRevert(DirectPropAMMRebalanceController.InvalidAddress.selector);
            new DirectPropAMMRebalanceController(
                IDirectPropAMM(badPools[i]),
                owner,
                keeper,
                tokens,
                _two(baseLiquidationAddress, quoteLiquidationAddress)
            );
        }
    }

    function test_constructorRejectsBadTokenLists() external {
        address[] memory none = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMRebalanceController.InvalidTokenCount.selector, 0, 0));
        _newController(none, none);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMRebalanceController.InvalidTokenCount.selector, 2, 1));
        _newController(_two(address(base), address(quote)), _one(baseLiquidationAddress));
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMRebalanceController.InvalidTokenCount.selector, 1, 2));
        _newController(_one(address(base)), _two(baseLiquidationAddress, quoteLiquidationAddress));

        uint256 max = controller.MAX_TOKENS();
        address[] memory tokens = new address[](max + 1);
        address[] memory destinations = new address[](max + 1);
        for (uint256 i; i <= max; ++i) {
            tokens[i] = address(uint160(0x1000 + i));
            destinations[i] = address(uint160(0x2000 + i));
        }
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMMRebalanceController.InvalidTokenCount.selector, max + 1, max + 1)
        );
        _newController(tokens, destinations);
        assembly ("memory-safe") {
            mstore(tokens, max)
            mstore(destinations, max)
        }
        assertEq(_newController(tokens, destinations).tokens().length, max);

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMRebalanceController.DuplicateToken.selector, address(base)));
        _newController(_two(address(base), address(base)), _two(baseLiquidationAddress, quoteLiquidationAddress));

        // One liquidation address may serve two tokens.
        DirectPropAMMRebalanceController shared =
            _newController(_two(address(base), address(quote)), _two(baseLiquidationAddress, baseLiquidationAddress));
        assertEq(shared.liquidationAddress(address(quote)), baseLiquidationAddress);
    }

    function test_rebalanceRejectsATokenWithoutALiquidationAddress() external {
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMRebalanceController.UnsupportedToken.selector, address(0)));
        vm.prank(keeper);
        controller.rebalance(address(0), UNIT);
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMMRebalanceController.UnsupportedToken.selector, address(0xBEEF))
        );
        vm.prank(keeper);
        controller.rebalance(address(0xBEEF), UNIT);
        assertFalse(pool.paused());
    }

    function test_constructorAllowsUnsetKeeperAndEmitsIt() external {
        vm.expectEmit();
        emit DirectPropAMMRebalanceController.KeeperUpdated(address(0), address(0));
        DirectPropAMMRebalanceController next = new DirectPropAMMRebalanceController(
            IDirectPropAMM(address(pool)),
            owner,
            address(0),
            _two(address(base), address(quote)),
            _two(baseLiquidationAddress, quoteLiquidationAddress)
        );
        assertEq(next.keeper(), address(0));
        _exec(abi.encodeCall(DirectPropAMM.transferOwnership, (address(next))));
        vm.prank(owner);
        next.execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ()));

        vm.expectRevert(DirectPropAMMRebalanceController.NotKeeper.selector);
        vm.prank(keeper);
        next.rebalance(address(base), UNIT);

        vm.expectEmit(address(next));
        emit DirectPropAMMRebalanceController.KeeperUpdated(address(0), keeper);
        vm.prank(owner);
        next.setKeeper(keeper);
        vm.prank(keeper);
        next.rebalance(address(base), UNIT);
        assertEq(base.balanceOf(baseLiquidationAddress), UNIT);
    }

    function test_ownerControlsPoolThroughExecute() external {
        assertEq(pool.owner(), address(controller));

        bytes memory data = abi.encodeCall(DirectPropAMM.setTakerAllowed, (address(0xBEEF), true));
        vm.expectEmit(address(controller));
        emit DirectPropAMMRebalanceController.Executed(data);
        vm.prank(owner);
        controller.execute(data);
        assertTrue(pool.takerAllowed(address(0xBEEF)));
    }

    function test_ownerCanWithdrawToTreasury() external {
        vm.startPrank(owner);
        controller.execute(abi.encodeCall(DirectPropAMM.pause, ()));
        controller.execute(abi.encodeCall(DirectPropAMM.withdraw, (address(quote), treasury, UNIT, "")));
        vm.stopPrank();

        assertEq(quote.balanceOf(treasury), UNIT);
    }

    function test_executeBubblesRevert() external {
        vm.expectRevert(DirectPropAMM.NotPaused.selector);
        vm.prank(owner);
        controller.execute(abi.encodeCall(DirectPropAMM.withdraw, (address(quote), treasury, UNIT, "")));
    }

    function test_onlyOwnerConfigures() external {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper);
        vm.startPrank(keeper);
        vm.expectRevert(notOwner);
        controller.execute(abi.encodeCall(DirectPropAMM.pause, ()));
        vm.expectRevert(notOwner);
        controller.setKeeper(keeper);
        vm.expectRevert(notOwner);
        controller.transferOwnership(keeper);
        vm.stopPrank();
    }

    function test_rebalanceSendsInventoryToLiquidationAddressAndStaysActive() external {
        // Check the actual token call, not only the pool event: Bridge does not route this by memo.
        vm.expectCall(
            address(base),
            abi.encodeCall(ITIP20.transferWithMemo, (baseLiquidationAddress, 3_000_000 * UNIT, bytes32(0)))
        );
        vm.expectEmit(address(controller));
        emit DirectPropAMMRebalanceController.Rebalanced(address(base), baseLiquidationAddress, 3_000_000 * UNIT);
        vm.prank(keeper);
        controller.rebalance(address(base), 3_000_000 * UNIT);

        assertEq(base.balanceOf(baseLiquidationAddress), 3_000_000 * UNIT);
        assertEq(base.balanceOf(address(pool)), INVENTORY - 3_000_000 * UNIT);
        assertEq(base.balanceOf(address(controller)), 0);
        assertFalse(pool.paused());

        vm.prank(keeper);
        controller.rebalance(address(quote), UNIT);
        assertEq(quote.balanceOf(quoteLiquidationAddress), UNIT);
    }

    function test_rebalanceRejectsPausedPool() external {
        vm.prank(guardian);
        pool.pause();

        vm.expectRevert(DirectPropAMMRebalanceController.PoolPaused.selector);
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);
        assertEq(base.balanceOf(address(pool)), INVENTORY);
        assertEq(base.balanceOf(baseLiquidationAddress), 0);
        assertTrue(pool.paused());
    }

    function test_rebalanceRevertsWhenPoolCannotReactivate() external {
        vm.warp(block.timestamp + 90_001);

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.StaleOraclePrice.selector, 1_000_000, 90_000));
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);

        assertEq(base.balanceOf(address(pool)), INVENTORY);
        assertEq(base.balanceOf(baseLiquidationAddress), 0);
        assertFalse(pool.paused());
    }

    function test_rebalanceValidatesBothAnchorsWithoutResettingThem() external {
        // Give the base direction a newer anchor; the quote direction must still constrain unpause.
        oracle.setPrice(100_400_000, block.timestamp);
        vm.startPrank(owner);
        controller.execute(abi.encodeCall(DirectPropAMM.pause, ()));
        controller.execute(abi.encodeCall(DirectPropAMM.resetPriceAnchor, (true)));
        controller.execute(abi.encodeCall(DirectPropAMM.unpause, ()));
        vm.stopPrank();

        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);
        assertEq(pool.priceAnchor(true), 100_400_000);
        assertEq(pool.priceAnchor(false), PRICE);

        // Within 50 bps of the base anchor, but outside 50 bps of the quote anchor.
        oracle.setPrice(100_600_000, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.PriceDeviationExceeded.selector, false, 100_600_000, PRICE, 50)
        );
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);

        assertEq(pool.priceAnchor(true), 100_400_000);
        assertEq(pool.priceAnchor(false), PRICE);
        assertEq(base.balanceOf(address(pool)), INVENTORY - UNIT);
        assertEq(base.balanceOf(baseLiquidationAddress), UNIT);
        assertFalse(pool.paused());
    }

    function test_rebalanceResolvesVirtualLiquidationAddress() external {
        address master = makeAddr("bridgeMaster");
        registry.setResolution(baseLiquidationAddress, master);
        base.setResolver(registry);

        vm.prank(keeper);
        controller.rebalance(address(base), 3 * UNIT);

        assertEq(base.balanceOf(master), 3 * UNIT);
        assertEq(base.balanceOf(baseLiquidationAddress), 0);
        assertEq(base.balanceOf(address(pool)), INVENTORY - 3 * UNIT);
        assertFalse(pool.paused());
    }

    /// @dev A `DirectPropAMM` resolves a TIP-1022 virtual liquidation address and pays its master, so the controller,
    /// which refuses one only for a `ManagedDirectPropAMM` (told apart by `pairCount()`), takes it here.
    function test_constructorAcceptsAVirtualLiquidationAddressForADirectPropAMM() external {
        address master = makeAddr("bridgeMaster");
        address virtualLiquidation = VirtualAddress.make(0x0badf00d, 1);
        registry.setResolution(virtualLiquidation, master);
        base.setResolver(registry);
        DirectPropAMMRebalanceController next =
            _newController(_two(address(base), address(quote)), _two(virtualLiquidation, quoteLiquidationAddress));
        assertEq(next.liquidationAddress(address(base)), virtualLiquidation);
        _exec(abi.encodeCall(DirectPropAMM.transferOwnership, (address(next))));
        vm.prank(owner);
        next.execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ()));

        vm.prank(keeper);
        next.rebalance(address(base), 3 * UNIT);
        assertEq(base.balanceOf(master), 3 * UNIT, "the master is paid");
        assertEq(base.balanceOf(virtualLiquidation), 0, "the virtual address holds nothing");
        assertEq(base.balanceOf(address(pool)), INVENTORY - 3 * UNIT);
        assertFalse(pool.paused());
    }

    function test_rebalanceRejectsRedirectedPayment() external {
        base.setRedirectRecipient(keeper);

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.ExactBalanceDeltaFailed.selector, address(base), UNIT, 0));
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);

        assertEq(base.balanceOf(address(pool)), INVENTORY);
        assertEq(base.balanceOf(baseLiquidationAddress), 0);
        assertEq(base.balanceOf(keeper), 0);
        assertFalse(pool.paused());
    }

    /// @dev A token transfer fee must revert atomically, unlike an offchain Bridge fee deducted from a later payout.
    function testFuzz_rebalanceRejectsTransferFee(bool baseToQuote, uint96 amountSeed, uint16 feeSeed) external {
        MockTIP20 token = baseToQuote ? base : quote;
        address destination = baseToQuote ? baseLiquidationAddress : quoteLiquidationAddress;
        uint256 amount = bound(amountSeed, 10_000, INVENTORY);
        // The bound is below uint16's maximum.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps = uint16(bound(feeSeed, 1, 10_000));
        uint256 received = amount - amount * feeBps / 10_000;
        token.setFeeBps(feeBps);
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.ExactBalanceDeltaFailed.selector, address(token), amount, received)
        );
        vm.prank(keeper);
        controller.rebalance(_token(baseToQuote), amount);
        assertEq(base.balanceOf(address(pool)), INVENTORY);
        assertEq(quote.balanceOf(address(pool)), INVENTORY);
        assertEq(token.balanceOf(destination), 0);
        assertFalse(pool.paused());
    }

    function test_rebalanceRejectsZeroAndExcessInventory() external {
        vm.startPrank(keeper);
        vm.expectRevert(DirectPropAMM.AmountIsZero.selector);
        controller.rebalance(address(quote), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectPropAMM.InsufficientInventory.selector, address(quote), INVENTORY, INVENTORY + 1
            )
        );
        controller.rebalance(address(quote), INVENTORY + 1);
        vm.stopPrank();

        assertEq(quote.balanceOf(address(pool)), INVENTORY);
        assertEq(quote.balanceOf(quoteLiquidationAddress), 0);
        assertFalse(pool.paused());
    }

    function test_rebalanceRequiresKeeper() external {
        vm.expectRevert(DirectPropAMMRebalanceController.NotKeeper.selector);
        vm.prank(owner);
        controller.rebalance(address(base), UNIT);
    }

    function test_setKeeperReplacesKeeper() external {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        controller.setKeeper(newKeeper);

        vm.expectRevert(DirectPropAMMRebalanceController.NotKeeper.selector);
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);

        vm.prank(newKeeper);
        controller.rebalance(address(base), UNIT);
        assertEq(base.balanceOf(baseLiquidationAddress), UNIT);
    }

    function test_setKeeperZeroDisablesRebalancing() external {
        vm.prank(owner);
        controller.setKeeper(address(0));
        assertEq(controller.keeper(), address(0));

        vm.expectRevert(DirectPropAMMRebalanceController.NotKeeper.selector);
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);
        assertEq(base.balanceOf(address(pool)), INVENTORY);
        assertFalse(pool.paused());
    }

    function test_ownerCannotRenounceOwnership() external {
        vm.expectRevert(DirectPropAMMRebalanceController.Disabled.selector);
        vm.prank(owner);
        controller.renounceOwnership();

        assertEq(controller.owner(), owner);
        assertEq(pool.owner(), address(controller));
        vm.prank(owner);
        controller.setKeeper(address(0));
        assertEq(controller.keeper(), address(0));
    }

    function test_ownerTransferIsTwoStep() external {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        controller.transferOwnership(newOwner);
        assertEq(controller.owner(), owner);
        assertEq(controller.pendingOwner(), newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vm.prank(newOwner);
        controller.execute(abi.encodeCall(DirectPropAMM.pause, ()));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vm.prank(keeper);
        controller.acceptOwnership();

        // The current owner retains authority while a transfer is pending.
        _exec(abi.encodeCall(DirectPropAMM.setTakerAllowed, (taker, true)));
        assertTrue(pool.takerAllowed(taker));

        vm.prank(newOwner);
        controller.acceptOwnership();
        assertEq(controller.owner(), newOwner);
        assertEq(controller.pendingOwner(), address(0));
        assertEq(pool.owner(), address(controller));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        controller.setKeeper(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        _exec(abi.encodeCall(DirectPropAMM.pause, ()));

        // Handover does not revoke the hot key. The new owner must do that explicitly.
        assertEq(controller.keeper(), keeper);
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);
        assertEq(base.balanceOf(baseLiquidationAddress), UNIT);
        vm.startPrank(newOwner);
        controller.execute(abi.encodeCall(DirectPropAMM.setTakerAllowed, (taker, false)));
        controller.setKeeper(address(0));
        vm.stopPrank();
        assertFalse(pool.takerAllowed(taker));
        vm.expectRevert(DirectPropAMMRebalanceController.NotKeeper.selector);
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);
    }

    // ---------------------------------------------------------------- end-to-end flows

    /// @dev A taker sells base for quote, the keeper sends the base to its Bridge liquidation address, and Bridge sends
    /// quote straight into the pool, where it is tradable without any `fund` call.
    function test_migrationRoundTrip() external {
        _allowTaker();
        base.mint(taker, 10_000_000 * UNIT);

        assertEq(_swapBaseForQuote(2_000_000 * UNIT), 2_000_000 * UNIT);
        assertEq(base.balanceOf(address(pool)), INVENTORY + 2_000_000 * UNIT);
        assertEq(quote.balanceOf(address(pool)), INVENTORY - 2_000_000 * UNIT);

        vm.prank(keeper);
        controller.rebalance(address(base), 2_000_000 * UNIT);
        _bridgeDelivers(quote, baseLiquidationAddress, 2_000_000 * UNIT);
        assertEq(base.balanceOf(address(pool)), INVENTORY);
        assertEq(quote.balanceOf(address(pool)), INVENTORY);

        // The whole book, including the Bridge delivery, is available to the next swap.
        assertEq(_swapBaseForQuote(INVENTORY), INVENTORY);
        assertEq(quote.balanceOf(address(pool)), 0);
        assertEq(quote.balanceOf(taker), INVENTORY + 2_000_000 * UNIT);
        assertEq(base.balanceOf(address(controller)) + quote.balanceOf(address(controller)), 0);
    }

    function test_pendingConversionOnlyReplenishesLiquidityAsPayoutsArrive() external {
        _allowTaker();
        base.mint(taker, 10_000_000 * UNIT);
        assertEq(_swapBaseForQuote(2_000_000 * UNIT), 2_000_000 * UNIT);
        vm.prank(keeper);
        controller.rebalance(address(base), 2_000_000 * UNIT);

        // Sending to Bridge creates no onchain receivable. Remaining inventory trades normally, then runs out.
        assertEq(_swapBaseForQuote(6_000_000 * UNIT), 6_000_000 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.InsufficientInventory.selector, address(quote), 0, UNIT));
        _swapBaseForQuote(UNIT);
        assertEq(base.balanceOf(taker), 2_000_000 * UNIT);
        assertEq(quote.balanceOf(address(pool)), 0);
        assertFalse(pool.paused());

        vm.warp(1_000_060);
        _bridgeDelivers(quote, baseLiquidationAddress, 1_000_000 * UNIT);
        assertEq(_swapBaseForQuote(1_000_000 * UNIT), 1_000_000 * UNIT);

        // The final payment is 1,000 quote tokens short of par due to external conversion fees/spread.
        vm.warp(1_000_120);
        _bridgeDelivers(quote, baseLiquidationAddress, 999_000 * UNIT);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectPropAMM.InsufficientInventory.selector, address(quote), 999_000 * UNIT, 1_000_000 * UNIT
            )
        );
        _swapBaseForQuote(1_000_000 * UNIT);
        assertEq(_swapBaseForQuote(999_000 * UNIT), 999_000 * UNIT);
        assertEq(base.balanceOf(taker), 1_000 * UNIT);
        assertEq(quote.balanceOf(taker), 9_999_000 * UNIT);
        assertEq(base.balanceOf(address(pool)), 15_999_000 * UNIT);
        assertEq(quote.balanceOf(address(pool)), 0);
    }

    function test_outOfOrderPayoutAndRefundDoNotUndoGuardianPause() external {
        vm.startPrank(keeper);
        controller.rebalance(address(base), 10 * UNIT);
        controller.rebalance(address(quote), 7 * UNIT);
        vm.stopPrank();

        // The second conversion finishes first, losing one unit to external fees/spread.
        _bridgeDelivers(base, quoteLiquidationAddress, 6 * UNIT);
        assertEq(base.balanceOf(address(pool)), INVENTORY - 4 * UNIT);
        assertEq(quote.balanceOf(address(pool)), INVENTORY - 7 * UNIT);
        vm.prank(guardian);
        pool.pause();
        vm.warp(1_000_060);

        // Bridge converts only three of the first ten units and refunds the other seven in the original token.
        _bridgeDelivers(quote, baseLiquidationAddress, 3 * UNIT);
        vm.prank(baseLiquidationAddress);
        base.transferWithMemo(address(pool), 7 * UNIT, "refund");
        assertEq(base.balanceOf(address(pool)), INVENTORY + 3 * UNIT);
        assertEq(quote.balanceOf(address(pool)), INVENTORY - 4 * UNIT);
        assertEq(base.balanceOf(baseLiquidationAddress), 3 * UNIT);
        assertTrue(pool.paused());

        vm.expectRevert(DirectPropAMMRebalanceController.PoolPaused.selector);
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);
        vm.expectRevert(DirectPropAMM.Paused.selector);
        _swapBaseForQuote(UNIT);
        _exec(abi.encodeCall(DirectPropAMM.unpause, ()));
        assertFalse(pool.paused());
    }

    function test_windDownWithdrawsEverythingToTreasury() external {
        _exec(abi.encodeCall(DirectPropAMM.pause, ()));
        vm.expectRevert(DirectPropAMMRebalanceController.PoolPaused.selector);
        vm.prank(keeper);
        controller.rebalance(address(quote), UNIT);

        _exec(abi.encodeCall(DirectPropAMM.withdraw, (address(base), treasury, INVENTORY, "wind-down")));
        _exec(abi.encodeCall(DirectPropAMM.withdraw, (address(quote), treasury, INVENTORY, "wind-down")));

        // A Bridge payout that lands late is withdrawn the same way.
        _bridgeDelivers(quote, baseLiquidationAddress, 5 * UNIT);
        _exec(abi.encodeCall(DirectPropAMM.withdraw, (address(quote), treasury, 5 * UNIT, "late")));

        assertEq(base.balanceOf(address(pool)), 0);
        assertEq(quote.balanceOf(address(pool)), 0);
        assertEq(base.balanceOf(treasury), INVENTORY);
        assertEq(quote.balanceOf(treasury), INVENTORY + 5 * UNIT);
        assertTrue(pool.paused());
    }

    function test_withdrawRejectsBadRequests() external {
        _exec(abi.encodeCall(DirectPropAMM.pause, ()));
        vm.startPrank(owner);

        vm.expectRevert(
            abi.encodeWithSelector(
                DirectPropAMM.InsufficientInventory.selector, address(quote), INVENTORY, INVENTORY + 1
            )
        );
        controller.execute(abi.encodeCall(DirectPropAMM.withdraw, (address(quote), treasury, INVENTORY + 1, "")));

        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.UnsupportedToken.selector, address(0xBEEF)));
        controller.execute(abi.encodeCall(DirectPropAMM.withdraw, (address(0xBEEF), treasury, UNIT, "")));

        vm.expectRevert(DirectPropAMM.InvalidAddress.selector);
        controller.execute(abi.encodeCall(DirectPropAMM.withdraw, (address(quote), address(pool), UNIT, "")));
        vm.stopPrank();
    }

    /// @dev Changing a liquidation address means a new controller; the old controller loses all pool authority.
    function test_liquidationAddressChangeMigratesPoolToNewController() external {
        vm.prank(keeper);
        controller.rebalance(address(base), 5 * UNIT);
        address newLiquidationAddress = makeAddr("newBaseLiquidationAddress");
        DirectPropAMMRebalanceController next =
            _newController(_two(address(base), address(quote)), _two(newLiquidationAddress, quoteLiquidationAddress));
        _exec(abi.encodeCall(DirectPropAMM.transferOwnership, (address(next))));
        vm.prank(owner);
        next.execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ()));
        assertEq(pool.owner(), address(next));

        vm.expectRevert(DirectPropAMM.NotGuardianOrOwner.selector);
        vm.prank(keeper);
        controller.rebalance(address(base), UNIT);
        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        _exec(abi.encodeCall(DirectPropAMM.setGuardian, (owner)));

        vm.prank(keeper);
        next.rebalance(address(base), UNIT);
        assertEq(base.balanceOf(newLiquidationAddress), UNIT);

        // A pending old-route payout still targets the same pool, not either controller.
        _bridgeDelivers(quote, baseLiquidationAddress, 4 * UNIT);
        assertEq(base.balanceOf(address(pool)), INVENTORY - 6 * UNIT);
        assertEq(quote.balanceOf(address(pool)), INVENTORY + 4 * UNIT);
        assertEq(quote.balanceOf(address(controller)), 0);
        assertEq(quote.balanceOf(address(next)), 0);
        assertEq(pool.owner(), address(next));
    }

    /// @dev The occasional owner calls from the operating plan, all made through `execute`.
    function test_ownerConfigCalls() external {
        MockOracle newOracle = new MockOracle(8, PRICE, block.timestamp);
        address newGuardian = makeAddr("newGuardian");

        _exec(abi.encodeCall(DirectPropAMM.pause, ()));
        _exec(abi.encodeCall(DirectPropAMM.setOracle, (IPriceOracle(address(newOracle)))));
        _exec(abi.encodeCall(DirectPropAMM.setMaxOracleAge, (3_600)));
        _exec(abi.encodeCall(DirectPropAMM.setMaxPriceDeviationBps, (25)));
        newOracle.setPrice(PRICE * 101 / 100, block.timestamp);
        _exec(abi.encodeCall(DirectPropAMM.resetPriceAnchor, (true)));
        _exec(abi.encodeCall(DirectPropAMM.resetPriceAnchor, (false)));
        _exec(abi.encodeCall(DirectPropAMM.setGuardian, (newGuardian)));
        _exec(abi.encodeCall(DirectPropAMM.setRecipientAllowed, (taker, true)));
        _exec(abi.encodeCall(DirectPropAMM.unpause, ()));

        assertEq(address(pool.oracle()), address(newOracle));
        assertEq(pool.maxOracleAge(), 3_600);
        assertEq(pool.maxPriceDeviationBps(), 25);
        assertEq(pool.priceAnchor(true), PRICE * 101 / 100);
        assertEq(pool.priceAnchor(false), PRICE * 101 / 100);
        assertEq(pool.guardian(), newGuardian);
        assertTrue(pool.recipientAllowed(taker));
        assertFalse(pool.paused());
    }

    /// @dev Unequal inventories catch reading the wrong token's balance; preexisting recipient funds require deltas.
    function testFuzz_keeperCanOnlyMoveInventoryToLiquidationAddresses(
        bool baseToQuote,
        uint256 amount,
        uint96 inventorySeed,
        uint96 otherSeed,
        uint96 recipientSeed
    ) external {
        MockTIP20 token = baseToQuote ? base : quote;
        MockTIP20 other = baseToQuote ? quote : base;
        address liquidationAddress = baseToQuote ? baseLiquidationAddress : quoteLiquidationAddress;
        address otherLiquidationAddress = baseToQuote ? quoteLiquidationAddress : baseLiquidationAddress;
        uint256 inventory = bound(inventorySeed, 1, 2 * INVENTORY);
        uint256 otherInventory = bound(otherSeed, 0, inventory - 1);
        uint256 recipientBefore = bound(recipientSeed, 1, INVENTORY);
        deal(address(token), address(pool), inventory);
        deal(address(other), address(pool), otherInventory);
        token.mint(liquidationAddress, recipientBefore);
        other.mint(otherLiquidationAddress, recipientBefore + 1);
        amount = bound(amount, 1, inventory);

        vm.expectCall(address(token), abi.encodeCall(ITIP20.transferWithMemo, (liquidationAddress, amount, bytes32(0))));
        vm.expectEmit(address(controller));
        emit DirectPropAMMRebalanceController.Rebalanced(address(token), liquidationAddress, amount);
        vm.prank(keeper);
        controller.rebalance(_token(baseToQuote), amount);

        assertEq(token.balanceOf(liquidationAddress), recipientBefore + amount);
        assertEq(token.balanceOf(address(pool)), inventory - amount);
        assertEq(token.balanceOf(keeper), 0);
        assertEq(token.balanceOf(address(controller)), 0);
        assertEq(token.balanceOf(otherLiquidationAddress), 0);
        assertEq(other.balanceOf(address(pool)), otherInventory);
        assertEq(other.balanceOf(otherLiquidationAddress), recipientBefore + 1);
        assertEq(other.balanceOf(liquidationAddress), 0);
        assertEq(other.balanceOf(keeper), 0);
        assertEq(other.balanceOf(address(controller)), 0);
        assertEq(pool.priceAnchor(true), PRICE);
        assertEq(pool.priceAnchor(false), PRICE);
        assertEq(pool.owner(), address(controller));
        assertEq(pool.guardian(), guardian);
        assertEq(controller.owner(), owner);
        assertEq(controller.keeper(), keeper);
        assertFalse(pool.paused());
    }

    function testFuzz_rebalanceInventoryBoundaries(bool baseToQuote, uint96 inventorySeed) external {
        MockTIP20 token = baseToQuote ? base : quote;
        MockTIP20 other = baseToQuote ? quote : base;
        address destination = baseToQuote ? baseLiquidationAddress : quoteLiquidationAddress;
        uint256 inventory = bound(inventorySeed, 2, 2 * INVENTORY);
        deal(address(token), address(pool), inventory);

        vm.startPrank(keeper);
        vm.expectRevert(DirectPropAMM.AmountIsZero.selector);
        controller.rebalance(_token(baseToQuote), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                DirectPropAMM.InsufficientInventory.selector, address(token), inventory, inventory + 1
            )
        );
        controller.rebalance(_token(baseToQuote), inventory + 1);
        assertEq(token.balanceOf(address(pool)), inventory);
        assertEq(token.balanceOf(destination), 0);
        assertFalse(pool.paused());

        controller.rebalance(_token(baseToQuote), 1);
        assertEq(token.balanceOf(address(pool)), inventory - 1);
        assertEq(token.balanceOf(destination), 1);
        controller.rebalance(_token(baseToQuote), inventory - 1);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMM.InsufficientInventory.selector, address(token), 0, 1));
        controller.rebalance(_token(baseToQuote), 1);
        vm.stopPrank();

        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(destination), inventory);
        assertEq(other.balanceOf(address(pool)), INVENTORY);
        assertFalse(pool.paused());
    }

    /// @dev Both price bands must accept. Each run checks both inclusive endpoints and one atom outside each.
    function testFuzz_rebalanceUsesIntersectionOfAnchorBands(
        bool baseToQuote,
        bool higherIsBase,
        uint96 lowSeed,
        uint96 gapSeed,
        uint16 bpsSeed
    ) public {
        uint256 low = bound(lowSeed, 1e6, 1e24);
        uint256 high = low + bound(gapSeed, 1, low / 1000);
        uint256 bps = bound(bpsSeed, 10, 500);
        uint256 baseAnchor = higherIsBase ? high : low;
        uint256 quoteAnchor = higherIsBase ? low : high;
        _exec(abi.encodeCall(DirectPropAMM.pause, ()));
        _exec(abi.encodeCall(DirectPropAMM.setMaxPriceDeviationBps, (bps)));
        oracle.setPrice(baseAnchor, block.timestamp);
        _exec(abi.encodeCall(DirectPropAMM.resetPriceAnchor, (true)));
        oracle.setPrice(quoteAnchor, block.timestamp);
        _exec(abi.encodeCall(DirectPropAMM.resetPriceAnchor, (false)));
        oracle.setPrice(low, block.timestamp);
        _exec(abi.encodeCall(DirectPropAMM.unpause, ()));

        // Independent integer specification; ranges are small enough that multiplication cannot overflow.
        uint256 lower = high - high * bps / 10_000;
        uint256 upper = low + low * bps / 10_000;
        uint256[4] memory prices = [lower - 1, lower, upper, upper + 1];
        MockTIP20 token = baseToQuote ? base : quote;
        address destination = baseToQuote ? baseLiquidationAddress : quoteLiquidationAddress;
        uint256 sent;
        for (uint256 i; i < prices.length; ++i) {
            oracle.setPrice(prices[i], block.timestamp);
            if (i == 0 || i == 3) {
                // Rounding can make the two lower bounds equal. The pool checks base first if both reject.
                uint256 baseWidth = baseAnchor * bps / 10_000;
                bool baseRejects = prices[i] < baseAnchor - baseWidth || prices[i] > baseAnchor + baseWidth;
                vm.expectRevert(
                    abi.encodeWithSelector(
                        DirectPropAMM.PriceDeviationExceeded.selector,
                        baseRejects,
                        prices[i],
                        baseRejects ? baseAnchor : quoteAnchor,
                        bps
                    )
                );
            } else {
                sent += UNIT;
            }
            vm.prank(keeper);
            controller.rebalance(_token(baseToQuote), UNIT);
            assertEq(token.balanceOf(address(pool)), INVENTORY - sent);
            assertEq(token.balanceOf(destination), sent);
            assertEq(pool.priceAnchor(true), baseAnchor);
            assertEq(pool.priceAnchor(false), quoteAnchor);
            assertFalse(pool.paused());
        }
    }

    function test_anchorBandsCanShareRoundedLowerBoundary() external {
        // 1,000,019 - 50,000 == 1,000,020 - 50,001. Below that boundary, base rejects first despite being lower.
        testFuzz_rebalanceUsesIntersectionOfAnchorBands(true, false, 1_000_019, 1, 500);
    }

    function testFuzz_keeperRotationDisableAndReenable(address nextKeeper, address stranger, bool baseToQuote)
        external
    {
        vm.assume(nextKeeper != address(0) && nextKeeper != owner && nextKeeper != keeper);
        vm.assume(stranger != address(0) && stranger != owner && stranger != keeper && stranger != nextKeeper);
        vm.expectEmit(address(controller));
        emit DirectPropAMMRebalanceController.KeeperUpdated(keeper, nextKeeper);
        vm.prank(owner);
        controller.setKeeper(nextKeeper);
        assertEq(controller.keeper(), nextKeeper);

        address[2] memory rejected = [keeper, stranger];
        for (uint256 i; i < rejected.length; ++i) {
            vm.expectRevert(DirectPropAMMRebalanceController.NotKeeper.selector);
            vm.prank(rejected[i]);
            controller.rebalance(_token(baseToQuote), UNIT);
        }
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nextKeeper));
        vm.prank(nextKeeper);
        controller.execute(abi.encodeCall(DirectPropAMM.pause, ()));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        controller.setKeeper(stranger);
        vm.prank(nextKeeper);
        controller.rebalance(_token(baseToQuote), UNIT);

        vm.expectEmit(address(controller));
        emit DirectPropAMMRebalanceController.KeeperUpdated(nextKeeper, address(0));
        vm.prank(owner);
        controller.setKeeper(address(0));
        vm.expectRevert(DirectPropAMMRebalanceController.NotKeeper.selector);
        vm.prank(nextKeeper);
        controller.rebalance(_token(baseToQuote), UNIT);

        vm.expectEmit(address(controller));
        emit DirectPropAMMRebalanceController.KeeperUpdated(address(0), keeper);
        vm.prank(owner);
        controller.setKeeper(keeper);
        vm.prank(keeper);
        controller.rebalance(_token(baseToQuote), UNIT);
        MockTIP20 token = baseToQuote ? base : quote;
        assertEq(token.balanceOf(baseToQuote ? baseLiquidationAddress : quoteLiquidationAddress), 2 * UNIT);
        assertEq(token.balanceOf(address(pool)), INVENTORY - 2 * UNIT);
        assertEq(controller.keeper(), keeper);
        assertFalse(pool.paused());
    }

    /// @dev Start with two pending conversions, then interleave sends, partial payouts, refunds, trades and pauses.
    /// At a fixed 1:1 oracle, the independent ledger needs no pool quote or rounding implementation. Each action
    /// is a separate transaction under isolate=true; only rebalance's internal pause/withdraw/unpause is atomic.
    function testFuzz_delayedBridgeWorkflowMatchesLedger(uint256[24] memory seeds) external {
        _allowTaker();
        vm.prank(taker);
        quote.approve(address(pool), type(uint256).max);
        MockTIP20[2] memory tokens = [base, quote];
        address[2] memory destinations = [baseLiquidationAddress, quoteLiquidationAddress];
        WorkflowLedger memory ledger;
        ledger.inventory = [INVENTORY, INVENTORY / 2];
        ledger.taker = [32 * INVENTORY, 32 * INVENTORY];
        deal(address(quote), address(pool), INVENTORY / 2);
        base.mint(taker, ledger.taker[0]);
        quote.mint(taker, ledger.taker[1]);

        for (uint256 i; i < seeds.length; ++i) {
            // Per-step values live in memory so the loop fits the stack under coverage's --ir-minimum build.
            WorkflowStep memory step;
            step.seed = seeds[i];
            step.side = i < 2 ? i : (step.seed >> 8) % 2;
            step.other = 1 - step.side;
            step.action = i < 2 ? 0 : step.seed % 5;
            step.amount = bound(step.seed >> 16, 1, INVENTORY / 2);
            vm.warp(1_000_000 + (i + 1) * 60);
            oracle.setPrice(PRICE, vm.getBlockTimestamp());

            if (step.action == 0) {
                if (ledger.paused) {
                    vm.expectRevert(DirectPropAMMRebalanceController.PoolPaused.selector);
                } else if (step.amount > ledger.inventory[step.side]) {
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            DirectPropAMM.InsufficientInventory.selector,
                            address(tokens[step.side]),
                            ledger.inventory[step.side],
                            step.amount
                        )
                    );
                } else {
                    ledger.inventory[step.side] -= step.amount;
                    ledger.pending[step.side] += step.amount;
                    ledger.escrow[step.side] += step.amount;
                }
                vm.prank(keeper);
                controller.rebalance(address(tokens[step.side]), step.amount);
            } else if (step.action == 1 || step.action == 2) {
                if (ledger.pending[step.side] != 0) {
                    step.amount = bound(step.seed >> 16, 1, ledger.pending[step.side]);
                    ledger.pending[step.side] -= step.amount;
                    if (step.action == 1) {
                        // Model an external fee of 0..100 bps, independent of the pool's oracle.
                        uint256 payout = step.amount - step.amount * ((step.seed >> 160) % 101) / 10_000;
                        ledger.inventory[step.other] += payout;
                        _bridgeDelivers(tokens[step.other], destinations[step.side], payout);
                    } else {
                        ledger.escrow[step.side] -= step.amount;
                        ledger.inventory[step.side] += step.amount;
                        vm.prank(destinations[step.side]);
                        tokens[step.side].transferWithMemo(address(pool), step.amount, "refund");
                    }
                }
            } else if (step.action == 3) {
                if (ledger.paused) {
                    vm.expectRevert(DirectPropAMM.Paused.selector);
                } else if (step.amount > ledger.inventory[step.other]) {
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            DirectPropAMM.InsufficientInventory.selector,
                            address(tokens[step.other]),
                            ledger.inventory[step.other],
                            step.amount
                        )
                    );
                } else {
                    ledger.inventory[step.side] += step.amount;
                    ledger.inventory[step.other] -= step.amount;
                    ledger.taker[step.side] -= step.amount;
                    ledger.taker[step.other] += step.amount;
                }
                _swap(step.side == 0, step.amount);
            } else {
                if (ledger.paused) {
                    _exec(abi.encodeCall(DirectPropAMM.unpause, ()));
                } else {
                    vm.prank(guardian);
                    pool.pause();
                }
                ledger.paused = !ledger.paused;
            }

            for (uint256 j; j < 2; ++j) {
                assertEq(tokens[j].balanceOf(address(pool)), ledger.inventory[j], "pool ledger");
                assertEq(tokens[j].balanceOf(taker), ledger.taker[j], "taker ledger");
                assertEq(tokens[j].balanceOf(destinations[j]), ledger.escrow[j], "source escrow");
                assertEq(tokens[j].balanceOf(destinations[1 - j]), 0, "payout fully delivered");
                assertEq(tokens[j].balanceOf(address(controller)), 0, "controller holds nothing");
                assertEq(tokens[j].balanceOf(keeper), 0, "keeper holds nothing");
                assertLe(ledger.pending[j], ledger.escrow[j]);
            }
            assertEq(pool.paused(), ledger.paused);
            assertEq(pool.priceAnchor(true), PRICE);
            assertEq(pool.priceAnchor(false), PRICE);
            assertEq(pool.owner(), address(controller));
            assertEq(controller.keeper(), keeper);
        }
    }

    function _newController(address[] memory tokens, address[] memory destinations)
        internal
        returns (DirectPropAMMRebalanceController)
    {
        return new DirectPropAMMRebalanceController(IDirectPropAMM(address(pool)), owner, keeper, tokens, destinations);
    }

    /// @dev The address this test contract's next CREATE deploys to.
    function _nextControllerAddress() internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    }

    function _token(bool baseToQuote) internal view returns (address) {
        return baseToQuote ? address(base) : address(quote);
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _exec(bytes memory data) internal {
        vm.prank(owner);
        controller.execute(data);
    }

    function _allowTaker() internal {
        _exec(abi.encodeCall(DirectPropAMM.setTakerAllowed, (taker, true)));
        _exec(abi.encodeCall(DirectPropAMM.setRecipientAllowed, (taker, true)));
        vm.prank(taker);
        base.approve(address(pool), type(uint256).max);
    }

    function _swapBaseForQuote(uint256 amountIn) internal returns (uint256) {
        return _swap(true, amountIn);
    }

    function _swap(bool baseToQuote, uint256 amountIn) internal returns (uint256) {
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(taker);
        return pool.swapExactInput(
            baseToQuote, amountIn, amountIn, taker, bytes32("taker"), bytes32(amountIn), deadline, PRICE, 0, 0
        );
    }

    /// @dev Simulates only an external payout, not Bridge conversion or cross-chain conservation. Converted inputs
    /// remain at the source liquidation address in this model; refunds transfer those existing inputs back instead.
    function _bridgeDelivers(MockTIP20 token, address liquidationAddress, uint256 amount) internal {
        token.mint(liquidationAddress, amount);
        vm.prank(liquidationAddress);
        ITIP20(address(token)).transferWithMemo(address(pool), amount, "bridge");
    }
}

/// @notice One controller owning a two-pair `ManagedDirectPropAMM` (`ManagedPoolFixture`: PRIME/pathUSD and
/// EURX/pathUSD): it rebalances every token any pair uses, each to a plain liquidation address, since the pool pays no
/// TIP-1022 virtual address and the constructor refuses one for it; and its pool-wide pause cycle checks no oracle.
contract ManagedRebalanceControllerTest is ManagedPoolFixture {
    address internal owner = makeAddr("controllerOwner");
    address internal keeper = makeAddr("keeper");
    address internal primeLiquidation = makeAddr("primeLiquidation");
    address internal eurLiquidation = makeAddr("eurLiquidation");
    address internal usdLiquidation = makeAddr("usdLiquidation");

    DirectPropAMMRebalanceController internal controller;

    function setUp() public override {
        super.setUp();
        controller = _controllerFor(usdLiquidation);
        pool.transferOwnership(address(controller));
        vm.prank(owner);
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.acceptOwnership, ()));
        assertEq(pool.owner(), address(controller));
    }

    function test_rebalancesEveryTokenOfEveryPair() external {
        uint256 primeBefore = prime.balanceOf(address(pool));
        uint256 usdBefore = pathUsd.balanceOf(address(pool));
        uint256 eurBefore = eurx.balanceOf(address(pool));
        vm.startPrank(keeper);
        vm.expectEmit(address(controller));
        emit DirectPropAMMRebalanceController.Rebalanced(address(pathUsd), usdLiquidation, 5 * UNIT);
        vm.expectEmit(address(pool));
        emit IManagedDirectPropAMM.Withdrawn(address(pathUsd), usdLiquidation, 5 * UNIT, bytes32(0));
        controller.rebalance(address(pathUsd), 5 * UNIT);
        controller.rebalance(address(prime), 3 * UNIT);
        controller.rebalance(address(eurx), 2 * EUR_UNIT);
        vm.stopPrank();

        assertEq(pathUsd.balanceOf(usdLiquidation), 5 * UNIT, "the liquidation address gets its exact credit");
        assertEq(prime.balanceOf(primeLiquidation), 3 * UNIT);
        assertEq(eurx.balanceOf(eurLiquidation), 2 * EUR_UNIT);
        assertEq(pathUsd.balanceOf(address(pool)), usdBefore - 5 * UNIT);
        assertEq(prime.balanceOf(address(pool)), primeBefore - 3 * UNIT);
        assertEq(eurx.balanceOf(address(pool)), eurBefore - 2 * EUR_UNIT);
        assertFalse(pool.paused());
        assertEq(uint8(pool.pair(PRIME_PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Listed));
    }

    /// @dev A managed pool's `unpause` checks no oracle, so the keeper rebalances while a feed is stale; swaps on that
    /// pair still refuse the stale price.
    function test_rebalancesWhileAnOracleIsStale() external {
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.prank(keeper);
        controller.rebalance(address(prime), UNIT);
        assertEq(prime.balanceOf(primeLiquidation), UNIT);
        assertFalse(pool.paused());

        vm.prank(owner);
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.setMembers, (PRIME_PAIR, HOME, _one(taker), true)));
        _expectSellRevert(
            abi.encodeWithSelector(IManagedDirectPropAMM.StaleOraclePrice.selector, 1_000_000, MAX_AGE),
            PRIME_PAIR,
            taker,
            HOME
        );
    }

    /// @dev The owner's pool-wide pause stops the keeper; closing a pair doesn't, since a withdrawal changes no pair.
    function test_aPauseStopsTheKeeperAndAClosedPairDoesNot() external {
        vm.prank(owner);
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.closePair, (PRIME_PAIR)));
        vm.prank(keeper);
        controller.rebalance(address(prime), UNIT);
        assertEq(prime.balanceOf(primeLiquidation), UNIT);
        assertEq(uint8(pool.pair(PRIME_PAIR).access), uint8(IManagedDirectPropAMM.AccessMode.Closed), "still closed");

        vm.prank(owner);
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.pause, ()));
        vm.expectRevert(DirectPropAMMRebalanceController.PoolPaused.selector);
        vm.prank(keeper);
        controller.rebalance(address(prime), UNIT);
        assertTrue(pool.paused(), "the owner's pause stands");

        vm.prank(owner);
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.unpause, ()));
        vm.prank(keeper);
        controller.rebalance(address(prime), UNIT);
        assertEq(prime.balanceOf(primeLiquidation), 2 * UNIT);
    }

    /// @dev The constructor refuses a TIP-1022 virtual liquidation address for a managed pool, which would revert
    /// `VirtualRecipient` on every rebalance: for any token, whether the registry maps it to a master (a Bridge
    /// liquidation address), to the pool or to no one, and with the token it was given for. Zero and the pool still
    /// revert `InvalidAddress` first, as for a `DirectPropAMM`.
    function test_constructorRefusesAVirtualLiquidationAddress() external {
        address bridgeLiquidation = VirtualAddress.make(0x0badf00d, 7);
        address poolAlias = VirtualAddress.make(0x0dead002, 1);
        address unregistered = VirtualAddress.make(0x0dead001, 1);
        registry.setVirtual(bridgeLiquidation, makeAddr("bridgeMaster"));
        registry.setVirtual(poolAlias, address(pool));
        address[3] memory virtuals = [bridgeLiquidation, poolAlias, unregistered];
        address[3] memory tokens = [address(prime), address(pathUsd), address(eurx)];
        for (uint256 v; v < virtuals.length; ++v) {
            for (uint256 t; t < tokens.length; ++t) {
                address[3] memory destinations = [primeLiquidation, usdLiquidation, eurLiquidation];
                destinations[t] = virtuals[v];
                vm.expectRevert(
                    abi.encodeWithSelector(
                        DirectPropAMMRebalanceController.VirtualLiquidationAddress.selector, tokens[t], virtuals[v]
                    )
                );
                _controllerWith(destinations);
            }
        }
        address[2] memory invalid = [address(0), address(pool)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(DirectPropAMMRebalanceController.InvalidAddress.selector);
            _controllerFor(invalid[i]);
        }
        // The pool would refuse every such withdrawal itself.
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, bridgeLiquidation));
        vm.prank(owner);
        controller.execute(
            abi.encodeCall(IManagedDirectPropAMM.withdraw, (address(pathUsd), bridgeLiquidation, UNIT, bytes32(0)))
        );
    }

    function test_rejectsATokenItWasNotGiven() external {
        MockTIP20 stray = new MockTIP20("STRAY", 6);
        stray.mint(address(pool), UNIT);
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMMRebalanceController.UnsupportedToken.selector, address(stray))
        );
        vm.prank(keeper);
        controller.rebalance(address(stray), UNIT);

        // The owner withdraws it through `execute`: a managed pool withdraws any token, paused or not.
        vm.prank(owner);
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.withdraw, (address(stray), owner, UNIT, bytes32(0))));
        assertEq(stray.balanceOf(owner), UNIT);
    }

    /// @dev The owner runs the pool's owner calls through `execute`: lists, pair modes, pairs and withdrawals.
    function test_ownerRunsManagedOwnerCallsThroughExecute() external {
        vm.startPrank(owner);
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.setMembers, (EUR_PAIR, HOME, _one(taker), true)));
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.closePair, (PRIME_PAIR)));
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.setMaxPriceDeviationBps, (PRIME_PAIR, 25)));
        controller.execute(
            abi.encodeCall(IManagedDirectPropAMM.setPairAccess, (PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed))
        );
        controller.execute(abi.encodeCall(IManagedDirectPropAMM.withdraw, (address(eurx), owner, EUR_UNIT, bytes32(0))));
        vm.stopPrank();
        assertTrue(pool.isMember(EUR_PAIR, HOME, taker));
        assertEq(pool.pair(PRIME_PAIR).maxPriceDeviationBps, 25);
        assertEq(eurx.balanceOf(owner), EUR_UNIT);
        assertGt(_sell(EUR_PAIR, taker, HOME), 0);
    }

    function _controllerFor(address usdDestination) internal returns (DirectPropAMMRebalanceController) {
        return _controllerWith([primeLiquidation, usdDestination, eurLiquidation]);
    }

    /// @dev A controller for PRIME, pathUSD and EURX, in order, with `destinations` as their liquidation addresses.
    function _controllerWith(address[3] memory destinations) internal returns (DirectPropAMMRebalanceController) {
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(prime), address(pathUsd), address(eurx));
        address[] memory liquidations = new address[](3);
        (liquidations[0], liquidations[1], liquidations[2]) = (destinations[0], destinations[1], destinations[2]);
        return new DirectPropAMMRebalanceController(IDirectPropAMM(address(pool)), owner, keeper, tokens, liquidations);
    }
}

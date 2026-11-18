// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { ISettler } from "../../../src/v2/interfaces/ISettler.sol";
import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { VenueHookFlags } from "../../../src/v2/interfaces/IVenueHook.sol";
import { HotWord } from "../../../src/v2/libraries/HotWord.sol";
import { Settler } from "../../../src/v2/Settler.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { CallbackHook } from "../integration/utils/Actors.sol";
import { IntegrationFixture } from "../integration/utils/IntegrationFixture.sol";
import { MockTIP20V2 } from "../mocks/MockTIP20V2.sol";

/// @notice Stateful callback attacks on an otherwise live pair, with a second venue as an independent target.
contract AdversarialHookInvariantTest is StdInvariant, IntegrationFixture {
    AdversarialHookHandler internal handler;

    function setUp() public override {
        super.setUp();
        // The campaign refills a side on every action, so inventory must cover its whole bounded run.
        usd.mint(address(venueA), 1_000_000e6);
        CallbackHook hook = new CallbackHook();
        vm.startPrank(makerA);
        venueA.setPairHook(pairA, address(hook), VenueHookFlags.ALL);
        venueA.setUpdater(address(hook), true);
        vm.stopPrank();

        handler = new AdversarialHookHandler(venueA, venueB, settler, eur, usd, hook, taker, makerA, pairA, pairB);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AdversarialHookHandler.attack.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_callbacksCannotEscapeTheirWindow() public view {
        handler.checkState();
    }

    function test_hookAttackCoverage() public {
        for (uint256 kind; kind < 6; ++kind) {
            handler.attack(kind, 1e6, true);
            handler.attack(kind, 1e6, false);
        }
        assertEq(handler.reverted(), 6, "strict attacks roll back");
        assertEq(handler.settled(), 6, "swallowed attacks settle");
        handler.checkState();
    }
}

contract AdversarialHookHandler is Test {
    uint256 internal constant INVENTORY = 100_000e6;
    uint40 internal constant DEADLINE = 1_800_086_400;
    Venue public immutable attacked;
    Venue public immutable other;
    Settler public immutable swapper;
    MockTIP20V2 public immutable base;
    MockTIP20V2 public immutable quote;
    CallbackHook public immutable hook;
    address public immutable trader;
    address public immutable maker;
    uint16 public immutable attackedPair;
    uint16 public immutable otherPair;
    uint256 public settled;
    uint256 public reverted;

    constructor(
        Venue attacked_,
        Venue other_,
        Settler swapper_,
        MockTIP20V2 base_,
        MockTIP20V2 quote_,
        CallbackHook hook_,
        address trader_,
        address maker_,
        uint16 attackedPair_,
        uint16 otherPair_
    ) {
        attacked = attacked_;
        other = other_;
        swapper = swapper_;
        base = base_;
        quote = quote_;
        hook = hook_;
        trader = trader_;
        maker = maker_;
        attackedPair = attackedPair_;
        otherPair = otherPair_;
    }

    /// @dev Every handler action is one transaction under `isolate = true`: callback, failed reentry and settlement
    /// happen inside the same external call. `kind` selects the forbidden call; `strict` bubbles or swallows it.
    function attack(uint256 kind, uint256 amountSeed, bool strict) external {
        // The bounded draw is at most 20, far below uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amount = uint128(amountSeed % 20 + 1) * 1e6;
        HotWord.Fields memory fields = HotWord.unpack(attacked.hotWord(attackedPair));
        ++fields.seq;
        fields.flags = HotWord.FLAG_REFILL_BIDS;
        vm.prank(maker);
        attacked.post(abi.encodePacked(attackedPair, HotWord.pack(fields)));
        hook.clearActions();

        (CallbackHook.Phase phase, address target, bytes memory data, bytes4 expected) = _action(kind % 6, amount);
        hook.addAction(phase, target, data, strict);

        uint256 preBase = base.balanceOf(address(attacked));
        uint256 preQuote = quote.balanceOf(address(attacked));
        uint256 preTraderBase = base.balanceOf(trader);
        uint256 preTraderQuote = quote.balanceOf(trader);
        uint256 preOtherBase = base.balanceOf(address(other));
        uint256 preOtherQuote = quote.balanceOf(address(other));
        uint256 preHookBase = base.balanceOf(address(hook));
        uint256 preHookQuote = quote.balanceOf(address(hook));
        uint256 preBefore = hook.beforeCalls();
        uint256 preAfter = hook.afterCalls();
        bytes32 hot = attacked.hotWord(attackedPair);

        vm.prank(trader);
        (bool ok, bytes memory result) = address(swapper)
            .call(
                abi.encodeCall(
                    ISettler.swapExactIn,
                    (address(attacked), attackedPair, address(base), address(quote), amount, 0, 0, DEADLINE, bytes32(0))
                )
            );
        assertEq(ok, !strict, "hostile callback settlement");
        if (strict) {
            // The returned error data begins with the four-byte selector; the callback bubbles it unchanged.
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(bytes4(result), expected, "strict callback bubbles the refusal");
            ++reverted;
            assertEq(base.balanceOf(address(attacked)), preBase, "venue input rolled back");
            assertEq(quote.balanceOf(address(attacked)), preQuote, "venue output rolled back");
            assertEq(base.balanceOf(trader), preTraderBase, "trader input rolled back");
            assertEq(quote.balanceOf(trader), preTraderQuote, "trader output rolled back");
            assertEq(hook.beforeCalls(), preBefore, "before callback rolled back");
            assertEq(hook.afterCalls(), preAfter, "after callback rolled back");
            assertEq(hook.outcomes().length, 0, "callback record rolled back");
            (uint128 bids, uint128 asks) = attacked.consumed(attackedPair);
            assertEq(bids, 0, "failed fill cannot consume depth");
            assertEq(asks, 0, "failed fill cannot consume opposite depth");
        } else {
            ++settled;
            CallbackHook.Outcome[] memory outcomes = hook.outcomes();
            assertEq(outcomes.length, 1, "exactly one callback attack");
            assertFalse(outcomes[0].ok, "callback attack must fail");
            assertEq(outcomes[0].selector, expected, "callback refusal");
            uint256 output = abi.decode(result, (uint256));
            assertGt(output, 0, "settled output");
            assertEq(base.balanceOf(address(attacked)), preBase + amount, "venue receives only input");
            assertEq(quote.balanceOf(address(attacked)), preQuote - output, "venue pays only output");
            assertEq(base.balanceOf(trader), preTraderBase - amount, "trader pays only input");
            assertEq(quote.balanceOf(trader), preTraderQuote + output, "trader receives only output");
            (uint128 bids, uint128 asks) = attacked.consumed(attackedPair);
            assertEq(bids, amount, "successful fill consumes exact depth");
            assertEq(asks, 0, "opposite depth untouched");
        }
        assertEq(attacked.hotWord(attackedPair), hot, "hostile updater cannot repost during callback");
        assertEq(base.balanceOf(address(other)), preOtherBase, "other venue base unchanged");
        assertEq(quote.balanceOf(address(other)), preOtherQuote, "other venue quote unchanged");
        assertEq(base.balanceOf(address(hook)), preHookBase, "hook cannot take input");
        assertEq(quote.balanceOf(address(hook)), preHookQuote, "hook cannot take output");
        assertEq(base.balanceOf(address(swapper)), 0, "settler holds no input");
        assertEq(quote.balanceOf(address(swapper)), 0, "settler holds no output");
    }

    function checkState() external view {
        assertEq(base.balanceOf(address(swapper)), 0, "settler input invariant");
        assertEq(quote.balanceOf(address(swapper)), 0, "settler output invariant");
        assertEq(base.balanceOf(address(hook)), 0, "hook input invariant");
        assertEq(quote.balanceOf(address(hook)), 0, "hook output invariant");
        assertEq(base.balanceOf(address(other)), INVENTORY, "other venue input invariant");
        assertEq(quote.balanceOf(address(other)), INVENTORY, "other venue output invariant");
    }

    function _action(uint256 kind, uint256 amount)
        internal
        view
        returns (CallbackHook.Phase phase, address target, bytes memory data, bytes4 refusal)
    {
        if (kind == 0) {
            return (
                CallbackHook.Phase.Before,
                address(swapper),
                abi.encodeCall(
                    ISettler.swapExactIn,
                    (address(other), otherPair, address(base), address(quote), 1e6, 0, 0, DEADLINE, bytes32(0))
                ),
                ISettler.Reentrancy.selector
            );
        }
        if (kind == 1) {
            return (
                CallbackHook.Phase.After,
                address(attacked),
                abi.encodeCall(IVenue.post, (hex"01")),
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
            );
        }
        if (kind == 2) {
            return (
                CallbackHook.Phase.Before,
                address(attacked),
                abi.encodeCall(IVenue.hookTake, (address(base), 1)),
                IVenue.HookTakeNotAllowed.selector
            );
        }
        if (kind == 3) {
            return (
                CallbackHook.Phase.After,
                address(attacked),
                abi.encodeCall(IVenue.hookTake, (address(quote), 1)),
                IVenue.HookTakeNotAllowed.selector
            );
        }
        if (kind == 4) {
            return (
                CallbackHook.Phase.After,
                address(attacked),
                abi.encodeCall(IVenue.hookTake, (address(base), amount + 1)),
                IVenue.HookTakeExceedsBudget.selector
            );
        }
        return (
            CallbackHook.Phase.After,
            address(other),
            abi.encodeCall(
                IVenue.fill, (otherPair, address(base), address(quote), 1e6, true, address(hook), 0, bytes32(0))
            ),
            IVenue.NotSettler.selector
        );
    }
}

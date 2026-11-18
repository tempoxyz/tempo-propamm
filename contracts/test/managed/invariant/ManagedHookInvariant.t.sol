// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Vm } from "forge-std/Vm.sol";
import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM as IM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { IManagedPoolHook } from "../../../src/managed/interfaces/IManagedPoolHook.sol";
import { MockTIP20 } from "../../mocks/MockTIP20.sol";
import { MockOracle } from "../../mocks/MockOracle.sol";

/// @dev A separate test hook, not the migration helper. Its assertions witness final context and settlement order.
contract LedgerWitnessHook is IManagedPoolHook {
    address public immutable pool;
    mapping(address => uint16[2]) internal _fees;
    uint8 public failure;
    uint256 public beforeCalls;
    uint256 public afterCalls;
    bytes32 internal _quoteHash;
    bytes32 internal _swapHash;
    uint256[4] internal _balances;

    constructor(address pool_) {
        pool = pool_;
    }

    function supportedFlags() external pure returns (uint8) {
        return 7;
    }

    function setPolicy(address taker, uint16 sell, uint16 buy, uint8 failure_) external {
        _fees[taker] = [sell, buy];
        failure = failure_;
    }

    function expectSwap(SwapContext memory context, uint256[4] memory balances) external {
        _quoteHash = keccak256(abi.encode(context.quote));
        _swapHash = keccak256(abi.encode(context));
        _balances = balances;
    }

    function quote(QuoteContext calldata context) external view returns (uint16) {
        require(msg.sender == pool && keccak256(abi.encode(context)) == _quoteHash, "quote context");
        require(failure != 1, "quote rejected");
        if (failure == 2) return 1001;
        return _fees[context.taker][context.baseToQuote ? 0 : 1];
    }

    function beforeSwap(SwapContext calldata context) external returns (bytes4) {
        _check(context, false);
        ++beforeCalls;
        require(failure != 3, "before rejected");
        return failure == 4 ? bytes4(0) : this.beforeSwap.selector;
    }

    function afterSwap(SwapContext calldata context) external returns (bytes4) {
        _check(context, true);
        ++afterCalls;
        require(failure != 5, "after rejected");
        return failure == 6 ? bytes4(0) : this.afterSwap.selector;
    }

    function _check(SwapContext calldata context, bool after_) private view {
        require(msg.sender == pool && keccak256(abi.encode(context)) == _swapHash, "final swap context");
        require(MockTIP20(context.tokenIn).balanceOf(pool) == _balances[0] + context.amountIn, "input settled");
        require(
            MockTIP20(context.tokenIn).balanceOf(context.caller) == _balances[2] - context.amountIn, "caller funded"
        );
        uint256 payout = after_ ? context.amountOut : 0;
        require(MockTIP20(context.tokenOut).balanceOf(pool) == _balances[1] - payout, "payout order pool");
        require(MockTIP20(context.tokenOut).balanceOf(context.caller) == _balances[3] + payout, "payout order caller");
    }
}

/// @notice Independent ghost ledger over two pairs sharing quote inventory, two takers, two customer credit routes,
/// both directions and exactnesses, changing directional fees, all stage masks and rejecting hooks. No quote, fee,
/// balance or credit view is used as a pricing oracle: the ledger starts from known mints and only accepted actions.
contract ManagedHookLedgerHandler is Test {
    ManagedDirectPropAMM public immutable pool;
    address public immutable owner;
    MockTIP20[3] public tokens;
    LedgerWitnessHook[2] public hooks;
    address[2] public takers;
    uint8[2] public flags;
    bool[2] public installed;
    uint8[2] public failures;
    mapping(uint16 => mapping(address => uint16[2])) internal _fees;
    uint256[3] public inventory;
    uint256[3][2] public holdings;
    uint256[2][2][2] public credits;
    uint256[2] public beforeCount;
    uint256[2] public afterCount;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public exactInputs;
    uint256 public exactOutputs;
    uint256 public feeFills;
    uint256 public creditOnly;
    uint256 public disabledFills;
    uint256 public step;
    bytes32 private constant FEE = keccak256("HookFeeCharged(uint16,address,address,uint256)");
    bytes32 private constant CREDIT = keccak256("RoundingCreditUpdated(bytes32,uint256,uint256)");
    bytes32 private constant TRADE = keccak256(
        "TradeExecuted(uint16,address,bytes32,uint64,bytes32,address,address,uint256,uint256,uint256,uint256)"
    );

    struct Trade {
        uint16 pairIndex;
        uint256 who;
        uint256 customer;
        bool direction;
        bool exactInput;
        uint256 amount;
        uint256 gross;
        uint256 output;
        uint256 fee;
        uint256 net;
        uint256 credit;
        uint256 inputToken;
        uint256 outputToken;
        bytes32 tradeId;
    }

    constructor(ManagedDirectPropAMM pool_, MockTIP20[3] memory tokens_, address[2] memory takers_) {
        pool = pool_;
        owner = msg.sender;
        tokens = tokens_;
        takers = takers_;
        for (uint256 p; p < 2; ++p) {
            hooks[p] = new LedgerWitnessHook(address(pool_));
        }
        for (uint256 t; t < 3; ++t) {
            inventory[t] = 1e36;
            holdings[0][t] = 1e36;
            holdings[1][t] = 1e36;
        }
    }

    /// @dev Owner reconfiguration restores Listed, so all later actions are reachable without discarded reverts.
    function stages(uint256 pairSeed, uint256 mask, bool enabled) public {
        uint16 p = uint16(pairSeed % 2);
        vm.startPrank(owner);
        pool.closePair(p);
        pool.setPairHook(p, enabled ? address(hooks[p]) : address(0), enabled ? uint8(mask % 8) : 0);
        pool.setPairAccess(p, IM.AccessMode.Listed);
        vm.stopPrank();
        installed[p] = enabled;
        flags[p] = enabled ? uint8(mask % 8) : 0;
        assertLedger();
    }

    function policy(uint256 pairSeed, uint256 whoSeed, uint256 sell, uint256 buy, uint256 failureSeed) public {
        uint16 p = uint16(pairSeed % 2);
        address who = takers[whoSeed % 2];
        uint16 s = uint16(sell % 1001);
        uint16 b = uint16(buy % 1001);
        uint8 f = uint8(failureSeed % 7);
        hooks[p].setPolicy(who, s, b, f);
        _fees[p][who] = [s, b];
        failures[p] = f;
        assertLedger();
    }

    function swap(
        uint256 pairSeed,
        uint256 whoSeed,
        uint256 customerSeed,
        bool direction,
        bool exactInput,
        uint256 seed
    ) public {
        Trade memory t;
        t.pairIndex = uint16(pairSeed % 2);
        t.who = whoSeed % 2;
        t.customer = customerSeed % 2;
        t.direction = direction;
        t.exactInput = exactInput;
        t.inputToken = direction ? t.pairIndex : 2;
        t.outputToken = direction ? 2 : t.pairIndex;
        uint256 amountToken = exactInput ? t.inputToken : t.outputToken;
        uint256 unit = amountToken == 1 ? 1e18 : 1e6;
        // Smallest-unit trades exercise zero output, ceil fees and credit-only opposite-direction payouts.
        t.amount = seed % 4 == 0 ? 1 + seed % 50 : 1 + seed % (100 * unit);
        t.tradeId = bytes32(++step);
        _trade(t);
    }

    /// @dev Force both directions/exactnesses into sequences, rather than relying on random bool coverage alone.
    function roundTrip(uint256 pairSeed, uint256 whoSeed, uint256 seed) public {
        seed %= type(uint256).max - 3;
        swap(pairSeed, whoSeed, seed, true, true, seed);
        swap(pairSeed, whoSeed, seed, false, false, seed + 1);
        swap(pairSeed, whoSeed, seed, false, true, seed + 2);
        swap(pairSeed, whoSeed, seed, true, false, seed + 3);
    }

    function _trade(Trade memory t) private {
        _price(t);
        IManagedPoolHook.SwapContext memory context = IManagedPoolHook.SwapContext({
            quote: IManagedPoolHook.QuoteContext(t.pairIndex, takers[t.who], t.direction, t.exactInput, t.amount),
            sponsorId: 0,
            customerId: bytes32(t.customer + 1),
            tradeId: t.tradeId,
            caller: takers[t.who],
            tokenIn: address(tokens[t.inputToken]),
            tokenOut: address(tokens[t.outputToken]),
            amountIn: t.gross,
            amountOut: t.output
        });
        hooks[t.pairIndex].expectSwap(
            context,
            [
                inventory[t.inputToken],
                inventory[t.outputToken],
                holdings[t.who][t.inputToken],
                holdings[t.who][t.outputToken]
            ]
        );
        bytes memory refusal = _refusal(t);
        // Pool views are subjects under test, never inputs to the independent model.
        _assertQuotes(t);
        bytes memory data = t.exactInput
            ? abi.encodeCall(
                IM.swapExactInput,
                (
                    t.pairIndex,
                    t.direction,
                    t.amount,
                    t.output,
                    uint64(0),
                    context.customerId,
                    t.tradeId,
                    block.timestamp,
                    _oraclePrice(t.pairIndex),
                    0,
                    0
                )
            )
            : abi.encodeCall(
                IM.swapExactOutput,
                (
                    t.pairIndex,
                    t.direction,
                    t.amount,
                    t.gross,
                    uint64(0),
                    context.customerId,
                    t.tradeId,
                    block.timestamp,
                    _oraclePrice(t.pairIndex),
                    0,
                    0
                )
            );
        vm.recordLogs();
        vm.prank(takers[t.who]);
        (bool ok, bytes memory result) = address(pool).call(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (refusal.length != 0) {
            assertFalse(ok, "rejected hook/zero-output unexpectedly settled");
            assertEq(result, refusal, "exact refusal predicted independently");
            ++rejected;
        } else {
            assertTrue(ok, "valid modeled trade reverted");
            assertEq(abi.decode(result, (uint256)), t.exactInput ? t.output : t.gross, "gross/output result");
            _events(t, logs);
            inventory[t.inputToken] += t.gross;
            inventory[t.outputToken] -= t.output;
            holdings[t.who][t.inputToken] -= t.gross;
            holdings[t.who][t.outputToken] += t.output;
            credits[t.pairIndex][t.who][t.customer] = t.credit;
            if (flags[t.pairIndex] & 2 != 0) ++beforeCount[t.pairIndex];
            if (flags[t.pairIndex] & 4 != 0) ++afterCount[t.pairIndex];
            ++accepted;
            if (t.exactInput) ++exactInputs;
            else ++exactOutputs;
            if (t.fee != 0) ++feeFills;
            if (t.gross == 0) ++creditOnly;
            if (!installed[t.pairIndex] || flags[t.pairIndex] == 0) ++disabledFills;
        }
        // Includes every other route, taker and shared token, and both callback counters after rejected afterSwap.
        assertLedger();
    }

    /// @dev Direct bounded value accounting, deliberately unlike production's mulDiv quotient/remainder algorithm.
    function _price(Trade memory t) private view {
        uint256 inputValue = t.direction ? _oraclePrice(t.pairIndex) : _scale(t.pairIndex);
        uint256 outputValue = t.direction ? _scale(t.pairIndex) : _oraclePrice(t.pairIndex);
        uint256 oldCredit = credits[t.pairIndex][t.who][t.customer];
        uint256 bps = flags[t.pairIndex] & 1 != 0 ? _fees[t.pairIndex][takers[t.who]][t.direction ? 0 : 1] : 0;
        if (t.exactInput) {
            t.gross = t.amount;
            t.fee = _ceil(t.gross * bps, 10000);
            t.net = t.gross - t.fee;
            uint256 value = t.net * inputValue + oldCredit;
            t.output = value / outputValue;
            t.credit = value - t.output * outputValue;
        } else {
            t.output = t.amount;
            uint256 required = t.output * outputValue;
            t.net = required > oldCredit ? _ceil(required - oldCredit, inputValue) : 0;
            t.gross = _ceil(t.net * 10000, 10000 - bps);
            t.fee = t.gross - t.net;
            t.credit = t.net * inputValue + oldCredit - required;
            if (t.gross != 0) {
                uint256 less = t.gross - 1;
                assertLt(less - _ceil(less * bps, 10000), t.net, "minimal exact-output gross");
            }
        }
        assertEq(t.net * inputValue + oldCredit, t.output * outputValue + t.credit, "net value plus credit conserved");
        assertEq(t.gross - _ceil(t.gross * bps, 10000), t.net, "fee excluded from credit");
    }

    function _refusal(Trade memory t) private view returns (bytes memory) {
        uint8 f = failures[t.pairIndex];
        uint8 mask = flags[t.pairIndex];
        if (mask & 1 != 0) {
            if (f == 1) return abi.encodeWithSelector(IM.HookCallFailed.selector);
            if (f == 2) return abi.encodeWithSelector(IM.HookFeeTooHigh.selector, uint256(1001), uint256(1000));
        }
        if (t.output == 0) return abi.encodeWithSelector(IM.AmountIsZero.selector);
        if ((mask & 2 != 0 && f == 3) || (mask & 4 != 0 && f == 5)) {
            return abi.encodeWithSelector(IM.HookCallFailed.selector);
        }
        if ((mask & 2 != 0 && f == 4) || (mask & 4 != 0 && f == 6)) {
            return abi.encodeWithSelector(IM.InvalidHookResponse.selector);
        }
        return "";
    }

    function _assertQuotes(Trade memory t) private view {
        bytes memory data = t.exactInput
            ? abi.encodeCall(
                IM.quoteExactInputFor, (t.pairIndex, takers[t.who], bytes32(t.customer + 1), t.direction, t.amount)
            )
            : abi.encodeCall(
                IM.quoteExactOutputFor, (t.pairIndex, takers[t.who], bytes32(t.customer + 1), t.direction, t.amount)
            );
        (bool ok, bytes memory result) = address(pool).staticcall(data);
        uint8 f = failures[t.pairIndex];
        bool rejectedQuote = flags[t.pairIndex] & 1 != 0 && (f == 1 || f == 2);
        assertEq(ok, !rejectedQuote, "quote acceptance");
        if (!ok) return;
        (uint256 amount, uint256 price, uint256 updated, uint256 credit) =
            abi.decode(result, (uint256, uint256, uint256, uint256));
        assertEq(amount, t.exactInput ? t.output : t.gross, "quote vs independent ledger");
        assertEq(price, _oraclePrice(t.pairIndex));
        assertEq(updated, 1_000_000);
        assertEq(credit, t.credit, "quoted credit vs independent ledger");
    }

    function _events(Trade memory t, Vm.Log[] memory logs) private view {
        uint256 fees;
        uint256 trades;
        uint256 changes;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(pool)) continue;
            if (l.topics[0] == FEE) {
                ++fees;
                assertEq(l.topics[1], bytes32(uint256(t.pairIndex)));
                assertEq(l.topics[2], bytes32(uint256(uint160(takers[t.who]))));
                assertEq(l.topics[3], bytes32(uint256(uint160(address(tokens[t.inputToken])))));
                assertEq(abi.decode(l.data, (uint256)), t.fee);
            } else if (l.topics[0] == CREDIT) {
                ++changes;
                assertEq(l.topics[1], _key(t.pairIndex, t.who, t.customer));
                assertEq(l.data, abi.encode(credits[t.pairIndex][t.who][t.customer], t.credit));
            } else if (l.topics[0] == TRADE) {
                ++trades;
                assertEq(l.topics[1], bytes32(uint256(t.pairIndex)));
                assertEq(l.topics[2], bytes32(uint256(uint160(takers[t.who]))));
                assertEq(l.topics[3], bytes32(t.customer + 1));
                assertEq(
                    l.data,
                    abi.encode(
                        uint64(0),
                        t.tradeId,
                        address(tokens[t.inputToken]),
                        address(tokens[t.outputToken]),
                        t.gross,
                        t.output,
                        _oraclePrice(t.pairIndex),
                        uint256(1_000_000)
                    )
                );
            }
        }
        assertEq(fees, t.fee == 0 ? 0 : 1, "one event per nonzero retained fee");
        assertEq(trades, 1);
        assertEq(changes, 1);
    }

    function assertLedger() public view {
        for (uint256 t; t < 3; ++t) {
            assertEq(tokens[t].balanceOf(address(pool)), inventory[t], "pool ghost inventory / rollback");
            uint256 total = inventory[t];
            for (uint256 who; who < 2; ++who) {
                assertEq(tokens[t].balanceOf(takers[who]), holdings[who][t], "taker ghost balance / rollback");
                total += holdings[who][t];
            }
            assertEq(total, 3e36, "all minted tokens conserved");
            for (uint256 p; p < 2; ++p) {
                assertEq(tokens[t].balanceOf(address(hooks[p])), 0, "hook never takes custody");
                assertEq(tokens[t].allowance(address(pool), address(hooks[p])), 0, "hook has no allowance");
            }
        }
        for (uint16 p; p < 2; ++p) {
            (address h, uint8 mask) = pool.pairHook(p);
            assertEq(h, installed[p] ? address(hooks[p]) : address(0));
            assertEq(mask, flags[p]);
            assertEq(hooks[p].beforeCalls(), beforeCount[p], "before callbacks / rollback");
            assertEq(hooks[p].afterCalls(), afterCount[p], "after callbacks / rollback");
            assertEq(pool.priceAnchor(p, true), _oraclePrice(p));
            assertEq(pool.priceAnchor(p, false), _oraclePrice(p));
            for (uint256 who; who < 2; ++who) {
                for (uint256 c; c < 2; ++c) {
                    assertEq(
                        pool.roundingCredit(_key(p, who, c)), credits[p][who][c], "isolated credit ledger / rollback"
                    );
                }
            }
        }
    }

    function _key(uint16 p, uint256 who, uint256 c) private view returns (bytes32) {
        return keccak256(abi.encode(p, takers[who], bytes32(c + 1)));
    }

    function _oraclePrice(uint16 p) private pure returns (uint256) {
        return p == 0 ? 105_000_000 : 108_500_000;
    }

    function _scale(uint16 p) private pure returns (uint256) {
        return p == 0 ? 1e8 : 1e20;
    }

    function _ceil(uint256 n, uint256 d) private pure returns (uint256) {
        return n == 0 ? 0 : (n - 1) / d + 1;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.runs = 256
/// forge-config: ci.invariant.depth = 32
/// forge-config: ci.invariant.fail-on-revert = true
/// forge-config: coverage.invariant.runs = 256
/// forge-config: coverage.invariant.depth = 32
/// forge-config: coverage.invariant.fail-on-revert = true
contract ManagedHookInvariantTest is StdInvariant, Test {
    ManagedHookLedgerHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        MockTIP20[3] memory tokens = [new MockTIP20("A", 6), new MockTIP20("B", 18), new MockTIP20("Q", 6)];
        address[2] memory takers = [makeAddr("ledger-taker-0"), makeAddr("ledger-taker-1")];
        ManagedDirectPropAMM pool = new ManagedDirectPropAMM(address(this), address(0));
        pool.addPair(address(tokens[0]), address(tokens[2]), new MockOracle(8, 105_000_000, block.timestamp), 90000, 50);
        pool.addPair(address(tokens[1]), address(tokens[2]), new MockOracle(8, 108_500_000, block.timestamp), 90000, 50);
        address[] memory members = new address[](2);
        members[0] = takers[0];
        members[1] = takers[1];
        for (uint16 p; p < 2; ++p) {
            pool.setMembers(p, 0, members, true);
            pool.setPairAccess(p, IM.AccessMode.Listed);
        }
        for (uint256 t; t < 3; ++t) {
            tokens[t].mint(address(pool), 1e36);
            for (uint256 who; who < 2; ++who) {
                tokens[t].mint(takers[who], 1e36);
                vm.prank(takers[who]);
                tokens[t].approve(address(pool), type(uint256).max);
            }
        }
        pool.unpause();
        handler = new ManagedHookLedgerHandler(pool, tokens, takers);
        handler.stages(0, 7, true);
        handler.stages(1, 7, true);
        handler.policy(0, 0, 17, 901, 0);
        handler.policy(1, 0, 1000, 1, 0);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.roundTrip.selector;
        selectors[2] = handler.stages.selector;
        selectors[3] = handler.policy.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        // Native fork RPCs need not fetch arbitrary fuzz senders; swap actors still vary inside the handler.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    function invariant_independentLedgerConservesTokensCreditsAndCallbackState() external view {
        handler.assertLedger();
    }

    /// @dev Deterministic witnesses prevent a vacuous invariant campaign: fee changes, all masks, both rejection
    /// mechanisms at each stage, small-unit credits and removals are required to execute, not merely selectable.
    function test_statefulCoverageWitness() external {
        for (uint256 p; p < 2; ++p) {
            for (uint256 mask; mask < 8; ++mask) {
                handler.stages(p, mask, true);
                for (uint256 f; f < 7; ++f) {
                    handler.policy(p, 0, 17 + f, 999 - f, f);
                    handler.roundTrip(p, 0, 100_003 + f);
                }
            }
            handler.stages(p, 7, false);
            handler.roundTrip(p, 1, 103);
        }
        // 18-decimal sell generates sub-quote-unit value, then a one-base-unit exact output spends only that credit.
        handler.stages(1, 7, true);
        handler.policy(1, 0, 1000, 1000, 0);
        handler.swap(1, 0, 0, true, true, 1_000_000_000_000_000_001);
        handler.swap(1, 0, 0, false, false, 0);
        assertGt(handler.accepted(), 0, "accepted coverage");
        assertGt(handler.rejected(), 0, "rejected coverage");
        assertGt(handler.exactInputs(), 0, "exactInputs coverage");
        assertGt(handler.exactOutputs(), 0, "exactOutputs coverage");
        assertGt(handler.feeFills(), 0, "feeFills coverage");
        assertGt(handler.creditOnly(), 0, "creditOnly coverage");
        assertGt(handler.disabledFills(), 0, "disabledFills coverage");
        handler.assertLedger();
        emit log_named_uint("successful swaps", handler.accepted());
        emit log_named_uint("atomic refusals", handler.rejected());
        emit log_named_uint("credit-only exact outputs", handler.creditOnly());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockAddressRegistry } from "../mocks/MockAddressRegistry.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";

/// @notice The v1 pricing differential, pair by pair: one `ManagedDirectPropAMM` with three pairs against three
/// `DirectPropAMM` pools with the same tokens, oracles and settings. Each pair's swaps must return or revert with the
/// same bytes, move the same balances, and leave the same anchors and route credits as its v1 pool, so the pools price
/// identically under equivalent access (the taker on the pair's home list, and on v1's taker and recipient lists).
/// @dev The pairs use disjoint tokens, so each Managed pair's inventory equals its v1 pool's and `InsufficientInventory`
/// matches too: 6/6 decimals with an 8-decimal oracle, an 18-decimal base with an 8-decimal oracle, and an 18-decimal
/// quote with an 18-decimal oracle. A second test shares a quote token across pairs with ample inventory, so sharing
/// provably changes no price. `withdraw` matches too, except on a TIP-1022 virtual recipient: v1 resolves it and pays
/// its master, while the managed pool refuses it as v2 `Venue` does, an intended divergence
/// (`test_withdrawMatchesV1ExceptAVirtualRecipient`).
contract ManagedDirectPropAMMDifferentialTest is Test {
    uint256 internal constant PAIRS = 3;
    uint256 internal constant STEPS = 8;
    uint256 internal constant MAX_AGE = 90_000;
    uint256 internal constant MAX_DEVIATION_BPS = 50;
    bytes32 internal constant CUSTOMER = bytes32("c");

    address internal taker = makeAddr("taker");
    /// @dev The callers `testFuzz_accessMatchesV1Listing` swaps from: the taker and two more accounts.
    address[3] internal parties;
    /// @dev `ALPHA`'s admin, the sponsor `testFuzz_accessMatchesV1Listing` registers.
    address internal alpha = makeAddr("alpha");
    uint64 internal constant ALPHA = 7;
    uint64 internal constant UNREGISTERED = 4242;
    MockAddressRegistry internal registry;
    MockTIP20[PAIRS] internal bases;
    MockTIP20[PAIRS] internal quotes;
    MockOracle[PAIRS] internal oracles;
    uint256[PAIRS] internal basePrices;
    DirectPropAMM[PAIRS] internal v1;
    ManagedDirectPropAMM internal managed;
    /// @dev The timestamp the differential runs at, kept here so no `block.timestamp` is read across a warp.
    uint256 internal now_;
    uint256 internal fills;
    uint256 internal reverts;

    function setUp() external {
        parties = [taker, makeAddr("a1"), makeAddr("a2")];
        now_ = 1_000_000;
        vm.warp(now_);
        registry = new MockAddressRegistry();
        bases = [new MockTIP20("PRIME", 6), new MockTIP20("EURX", 18), new MockTIP20("GBPX", 6)];
        quotes = [new MockTIP20("pathUSD", 6), new MockTIP20("USDX", 6), new MockTIP20("DAI", 18)];
        basePrices = [uint256(105_000_000), uint256(108_500_000), uint256(1.27e18)];
        oracles = [
            new MockOracle(8, basePrices[0], now_),
            new MockOracle(8, basePrices[1], now_),
            new MockOracle(18, basePrices[2], now_)
        ];
        managed = new ManagedDirectPropAMM(address(this), address(0));
        address[] memory one = new address[](1);
        one[0] = taker;
        for (uint256 p; p < PAIRS; ++p) {
            v1[p] = new DirectPropAMM(
                bases[p], quotes[p], oracles[p], registry, address(this), address(this), MAX_AGE, MAX_DEVIATION_BPS
            );
            v1[p].setTakerAllowed(taker, true);
            v1[p].setRecipientAllowed(taker, true);
            v1[p].unpause();
            uint16 index =
                managed.addPair(address(bases[p]), address(quotes[p]), oracles[p], MAX_AGE, MAX_DEVIATION_BPS);
            assertEq(index, p);
            assertEq(managed.pair(index).priceScale, v1[p].priceScale(), "price scale");
            managed.setMembers(index, 0, one, true);
            managed.setPairAccess(index, IManagedDirectPropAMM.AccessMode.Listed);
            _fund(bases[p], address(v1[p]), 50_000);
            _fund(quotes[p], address(v1[p]), 50_000);
        }
        managed.unpause();
    }

    /// @dev `withdraw`, pair by pair, against v1's on its paused pool (`DirectPropAMM` withdraws only while paused; the
    /// managed pool withdraws paused or not, so it stays active), with both pools holding the same of each token. An
    /// ordinary recipient, zero, the pool itself and an amount above the inventory get the same outcome, the same
    /// revert bytes, and move the same balances. A TIP-1022 virtual recipient is the one intended divergence, as in
    /// v2 `Venue`: `DirectPropAMM` resolves it and pays its master; the managed pool reverts `VirtualRecipient` and
    /// moves nothing, though the token would forward the transfer to the master.
    function test_withdrawMatchesV1ExceptAVirtualRecipient() external {
        address recipient = makeAddr("treasury");
        address master = makeAddr("bridgeMaster");
        address liquidation = VirtualAddress.make(0x0badf00d, 1);
        registry.setResolution(liquidation, master);
        for (uint256 p; p < PAIRS; ++p) {
            v1[p].pause();
            MockTIP20[2] memory tokens = [bases[p], quotes[p]];
            for (uint256 t; t < tokens.length; ++t) {
                MockTIP20 token = tokens[t];
                token.setResolver(registry);
                uint256 amount = 3 * 10 ** token.decimals();
                uint256 before = token.balanceOf(recipient);
                assertTrue(
                    _compareOwnerCalls(
                        address(v1[p]),
                        abi.encodeCall(DirectPropAMM.withdraw, (address(token), recipient, amount, bytes32("w"))),
                        abi.encodeCall(ManagedDirectPropAMM.withdraw, (address(token), recipient, amount, bytes32("w")))
                    ),
                    "an ordinary recipient"
                );
                assertEq(token.balanceOf(recipient), before + 2 * amount, "each pool pays it exactly");
                assertEq(token.balanceOf(address(v1[p])), token.balanceOf(address(managed)), "the same inventory left");
                assertFalse(
                    _compareOwnerCalls(
                        address(v1[p]),
                        abi.encodeCall(DirectPropAMM.withdraw, (address(token), address(0), amount, bytes32(0))),
                        abi.encodeCall(ManagedDirectPropAMM.withdraw, (address(token), address(0), amount, bytes32(0)))
                    ),
                    "zero"
                );
                assertFalse(
                    _compareOwnerCalls(
                        address(v1[p]),
                        abi.encodeCall(DirectPropAMM.withdraw, (address(token), address(v1[p]), amount, bytes32(0))),
                        abi.encodeCall(
                            ManagedDirectPropAMM.withdraw, (address(token), address(managed), amount, bytes32(0))
                        )
                    ),
                    "the pool itself"
                );
                uint256 tooMuch = token.balanceOf(address(managed)) + 1;
                assertFalse(
                    _compareOwnerCalls(
                        address(v1[p]),
                        abi.encodeCall(DirectPropAMM.withdraw, (address(token), recipient, tooMuch, bytes32(0))),
                        abi.encodeCall(ManagedDirectPropAMM.withdraw, (address(token), recipient, tooMuch, bytes32(0)))
                    ),
                    "above the inventory"
                );

                // The intended divergence.
                uint256 masterBefore = token.balanceOf(master);
                v1[p].withdraw(address(token), liquidation, amount, bytes32("w"));
                assertEq(token.balanceOf(master), masterBefore + amount, "v1 resolves it and pays its master");
                uint256 managedBefore = token.balanceOf(address(managed));
                vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, liquidation));
                managed.withdraw(address(token), liquidation, amount, bytes32("w"));
                assertEq(token.balanceOf(address(managed)), managedBefore, "the managed pool moves nothing");
                assertEq(token.balanceOf(master), masterBefore + amount, "only v1 paid the master");
                assertEq(token.balanceOf(liquidation), 0, "the virtual address holds nothing");
            }
        }
    }

    /// @dev Random swaps on random pairs, both directions, exact in and exact out, with random oracle moves around the
    /// deviation limit, tolerances and expected prices, and amounts that reach past the inventory.
    /// forge-config: coverage.fuzz.runs = 128
    function testFuzz_pairByPairMatchesV1(
        uint8[STEPS] memory pairSeed,
        bool[STEPS] memory baseToQuote,
        bool[STEPS] memory exactInput,
        uint256[STEPS] memory amounts,
        int16[STEPS] memory moves,
        uint8[STEPS] memory toleranceSeed
    ) public {
        for (uint256 k; k < STEPS; ++k) {
            _step(pairSeed[k] % PAIRS, baseToQuote[k], exactInput[k], amounts[k], moves[k], toleranceSeed[k]);
            now_ += 1;
            vm.warp(now_);
        }
    }

    function _step(uint256 p, bool baseToQuote, bool exactInput, uint256 amountSeed, int16 move, uint8 toleranceSeed)
        internal
    {
        int256 basePrice = int256(basePrices[p]);
        uint256 price = uint256(basePrice + basePrice * bound(int256(move), -60, 60) / 10_000);
        oracles[p].setPrice(price, now_);
        MockTIP20 tokenIn = baseToQuote == exactInput ? bases[p] : quotes[p];
        uint256 amount = bound(amountSeed, 0, 80_000 * 10 ** tokenIn.decimals());
        uint256 tolerance = toleranceSeed % 3 == 0 ? 0 : toleranceSeed % 3 == 1 ? 5 : 20_000;
        uint256 expected = toleranceSeed % 2 == 0 ? price : basePrices[p];
        _compareSwap(p, baseToQuote, exactInput, amount, expected, tolerance);
    }

    /// @dev A fixed mix that must produce both fills and reverts, so the differential isn't vacuous.
    function test_deterministicMix() external {
        for (uint256 r; r < 40; ++r) {
            uint8[STEPS] memory ps;
            bool[STEPS] memory b2q;
            bool[STEPS] memory ex;
            uint256[STEPS] memory am;
            int16[STEPS] memory mv;
            uint8[STEPS] memory ts;
            for (uint256 k; k < STEPS; ++k) {
                uint256 h = uint256(keccak256(abi.encode(r, k)));
                // forge-lint: disable-start(unsafe-typecast)
                ps[k] = uint8(h);
                b2q[k] = (h >> 8) & 1 == 1;
                ex[k] = (h >> 9) & 1 == 1;
                am[k] = (h >> 16) % (30_000 * 10 ** 18);
                mv[k] = int16(int256((h >> 128) % 81) - 40);
                ts[k] = uint8(h >> 200) & 0xfe;
                // forge-lint: disable-end(unsafe-typecast)
            }
            testFuzz_pairByPairMatchesV1(ps, b2q, ex, am, mv, ts);
        }
        assertGt(fills, 60, "fills");
        assertGt(reverts, 20, "reverts");
    }

    /// @dev The quote views match v1's on every pair, `quote*For` against the same route's credit.
    /// forge-config: coverage.fuzz.runs = 128
    function testFuzz_quotesMatchV1(uint8 pairSeed, bool baseToQuote, uint256 amount, int16 move) external {
        uint256 p = pairSeed % PAIRS;
        int256 basePrice = int256(basePrices[p]);
        oracles[p].setPrice(uint256(basePrice + basePrice * bound(int256(move), -60, 60) / 10_000), now_);
        amount = bound(amount, 0, 1e30);
        uint16 index = uint16(p);
        _compareCall(
            address(v1[p]),
            abi.encodeCall(DirectPropAMM.quoteExactInput, (baseToQuote, amount)),
            abi.encodeCall(ManagedDirectPropAMM.quoteExactInput, (index, taker, baseToQuote, amount))
        );
        _compareCall(
            address(v1[p]),
            abi.encodeCall(DirectPropAMM.quoteExactOutput, (baseToQuote, amount)),
            abi.encodeCall(ManagedDirectPropAMM.quoteExactOutput, (index, taker, baseToQuote, amount))
        );
        _compareCall(
            address(v1[p]),
            abi.encodeCall(DirectPropAMM.quoteExactInputFor, (taker, taker, CUSTOMER, baseToQuote, amount)),
            abi.encodeCall(ManagedDirectPropAMM.quoteExactInputFor, (index, taker, CUSTOMER, baseToQuote, amount))
        );
        _compareCall(
            address(v1[p]),
            abi.encodeCall(DirectPropAMM.quoteExactOutputFor, (taker, taker, CUSTOMER, baseToQuote, amount)),
            abi.encodeCall(ManagedDirectPropAMM.quoteExactOutputFor, (index, taker, CUSTOMER, baseToQuote, amount))
        );
    }

    /// @dev Two pairs sharing a quote token, each against its own v1 pool, with inventory no swap can exhaust: the
    /// shared balance changes no price, anchor or credit.
    /// forge-config: coverage.fuzz.runs = 128
    function testFuzz_sharedTokensChangeNoPrice(
        bool[STEPS] memory onSecond,
        bool[STEPS] memory baseToQuote,
        bool[STEPS] memory exactInput,
        uint256[STEPS] memory amounts
    ) external {
        MockTIP20 shared = new MockTIP20("SHARED", 6);
        MockTIP20[2] memory sharedBases = [new MockTIP20("A", 6), new MockTIP20("B", 18)];
        MockOracle[2] memory sharedOracles = [new MockOracle(8, 99_000_000, now_), new MockOracle(8, 201_000_000, now_)];
        ManagedDirectPropAMM pool = new ManagedDirectPropAMM(address(this), address(0));
        DirectPropAMM[2] memory refs;
        address[] memory one = new address[](1);
        one[0] = taker;
        for (uint256 p; p < 2; ++p) {
            refs[p] = new DirectPropAMM(
                sharedBases[p], shared, sharedOracles[p], registry, address(this), address(this), MAX_AGE, 50
            );
            refs[p].setTakerAllowed(taker, true);
            refs[p].setRecipientAllowed(taker, true);
            refs[p].unpause();
            pool.addPair(address(sharedBases[p]), address(shared), sharedOracles[p], MAX_AGE, 50);
            pool.setMembers(uint16(p), 0, one, true);
            pool.setPairAccess(uint16(p), IManagedDirectPropAMM.AccessMode.Listed);
            _fundPool(sharedBases[p], address(refs[p]), address(pool), 1e9);
            _fundPool(shared, address(refs[p]), address(pool), 1e9);
        }
        pool.unpause();
        for (uint256 k; k < STEPS; ++k) {
            uint256 p = onSecond[k] ? 1 : 0;
            MockTIP20 tokenIn = baseToQuote[k] == exactInput[k] ? sharedBases[p] : shared;
            uint256 amount = bound(amounts[k], 1, 1_000_000 * 10 ** tokenIn.decimals());
            (uint256 price,) = sharedOracles[p].latestPrice();
            bytes memory a = _v1Call(baseToQuote[k], exactInput[k], amount, price, 0);
            bytes memory b = _managedCall(uint16(p), baseToQuote[k], exactInput[k], amount, price, 0);
            vm.prank(taker);
            (bool okA, bytes memory retA) = address(refs[p]).call(a);
            vm.prank(taker);
            (bool okB, bytes memory retB) = address(pool).call(b);
            assertEq(okA, okB, "success");
            assertEq(retA, retB, "return or revert bytes");
            assertEq(refs[p].priceAnchor(true), pool.priceAnchor(uint16(p), true));
            assertEq(refs[p].priceAnchor(false), pool.priceAnchor(uint16(p), false));
            assertEq(
                refs[p].roundingCredit(refs[p].roundingRouteKey(taker, taker, CUSTOMER)),
                pool.roundingCredit(pool.roundingRouteKey(uint16(p), taker, CUSTOMER))
            );
        }
    }

    /// @dev The swap limits, at and one unit either side of what the swap pays or costs: both pools fill or revert
    /// `SlippageExceeded` alike, with the same route credits.
    /// forge-config: coverage.fuzz.runs = 128
    function testFuzz_slippageLimitsMatchV1(
        uint8 pairSeed,
        bool baseToQuote,
        bool exactInput,
        uint256 amount,
        uint8 slack
    ) external {
        uint256 p = pairSeed % PAIRS;
        uint16 index = uint16(p);
        MockTIP20 unitToken = baseToQuote == exactInput ? bases[p] : quotes[p];
        amount = bound(amount, 1, 10_000 * 10 ** unitToken.decimals());
        (uint256 price,) = oracles[p].latestPrice();
        (bool quoted, bytes memory ret) = address(v1[p])
            .staticcall(
                exactInput
                    ? abi.encodeCall(DirectPropAMM.quoteExactInputFor, (taker, taker, CUSTOMER, baseToQuote, amount))
                    : abi.encodeCall(DirectPropAMM.quoteExactOutputFor, (taker, taker, CUSTOMER, baseToQuote, amount))
            );
        if (!quoted) return;
        (uint256 result,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        // The limit: one unit tighter than the result, the result itself, or one unit looser.
        int256 offset = int256(uint256(slack % 3)) - 1;
        uint256 limit = exactInput
            ? uint256(int256(result) - offset)
            : (result == 0 && offset < 0 ? 0 : uint256(int256(result) + offset));
        bytes memory a = exactInput
            ? abi.encodeCall(
                DirectPropAMM.swapExactInput, (baseToQuote, amount, limit, taker, CUSTOMER, "t", now_, price, 0, now_)
            )
            : abi.encodeCall(
                DirectPropAMM.swapExactOutput, (baseToQuote, amount, limit, taker, CUSTOMER, "t", now_, price, 0, now_)
            );
        bytes memory b = exactInput
            ? abi.encodeCall(
                ManagedDirectPropAMM.swapExactInput,
                (index, baseToQuote, amount, limit, 0, CUSTOMER, "t", now_, price, 0, now_)
            )
            : abi.encodeCall(
                ManagedDirectPropAMM.swapExactOutput,
                (index, baseToQuote, amount, limit, 0, CUSTOMER, "t", now_, price, 0, now_)
            );
        vm.prank(taker);
        (bool okA, bytes memory retA) = address(v1[p]).call(a);
        vm.prank(taker);
        (bool okB, bytes memory retB) = address(managed).call(b);
        assertEq(okA, okB, "success");
        assertEq(retA, retB, "return or revert bytes");
        assertEq(
            v1[p].roundingCredit(v1[p].roundingRouteKey(taker, taker, CUSTOMER)),
            managed.roundingCredit(managed.roundingRouteKey(index, taker, CUSTOMER)),
            "credit"
        );
    }

    /// @dev A pair's `Closed` is v1's pause. From the same oracle state, anchors and deviation limit, closing a pair and
    /// reopening it (`setPairAccess(Listed)`) reverts with the same bytes as `pause` then `unpause` on the pair's v1
    /// pool, or succeeds leaving the same anchors, and `resetPriceAnchor` on the closed pair matches v1's on the paused
    /// pool. A swap afterwards still matches.
    /// forge-config: coverage.fuzz.runs = 128
    function testFuzz_reopeningMatchesV1Unpause(
        uint8 pairSeed,
        uint8 kind,
        int16 move,
        uint8 resetMask,
        uint16 newBps,
        uint256 amount
    ) external {
        uint256 p = pairSeed % PAIRS;
        uint16 index = uint16(p);
        v1[p].pause();
        managed.closePair(index);
        uint256 bps = bound(uint256(newBps), 0, 200);
        _compareOwnerCalls(
            address(v1[p]),
            abi.encodeCall(DirectPropAMM.setMaxPriceDeviationBps, (bps)),
            abi.encodeCall(ManagedDirectPropAMM.setMaxPriceDeviationBps, (index, bps))
        );
        int256 basePrice = int256(basePrices[p]);
        uint256 moved = uint256(basePrice + basePrice * bound(int256(move), -300, 300) / 10_000);
        kind %= 5;
        if (kind == 0) oracles[p].setPrice(moved, now_);
        else if (kind == 1) oracles[p].setPrice(moved, now_ - MAX_AGE - 1);
        else if (kind == 2) oracles[p].setPrice(0, now_);
        else if (kind == 3) oracles[p].setPrice(moved, now_ + 1);
        else oracles[p].setPrice(moved, 0);
        for (uint256 d; d < 2; ++d) {
            if ((resetMask >> d) & 1 == 0) continue;
            _compareOwnerCalls(
                address(v1[p]),
                abi.encodeCall(DirectPropAMM.resetPriceAnchor, (d == 0)),
                abi.encodeCall(ManagedDirectPropAMM.resetPriceAnchor, (index, d == 0))
            );
        }
        bool reopened = _compareOwnerCalls(
            address(v1[p]),
            abi.encodeCall(DirectPropAMM.unpause, ()),
            abi.encodeCall(ManagedDirectPropAMM.setPairAccess, (index, IManagedDirectPropAMM.AccessMode.Listed))
        );
        assertEq(v1[p].paused(), !reopened, "v1 pause state");
        assertEq(
            uint8(managed.pair(index).access),
            uint8(reopened ? IManagedDirectPropAMM.AccessMode.Listed : IManagedDirectPropAMM.AccessMode.Closed),
            "the pair's mode"
        );
        assertEq(v1[p].priceAnchor(true), managed.priceAnchor(index, true), "anchor b2q");
        assertEq(v1[p].priceAnchor(false), managed.priceAnchor(index, false), "anchor q2b");
        if (!reopened) return;
        (uint256 price,) = oracles[p].latestPrice();
        MockTIP20 tokenIn = bases[p];
        _compareSwap(p, true, true, bound(amount, 1, 10_000 * 10 ** tokenIn.decimals()), price, 0);
    }

    /// @dev The access mapping, pair by pair: for each swap, `DirectPropAMM` lists its caller as a taker and a
    /// recipient exactly when the managed pool's `takerAccess` admits the caller on the pair under the swap's sponsor
    /// id. The managed state is fuzzed: the home lists (`homeMasks[p]`, bit `i` for party `i`), sponsor `ALPHA`'s lists
    /// (`alphaMasks[p]`), its admission per pair (`admittedMask`), its switch, a reset that voids its lists, denials
    /// (`deniedMask`) and `Open` or `Closed` pairs instead of `Listed` (`modeSeeds[p]`). Each swap names the home list,
    /// `ALPHA` or an unregistered id. Both pools must then return or revert
    /// with the same bytes, a managed refusal read as `DirectPropAMM`'s `TakerNotAllowed(caller)` after it is checked
    /// against `takerAccess` (see `_normalizeRevert`), and move every party's and pool's balances alike.
    /// forge-config: coverage.fuzz.runs = 128
    function testFuzz_accessMatchesV1Listing(
        uint8[3] memory homeMasks,
        uint8[3] memory alphaMasks,
        uint8 admittedMask,
        uint8 deniedMask,
        uint8[3] memory modeSeeds,
        uint8 flags,
        uint256[STEPS] memory swapSeeds
    ) external {
        _setUpAccess(homeMasks, alphaMasks, admittedMask, deniedMask, modeSeeds, flags);
        for (uint256 k; k < STEPS; ++k) {
            uint256 r = swapSeeds[k];
            uint256 p = r % PAIRS;
            address from = parties[(r >> 8) % parties.length];
            uint64 sponsorId = [uint64(0), ALPHA, 0, ALPHA, UNREGISTERED][(r >> 16) % 5];
            bool baseToQuote = (r >> 24) & 1 == 1;
            bool exactInput = (r >> 25) & 1 == 1;
            MockTIP20 tokenIn = baseToQuote == exactInput ? bases[p] : quotes[p];
            uint256 amount = bound(r >> 32, 1, 20_000 * 10 ** tokenIn.decimals());
            int256 basePrice = int256(basePrices[p]);
            oracles[p].setPrice(
                uint256(basePrice + basePrice * int256(uint256((r >> 128) % 81)) / 10_000 - basePrice * 40 / 10_000),
                now_
            );
            IManagedDirectPropAMM.TakerAccess access = managed.takerAccess(uint16(p), from, sponsorId);
            bool admitted = access == IManagedDirectPropAMM.TakerAccess.Allowed;
            v1[p].setTakerAllowed(from, admitted);
            v1[p].setRecipientAllowed(from, admitted);
            (uint256 price,) = oracles[p].latestPrice();
            _compareSwapAs(from, p, sponsorId, baseToQuote, exactInput, amount, price, access);
            now_ += 1;
            vm.warp(now_);
        }
    }

    /// @dev A fixed mix of access states for `testFuzz_accessMatchesV1Listing` that must reach fills and every
    /// refusal reason.
    function test_accessMixReachesEveryReason() external {
        // Storage counters are reset by each run's revert, so the totals are kept here.
        uint256[9] memory totals;
        uint256 filledTotal;
        for (uint256 r; r < 48; ++r) {
            uint256 snapshot = vm.snapshotState();
            uint256 h = uint256(keccak256(abi.encode("access", r)));
            uint256[STEPS] memory seeds;
            for (uint256 k; k < STEPS; ++k) {
                seeds[k] = uint256(keccak256(abi.encode(h, k)));
            }
            // forge-lint: disable-start(unsafe-typecast)
            this.testFuzz_accessMatchesV1Listing(
                [uint8(h), uint8(h >> 8), uint8(h >> 16)],
                [uint8(h >> 24), uint8(h >> 32), uint8(h >> 40)],
                uint8(h >> 48),
                uint8(h >> 56) & uint8(h >> 64),
                [uint8(h >> 72), uint8(h >> 80), uint8(h >> 88)],
                uint8(h >> 96),
                seeds
            );
            // forge-lint: disable-end(unsafe-typecast)
            uint256[9] memory seen = _reasonsSeen;
            uint256 filled = fills;
            vm.revertToState(snapshot);
            for (uint256 a; a < 9; ++a) {
                totals[a] += seen[a];
            }
            filledTotal += filled;
        }
        emit log_named_uint("fills", filledTotal);
        assertGt(filledTotal, 40, "fills");
        for (uint256 a = 3; a < 9; ++a) {
            emit log_named_uint(string.concat("refused swaps with takerAccess ", vm.toString(a)), totals[a]);
            assertGt(totals[a], 0, "a refusal reason no swap met");
        }
    }

    /// @dev Refusals by `TakerAccess` value in the current run.
    uint256[9] internal _reasonsSeen;

    /// @dev Applies `testFuzz_accessMatchesV1Listing`'s managed access state. `DirectPropAMM`'s lists are set per swap.
    function _setUpAccess(
        uint8[3] memory homeMasks,
        uint8[3] memory alphaMasks,
        uint8 admittedMask,
        uint8 deniedMask,
        uint8[3] memory modeSeeds,
        uint8 flags
    ) internal {
        managed.addSponsor(ALPHA, alpha);
        for (uint16 p; p < PAIRS; ++p) {
            managed.setPairSponsor(p, ALPHA, true);
            for (uint256 i; i < parties.length; ++i) {
                address[] memory one = new address[](1);
                one[0] = parties[i];
                managed.setMembers(p, 0, one, (homeMasks[p] >> i) & 1 == 1);
                vm.prank(alpha);
                managed.setMembers(p, ALPHA, one, (alphaMasks[p] >> i) & 1 == 1);
            }
            if ((admittedMask >> p) & 1 == 0) managed.setPairSponsor(p, ALPHA, false);
            // 0-3: Listed; 4: Open; 5: Closed.
            uint8 mode = modeSeeds[p] % 6;
            if (mode == 4) {
                managed.pause();
                managed.setPairAccess(p, IManagedDirectPropAMM.AccessMode.Open);
                managed.unpause();
            } else if (mode == 5) {
                managed.closePair(p);
            }
        }
        if (flags & 1 == 1) managed.setSponsorEnabled(ALPHA, false);
        if ((flags >> 1) & 3 == 0) managed.resetSponsor(ALPHA, alpha);
        address[] memory denied = new address[](0);
        for (uint256 i; i < parties.length; ++i) {
            if ((deniedMask >> i) & 1 == 0) continue;
            denied = new address[](1);
            denied[0] = parties[i];
            managed.setDenied(denied, true);
        }
    }

    /// @dev `_compareSwap` from `from`: both pools, the same call (`DirectPropAMM` paying `from`), the same result or
    /// the same revert once normalized, the same balance change for every party and pool, and the same anchors and
    /// credits.
    function _compareSwapAs(
        address from,
        uint256 p,
        uint64 sponsorId,
        bool baseToQuote,
        bool exactInput,
        uint256 amount,
        uint256 price,
        IManagedDirectPropAMM.TakerAccess access
    ) internal {
        bytes memory a = exactInput
            ? abi.encodeCall(
                DirectPropAMM.swapExactInput, (baseToQuote, amount, 0, from, CUSTOMER, "t", now_, price, 0, now_)
            )
            : abi.encodeCall(
                DirectPropAMM.swapExactOutput,
                (baseToQuote, amount, type(uint256).max, from, CUSTOMER, "t", now_, price, 0, now_)
            );
        bytes memory b = exactInput
            ? abi.encodeCall(
                ManagedDirectPropAMM.swapExactInput,
                (uint16(p), baseToQuote, amount, 0, sponsorId, CUSTOMER, "t", now_, price, 0, now_)
            )
            : abi.encodeCall(
                ManagedDirectPropAMM.swapExactOutput,
                (uint16(p), baseToQuote, amount, type(uint256).max, sponsorId, CUSTOMER, "t", now_, price, 0, now_)
            );
        int256[10] memory before = _allBalances(p);
        vm.prank(from);
        (bool okA, bytes memory retA) = address(v1[p]).call(a);
        int256[10] memory midway = _allBalances(p);
        vm.prank(from);
        (bool okB, bytes memory retB) = address(managed).call(b);
        int256[10] memory afterB = _allBalances(p);
        assertEq(okA, okB, "success");
        if (okA) assertEq(retA, retB, "return");
        else assertEq(retA, _normalizeRevert(retB, from, uint16(p), sponsorId, access), "revert");
        // Each party's two balances, then each pool's: v1 [6..7], managed [8..9].
        for (uint256 i; i < 6; ++i) {
            assertEq(midway[i] - before[i], afterB[i] - midway[i], "a party's balance moved differently");
        }
        assertEq(midway[6] - before[6], afterB[8] - midway[8], "base pool delta");
        assertEq(midway[7] - before[7], afterB[9] - midway[9], "quote pool delta");
        assertEq(v1[p].priceAnchor(true), managed.priceAnchor(uint16(p), true), "anchor b2q");
        assertEq(v1[p].priceAnchor(false), managed.priceAnchor(uint16(p), false), "anchor q2b");
        assertEq(
            v1[p].roundingCredit(v1[p].roundingRouteKey(from, from, CUSTOMER)),
            managed.roundingCredit(managed.roundingRouteKey(uint16(p), from, CUSTOMER)),
            "credit"
        );
        if (okA) ++fills;
        else if (access != IManagedDirectPropAMM.TakerAccess.Allowed) ++_reasonsSeen[uint8(access)];
    }

    /// @dev Reads a managed revert as `DirectPropAMM` gives it once it unlists the caller. A refusal `DirectPropAMM`
    /// has no error for (a denial, an unknown, switched-off or unadmitted sponsor) is read as
    /// `TakerNotAllowed(from)`, after checking it is the error for the reason `takerAccess` gave; `Closed` and
    /// `NotListed` already revert `TakerNotAllowed`. Anything else, a pricing or settlement revert, must match as is.
    function _normalizeRevert(
        bytes memory ret,
        address from,
        uint16 p,
        uint64 sponsorId,
        IManagedDirectPropAMM.TakerAccess access
    ) internal view returns (bytes memory) {
        bytes memory notAllowed = abi.encodeWithSelector(DirectPropAMM.TakerNotAllowed.selector, from);
        if (access == IManagedDirectPropAMM.TakerAccess.Allowed) return ret;
        bytes memory reason;
        if (access == IManagedDirectPropAMM.TakerAccess.Denied) {
            reason = abi.encodeWithSelector(IManagedDirectPropAMM.TakerDenied.selector, from);
        } else if (access == IManagedDirectPropAMM.TakerAccess.UnknownSponsor) {
            reason = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, sponsorId);
        } else if (access == IManagedDirectPropAMM.TakerAccess.SponsorDisabled) {
            reason = abi.encodeWithSelector(IManagedDirectPropAMM.SponsorDisabled.selector, sponsorId);
        } else if (access == IManagedDirectPropAMM.TakerAccess.SponsorNotAdmitted) {
            reason = abi.encodeWithSelector(IManagedDirectPropAMM.SponsorNotAdmitted.selector, p, sponsorId);
        } else {
            reason = notAllowed;
        }
        assertEq(ret, reason, "the managed refusal isn't takerAccess's reason");
        return notAllowed;
    }

    /// @dev Every party's base and quote balance for pair `p` ([2i], [2i + 1]), then the v1 pool's and the managed
    /// pool's ([6..9]).
    function _allBalances(uint256 p) internal view returns (int256[10] memory b) {
        for (uint256 i; i < parties.length; ++i) {
            b[2 * i] = int256(bases[p].balanceOf(parties[i]));
            b[2 * i + 1] = int256(quotes[p].balanceOf(parties[i]));
        }
        b[6] = int256(bases[p].balanceOf(address(v1[p])));
        b[7] = int256(quotes[p].balanceOf(address(v1[p])));
        b[8] = int256(bases[p].balanceOf(address(managed)));
        b[9] = int256(quotes[p].balanceOf(address(managed)));
    }

    // ---------------------------------------------------------------- helpers

    function _compareSwap(
        uint256 p,
        bool baseToQuote,
        bool exactInput,
        uint256 amount,
        uint256 expected,
        uint256 tolerance
    ) internal {
        bytes memory a = _v1Call(baseToQuote, exactInput, amount, expected, tolerance);
        bytes memory b = _managedCall(uint16(p), baseToQuote, exactInput, amount, expected, tolerance);
        int256[4] memory before = _balances(p);
        vm.prank(taker);
        (bool okA, bytes memory retA) = address(v1[p]).call(a);
        int256[4] memory midway = _balances(p);
        vm.prank(taker);
        (bool okB, bytes memory retB) = address(managed).call(b);
        int256[4] memory afterB = _balances(p);
        assertEq(okA, okB, "success");
        assertEq(retA, retB, "return or revert bytes");
        assertEq(midway[0] - before[0], afterB[2] - midway[2], "base pool delta");
        assertEq(midway[1] - before[1], afterB[3] - midway[3], "quote pool delta");
        assertEq(v1[p].priceAnchor(true), managed.priceAnchor(uint16(p), true), "anchor b2q");
        assertEq(v1[p].priceAnchor(false), managed.priceAnchor(uint16(p), false), "anchor q2b");
        assertEq(
            v1[p].roundingCredit(v1[p].roundingRouteKey(taker, taker, CUSTOMER)),
            managed.roundingCredit(managed.roundingRouteKey(uint16(p), taker, CUSTOMER)),
            "credit"
        );
        if (okA) ++fills;
        else ++reverts;
    }

    /// @dev Runs an owner call on a v1 pool and its managed counterpart: the same success, or the same revert bytes.
    function _compareOwnerCalls(address target, bytes memory a, bytes memory b) internal returns (bool okA) {
        bytes memory retA;
        (okA, retA) = target.call(a);
        (bool okB, bytes memory retB) = address(managed).call(b);
        assertEq(okA, okB, "owner call success");
        assertEq(retA, retB, "owner call return or revert bytes");
    }

    function _compareCall(address target, bytes memory a, bytes memory b) internal view {
        (bool okA, bytes memory retA) = target.staticcall(a);
        (bool okB, bytes memory retB) = address(managed).staticcall(b);
        assertEq(okA, okB, "success");
        assertEq(retA, retB, "return or revert bytes");
    }

    function _v1Call(bool baseToQuote, bool exactInput, uint256 amount, uint256 expected, uint256 tolerance)
        internal
        view
        returns (bytes memory)
    {
        return exactInput
            ? abi.encodeCall(
                DirectPropAMM.swapExactInput,
                (baseToQuote, amount, 0, taker, CUSTOMER, "t", now_, expected, tolerance, now_)
            )
            : abi.encodeCall(
                DirectPropAMM.swapExactOutput,
                (baseToQuote, amount, type(uint256).max, taker, CUSTOMER, "t", now_, expected, tolerance, now_)
            );
    }

    function _managedCall(
        uint16 index,
        bool baseToQuote,
        bool exactInput,
        uint256 amount,
        uint256 expected,
        uint256 tolerance
    ) internal view returns (bytes memory) {
        return exactInput
            ? abi.encodeCall(
                ManagedDirectPropAMM.swapExactInput,
                (index, baseToQuote, amount, 0, 0, CUSTOMER, "t", now_, expected, tolerance, now_)
            )
            : abi.encodeCall(
                ManagedDirectPropAMM.swapExactOutput,
                (index, baseToQuote, amount, type(uint256).max, 0, CUSTOMER, "t", now_, expected, tolerance, now_)
            );
    }

    /// @dev [v1 pool base, v1 pool quote, managed base, managed quote] balances for pair `p`.
    function _balances(uint256 p) internal view returns (int256[4] memory b) {
        b[0] = int256(bases[p].balanceOf(address(v1[p])));
        b[1] = int256(quotes[p].balanceOf(address(v1[p])));
        b[2] = int256(bases[p].balanceOf(address(managed)));
        b[3] = int256(quotes[p].balanceOf(address(managed)));
    }

    /// @dev Gives the v1 pool and the managed pool `units` of `token` each, and the taker plenty, approved to both.
    function _fund(MockTIP20 token, address v1Pool, uint256 units) internal {
        _fundPool(token, v1Pool, address(managed), units);
    }

    function _fundPool(MockTIP20 token, address v1Pool, address managedPool, uint256 units) internal {
        uint256 unit = 10 ** token.decimals();
        token.mint(v1Pool, units * unit);
        token.mint(managedPool, units * unit);
        for (uint256 i; i < parties.length; ++i) {
            token.mint(parties[i], 100_000_000 * unit);
            vm.startPrank(parties[i]);
            token.approve(v1Pool, type(uint256).max);
            token.approve(managedPool, type(uint256).max);
            vm.stopPrank();
        }
    }
}

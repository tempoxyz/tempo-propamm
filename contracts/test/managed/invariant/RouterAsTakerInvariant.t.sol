// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestFeeHook, TestFeeHookLib } from "../utils/TestFeeHook.sol";
using TestFeeHookLib for ManagedDirectPropAMM;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { PoolFactory } from "../../../src/managed/PoolFactory.sol";
import { Settler } from "../../../src/managed/Settler.sol";
import { IManagedDirectPropAMM as IM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { ISettler } from "../../../src/managed/interfaces/ISettler.sol";
import { MockTIP20 } from "../../mocks/MockTIP20.sol";
import { MockOracle } from "../../mocks/MockOracle.sol";
import { AuthenticatedManagedTestRouter } from "../RouterAsTaker.t.sol";

/// @dev Local model, not a fork or evidence about a deployed router. Mock TIP20s have six decimals; oracle prices
/// are fixed and fresh. The independent model uses small bounded integer value products (not production Math or
/// quotes), including the fee ceiling and a credit per caller shared across directions and its execution entry points.
/// Four markets share both base and quote inventory: A: X/USD, X/Y, Y/USD; B: Y/USD. Each has three users,
/// three customer IDs and two authenticated routers. Ghost balances are never refreshed from successful fills.
contract RouterAsTakerHandler is Test {
    uint256 internal constant SCALE = 1e8;
    uint256 internal constant APPROVAL = 1e30;
    uint64 internal constant SPONSOR = 7;
    ManagedDirectPropAMM[2] public pools;
    TestFeeHook[4] public hooks;
    MockTIP20[3] public tokens;
    AuthenticatedManagedTestRouter[2] public routers;
    Settler public settler;
    address[3] public users;
    address[2] public owners;
    address internal sponsorAdmin;
    address[8] internal holders;
    uint256[3][8] internal balances;
    uint256[3] public total;
    uint256[3][5][4] internal credits;
    uint16[2][5][4] internal fees;
    IM.AccessMode[4] internal modes;
    bool[5][4] internal home;
    bool[5][4] internal sponsored;
    bool[4] internal admitted;
    bool[2] internal enabled;
    bool[5][2] internal denied;
    // Finite user approvals: token / user / spender (A, B, Settler, router0, router1).
    uint256[5][3][3] internal allowances;
    uint256 public successes;
    uint256 public refusals;
    uint256 public exactOutputs;
    uint256 public direct;
    uint256 public routerSettled;
    uint256 public policyRollbacks;
    uint256 public ownershipTransfers;
    uint256 public feeChanges;
    uint256 public creditOnlyOutputs;

    constructor() {
        vm.warp(1_000_000);
        PoolFactory f = new PoolFactory();
        settler = Settler(f.defaultSettler());
        tokens = [new MockTIP20("X", 6), new MockTIP20("USD", 6), new MockTIP20("Y", 6)];
        sponsorAdmin = makeAddr("invariant sponsor admin");
        owners = [makeAddr("invariant owner A"), makeAddr("invariant owner B")];
        users = [makeAddr("invariant alice"), makeAddr("invariant bob"), makeAddr("invariant carol")];
        pools[0] = ManagedDirectPropAMM(f.createPool(owners[0], bytes32("invariant A")));
        pools[1] = ManagedDirectPropAMM(f.createPool(owners[1], bytes32("invariant B")));
        routers[0] = new AuthenticatedManagedTestRouter(ISettler(address(settler)));
        routers[1] = new AuthenticatedManagedTestRouter(ISettler(address(settler)));
        for (uint256 m; m < 4; ++m) {
            uint256 p = _pool(m);
            MockOracle oracle = new MockOracle(8, _price(m), block.timestamp);
            vm.prank(owners[p]);
            pools[p].addPair(address(tokens[_base(m)]), address(tokens[_quote(m)]), oracle, 90_000, 50);
        }
        for (uint256 p; p < 2; ++p) {
            vm.startPrank(owners[p]);
            pools[p].addSponsor(SPONSOR, sponsorAdmin);
            enabled[p] = true;
            vm.stopPrank();
        }
        for (uint256 m; m < 4; ++m) {
            uint256 p = _pool(m);
            vm.startPrank(owners[p]);
            hooks[m] = new TestFeeHook(pools[p]);
            pools[p].setPairHook(_index(m), address(hooks[m]), 1);
            pools[p].setPairSponsor(_index(m), SPONSOR, true);
            admitted[m] = true;
            for (uint256 u; u < 3; ++u) {
                pools[p].setMembers(_index(m), 0, _one(users[u]), true);
                home[m][u] = true;
                fees[m][u][0] = uint16(u * 100);
                fees[m][u][1] = uint16((u + 1) * 100);
                hooks[m].setFees(_index(m), users[u], fees[m][u][0], fees[m][u][1]);
            }
            // Router rates and credits belong to the router, not its authenticated user.
            hooks[m].setFees(_index(m), address(routers[0]), 1000, 1000);
            hooks[m].setFees(_index(m), address(routers[1]), 1000, 1000);
            for (uint256 r; r < 2; ++r) {
                pools[p].setMembers(_index(m), 0, _one(address(routers[r])), true);
                home[m][r + 3] = true;
                fees[m][r + 3] = [uint16(1000), uint16(1000)];
            }
            pools[p].setPairAccess(_index(m), IM.AccessMode.Listed);
            modes[m] = IM.AccessMode.Listed;
            vm.stopPrank();
            vm.startPrank(sponsorAdmin);
            for (uint256 u; u < 3; ++u) {
                sponsored[m][u] = u != 2;
                pools[p].setMembers(_index(m), SPONSOR, _one(users[u]), u != 2);
            }
            for (uint256 r; r < 2; ++r) {
                pools[p].setMembers(_index(m), SPONSOR, _one(address(routers[r])), true);
                sponsored[m][r + 3] = true;
            }
            vm.stopPrank();
        }
        holders = [
            address(pools[0]),
            address(pools[1]),
            users[0],
            users[1],
            users[2],
            address(routers[0]),
            address(routers[1]),
            address(settler)
        ];
        for (uint256 h; h < 8; ++h) {
            for (uint256 t; t < 3; ++t) {
                uint256 amount = h < 5 ? 1e15 : 1000 + h * 10 + t;
                tokens[t].mint(holders[h], amount);
                balances[h][t] = amount;
                total[t] += amount;
            }
        }
        for (uint256 u; u < 3; ++u) {
            vm.startPrank(users[u]);
            for (uint256 t; t < 3; ++t) {
                for (uint256 s; s < 5; ++s) {
                    tokens[t].approve(_spender(s), APPROVAL);
                    allowances[t][u][s] = APPROVAL;
                }
            }
            vm.stopPrank();
        }
        for (uint256 p; p < 2; ++p) {
            vm.prank(owners[p]);
            pools[p].unpause();
        }
    }

    function _pool(uint256 m) internal pure returns (uint256) {
        return m == 3 ? 1 : 0;
    }

    function _index(uint256 m) internal pure returns (uint16) {
        return uint16(m == 3 ? 0 : m);
    }

    function _base(uint256 m) internal pure returns (uint256) {
        return m < 2 ? 0 : 2;
    }

    function _quote(uint256 m) internal pure returns (uint256) {
        return m == 1 ? 2 : 1;
    }

    function _price(uint256 m) internal pure returns (uint256) {
        return m == 0 ? 105_000_000 : (m == 1 ? 97_000_000 : 108_500_000);
    }

    function _customer(uint256 c) internal pure returns (bytes32) {
        return bytes32(c + 1);
    }

    function _spender(uint256 s) internal view returns (address) {
        if (s < 2) return address(pools[s]);
        return s == 2 ? address(settler) : address(routers[s - 3]);
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _ceil(uint256 n, uint256 d) internal pure returns (uint256) {
        return n == 0 ? 0 : (n - 1) / d + 1;
    }

    /// @dev One value-conservation equation, with no call into pool pricing libraries or quotes.
    function _model(uint256 m, uint256 u, uint256 c, bool dir, bool exactIn, uint256 amount)
        internal
        view
        returns (uint256 input, uint256 output, uint256 credit)
    {
        uint256 iv = dir ? _price(m) : SCALE;
        uint256 ov = dir ? SCALE : _price(m);
        uint256 f = fees[m][u][dir ? 0 : 1];
        uint256 old = credits[m][u][c];
        if (exactIn) {
            input = amount;
            uint256 value = (amount - _ceil(amount * f, 10_000)) * iv + old;
            output = value / ov;
            credit = value - output * ov;
        } else {
            output = amount;
            uint256 required = amount * ov;
            uint256 net = required > old ? _ceil(required - old, iv) : 0;
            input = _ceil(net * 10_000, 10_000 - f);
            credit = old + net * iv - required;
        }
    }

    function _access(uint256 m, uint256 u, uint64 sponsor) internal view returns (IM.TakerAccess) {
        if (modes[m] == IM.AccessMode.Closed) return IM.TakerAccess.Closed;
        if (denied[_pool(m)][u]) return IM.TakerAccess.Denied;
        if (modes[m] == IM.AccessMode.Open) return IM.TakerAccess.Allowed;
        if (sponsor == 0) return home[m][u] ? IM.TakerAccess.Allowed : IM.TakerAccess.NotListed;
        if (sponsor != SPONSOR) return IM.TakerAccess.UnknownSponsor;
        if (!enabled[_pool(m)]) return IM.TakerAccess.SponsorDisabled;
        if (!admitted[m]) return IM.TakerAccess.SponsorNotAdmitted;
        return sponsored[m][u] ? IM.TakerAccess.Allowed : IM.TakerAccess.NotListed;
    }

    function _allowed(uint256 m, uint256 u, uint64 sponsor, uint256 channel) internal view returns (bool) {
        return _access(m, u, sponsor) == IM.TakerAccess.Allowed
            && (channel < 2 || _access(m, channel + 1, sponsor) == IM.TakerAccess.Allowed);
    }

    function _params(uint256 m, uint256 c, bool dir, bool exactIn, uint256 amount, uint64 sponsor)
        internal
        view
        returns (IM.SwapParams memory)
    {
        return IM.SwapParams(
            _index(m),
            dir,
            exactIn,
            amount,
            exactIn ? 0 : type(uint256).max,
            sponsor,
            _customer(c),
            bytes32("invariant trade"),
            block.timestamp,
            _price(m),
            0,
            block.timestamp
        );
    }

    /// @dev Every quote is checked even when access/listing blocks the later fill. Customer, user, pair and channel
    /// vary independently; unrelated credits must continue to equal the untouched ghost entries.
    function trade(uint256 seed, uint256 amountSeed, bool dir, bool exactIn) public {
        uint256 m = seed % 4;
        uint256 u = (seed / 4) % 3;
        uint256 c = (seed / 12) % 3;
        uint256 channel = (seed / 36) % 4; // direct pool, ordinary Settler, router0, router1
        uint64 sponsor = (seed / 144) % 3 == 0 ? 0 : ((seed / 144) % 3 == 1 ? SPONSOR : 9);
        uint256 amount = 1 + amountSeed % 100_000_003;
        uint256 identity = channel < 2 ? u : channel + 1;
        address who = identity < 3 ? users[identity] : address(routers[identity - 3]);
        (uint256 input, uint256 output, uint256 credit) = _model(m, identity, c, dir, exactIn, amount);
        ManagedDirectPropAMM p = pools[_pool(m)];
        uint256 quoted;
        uint256 quotedCredit;
        if (exactIn) (quoted,,, quotedCredit) = p.quoteExactInputFor(_index(m), who, _customer(c), dir, amount);
        else (quoted,,, quotedCredit) = p.quoteExactOutputFor(_index(m), who, _customer(c), dir, amount);
        assertEq(quoted, exactIn ? output : input, "independent quote amount");
        assertEq(quotedCredit, credit, "independent quote credit");
        IM.SwapParams memory s = _params(m, c, dir, exactIn, amount, sponsor);
        // Deliberate final slippage failure after otherwise executable pricing.
        bool badLimit = (seed / 432) % 5 == 1;
        if (badLimit) s.limit = exactIn ? output + 1 : (input == 0 ? 0 : input - 1);
        bool expected =
            _allowed(m, u, sponsor, channel) && (!exactIn || output != 0) && (!badLimit || (!exactIn && input == 0));
        bytes32 beforeState = expected ? bytes32(0) : _digest();
        (bool ok, bytes memory data) = _execute(p, s, u, channel);
        assertEq(ok, expected, "fill success must match independent access/listing/slippage model");
        if (ok) {
            assertEq(abi.decode(data, (uint256)), exactIn ? output : input, "fill amount");
            _book(m, u, identity, c, dir, input, output, credit);
            allowances[dir ? _base(m) : _quote(m)][u][channel == 0 ? _pool(m) : channel + 1] -= input;
            ++successes;
            if (!exactIn) {
                ++exactOutputs;
                if (input == 0) ++creditOnlyOutputs;
            }
            if (channel == 0) ++direct;
            if (channel >= 2) ++routerSettled;
        } else {
            assertEq(_digest(), beforeState, "failed fill atomicity");
            ++refusals;
        }
    }

    function _execute(ManagedDirectPropAMM p, IM.SwapParams memory s, uint256 u, uint256 channel)
        internal
        returns (bool, bytes memory)
    {
        bytes memory data;
        address target;
        if (channel == 0) {
            target = address(p);
            data = abi.encodeWithSelector(
                s.exactInput ? IM.swapExactInput.selector : IM.swapExactOutput.selector,
                s.pairIndex,
                s.baseToQuote,
                s.amount,
                s.limit,
                s.sponsorId,
                s.customerId,
                s.tradeId,
                s.deadline,
                s.expectedOraclePrice,
                s.oraclePriceToleranceBps,
                s.minimumOracleUpdatedAt
            );
        } else if (channel == 1) {
            target = address(settler);
            data = abi.encodeCall(ISettler.swap, (address(p), s));
        } else {
            target = address(routers[channel - 2]);
            data = abi.encodeCall(AuthenticatedManagedTestRouter.swap, (address(p), s));
        }
        vm.prank(users[u]);
        return target.call(data);
    }

    function _book(
        uint256 m,
        uint256 u,
        uint256 identity,
        uint256 c,
        bool dir,
        uint256 input,
        uint256 output,
        uint256 credit
    ) internal {
        uint256 ti = dir ? _base(m) : _quote(m);
        uint256 to = dir ? _quote(m) : _base(m);
        balances[u + 2][ti] -= input;
        balances[u + 2][to] += output;
        balances[_pool(m)][ti] += input;
        balances[_pool(m)][to] -= output;
        credits[m][identity][c] = credit;
    }

    function routerListing(uint256 seed, bool listed) public {
        uint256 p = seed % 2;
        uint256 r = seed / 2 % 2;
        uint256 role = seed / 4 % 3;
        address caller = role == 0 ? owners[p] : (role == 1 ? sponsorAdmin : users[2]);
        for (uint256 m; m < 4; ++m) {
            if (_pool(m) != p) continue;
            bytes32 beforeState = _digest();
            vm.prank(caller);
            (bool ok,) = address(pools[p])
                .call(abi.encodeCall(IM.setMembers, (_index(m), uint64(0), _one(address(routers[r])), listed)));
            assertEq(ok, role == 0, "only current owner edits router home listing");
            if (ok) home[m][r + 3] = listed;
            else assertEq(_digest(), beforeState, "unauthorized listing atomicity");
        }
    }

    function access(uint256 seed, bool value) public {
        uint256 m = seed % 4;
        uint256 p = _pool(m);
        uint256 u = seed / 4 % 3;
        uint256 action = seed / 12 % 7;
        if (action == 0) {
            _mode(m, IM.AccessMode(uint8(1 + seed / 84 % 3)));
        } else if (action == 1) {
            vm.prank(owners[p]);
            pools[p].setMembers(_index(m), 0, _one(users[u]), value);
            home[m][u] = value;
        } else if (action == 2) {
            bool expected = !value || (enabled[p] && admitted[m]);
            bytes32 beforeState = expected ? bytes32(0) : _digest();
            vm.prank(sponsorAdmin);
            (bool ok,) =
                address(pools[p]).call(abi.encodeCall(IM.setMembers, (_index(m), SPONSOR, _one(users[u]), value)));
            assertEq(ok, expected, "sponsor may only list while enabled and admitted");
            if (ok) sponsored[m][u] = value;
            else assertEq(_digest(), beforeState, "refused sponsor listing atomicity");
        } else if (action == 3) {
            vm.prank(owners[p]);
            pools[p].setSponsorEnabled(SPONSOR, value);
            enabled[p] = value;
        } else if (action == 4) {
            vm.prank(owners[p]);
            pools[p].setPairSponsor(_index(m), SPONSOR, value);
            admitted[m] = value;
        } else if (action == 5) {
            uint256 identity = seed / 84 % 5;
            address account = identity < 3 ? users[identity] : address(routers[identity - 3]);
            vm.prank(owners[p]);
            pools[p].setDenied(_one(account), value);
            denied[p][identity] = value;
        } else {
            vm.prank(owners[p]);
            pools[p].closePair(_index(m));
            modes[m] = IM.AccessMode.Closed;
        }
    }

    function _mode(uint256 m, IM.AccessMode mode) internal {
        uint256 p = _pool(m);
        vm.startPrank(owners[p]);
        if (mode == IM.AccessMode.Open) pools[p].pause();
        pools[p].setPairAccess(_index(m), mode);
        if (mode == IM.AccessMode.Open) pools[p].unpause();
        vm.stopPrank();
        modes[m] = mode;
    }

    function changeFees(uint256 seed) public {
        uint256 m = seed % 4;
        uint256 p = _pool(m);
        uint256 u = seed / 4 % 3;
        uint16[4] memory rates = [uint16(0), 1, 100, 1000];
        uint16 sell = rates[seed / 12 % 4];
        uint16 buy = rates[seed / 48 % 4];
        vm.prank(owners[p]);
        hooks[m].setFees(_index(m), users[u], sell, buy);
        fees[m][u][0] = sell;
        fees[m][u][1] = buy;
        ++feeChanges;
    }

    function transferOwner(uint256 seed) public {
        uint256 p = seed % 2;
        address old = owners[p];
        address next =
            old == address(this) ? (p == 0 ? makeAddr("replacement A") : makeAddr("replacement B")) : address(this);
        vm.prank(old);
        pools[p].transferOwnership(next);
        vm.prank(next);
        (bool pendingCanGrant,) = address(pools[p])
            .call(abi.encodeCall(IM.setMembers, (uint16(0), uint64(0), _one(address(routers[0])), true)));
        assertFalse(pendingCanGrant, "pending owner is not owner");
        vm.prank(next);
        pools[p].acceptOwnership();
        owners[p] = next;
        vm.prank(old);
        (bool formerCanGrant,) = address(pools[p])
            .call(abi.encodeCall(IM.setMembers, (uint16(0), uint64(0), _one(address(routers[0])), true)));
        assertFalse(formerCanGrant, "former owner lost authority");
        ++ownershipTransfers;
    }

    /// @dev Find an exact-output overpayment that funds the next one-unit output entirely from credit.
    /// The second execution crosses from direct to Settler and raises the caller fee to 1000 bps: neither
    /// changing the execution channel nor the rate may erase credit or charge a fee on nonexistent fresh input.
    function creditOnlyExercise() public {
        _repair(0);
        changeFees(0);
        bool found;
        for (uint256 amount = 1; amount <= 21; ++amount) {
            (,, uint256 credit) = _model(0, 0, 0, true, false, amount);
            if (credit >= SCALE) {
                trade(0, amount - 1, true, false);
                found = true;
                break;
            }
        }
        assertTrue(found, "must create credit for a whole output unit");
        changeFees(180);
        uint256 beforeCount = creditOnlyOutputs;
        trade(36, 0, true, false);
        assertEq(creditOnlyOutputs, beforeCount + 1, "credit-only exact-output must succeed");
    }

    function _repair(uint256 m) internal {
        uint256 p = _pool(m);
        _mode(m, IM.AccessMode.Listed);
        vm.startPrank(owners[p]);
        pools[p].setMembers(_index(m), 0, _one(users[0]), true);
        home[m][0] = true;
        pools[p].setMembers(_index(m), 0, _one(address(routers[0])), true);
        home[m][3] = true;
        pools[p].setDenied(_one(users[0]), false);
        pools[p].setDenied(_one(address(routers[0])), false);
        denied[p][0] = false;
        denied[p][3] = false;
        vm.stopPrank();
    }

    /// @dev An authorized token callback narrows the same pool before settlement, then the refused fill
    /// must roll back balances, finite approvals, credits and the callback's policy mutation together.
    function atomicPolicyChange(bool close) public {
        _repair(0);
        address previousOwner = owners[0];
        vm.prank(previousOwner);
        pools[0].transferOwnership(address(tokens[0]));
        vm.prank(address(tokens[0]));
        pools[0].acceptOwnership();
        owners[0] = address(tokens[0]);
        tokens[0].setReentry(
            address(pools[0]),
            close
                ? abi.encodeCall(IM.closePair, (uint16(0)))
                : abi.encodeCall(IM.setDenied, (_one(address(routers[0])), true))
        );
        bytes32 beforeState = _digest();
        IM.SwapParams memory s = _params(0, 0, true, true, 101, 0);
        vm.prank(users[0]);
        (bool ok,) =
            address(routers[0]).call(abi.encodeCall(AuthenticatedManagedTestRouter.swap, (address(pools[0]), s)));
        assertFalse(ok, "callback narrowing must stop the single fill");
        assertEq(_digest(), beforeState, "refused fill rolls back owner policy mutation");
        tokens[0].setReentry(address(0), "");
        vm.prank(owners[0]);
        pools[0].transferOwnership(previousOwner);
        vm.prank(previousOwner);
        pools[0].acceptOwnership();
        owners[0] = previousOwner;
        ++policyRollbacks;
    }

    /// @dev Routers and Settler start with ambient inventory; it cannot replace the user's missing approval.
    function ambientAttempt(uint256 seed) public {
        _repair(0);
        uint256 r = seed % 2;
        vm.prank(users[0]);
        tokens[0].approve(address(routers[r]), 0);
        bytes32 beforeState = _digest();
        IM.SwapParams memory s = _params(0, 0, true, true, 101, 0);
        vm.prank(users[0]);
        (bool ok,) =
            address(routers[r]).call(abi.encodeCall(AuthenticatedManagedTestRouter.swap, (address(pools[0]), s)));
        assertFalse(ok, "ambient inventory cannot replace caller payment");
        assertEq(_digest(), beforeState, "missing approval atomicity");
        vm.prank(users[0]);
        tokens[0].approve(address(routers[r]), allowances[0][0][r + 3]);
        ++refusals;
    }

    /// @dev The callback's final attempt occurs inside Settler's locked input transfer in the same call.
    function reentryAttempt() public {
        _repair(0);
        IM.SwapParams memory s = _params(0, 0, true, true, 101, 0);
        tokens[0].setReentry(address(settler), abi.encodeCall(ISettler.swap, (address(pools[0]), s)));
        trade(72, 100, true, true);
        assertFalse(tokens[0].reentrySucceeded());
        assertEq(tokens[0].reentryResult(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        tokens[0].setReentry(address(0), "");
    }

    function _digest() internal view returns (bytes32 digest) {
        for (uint256 t; t < 3; ++t) {
            for (uint256 h; h < 8; ++h) {
                digest = keccak256(abi.encode(digest, tokens[t].balanceOf(holders[h])));
                for (uint256 s; s < 5; ++s) {
                    digest = keccak256(abi.encode(digest, tokens[t].allowance(holders[h], _spender(s))));
                }
            }
        }
        for (uint256 m; m < 4; ++m) {
            ManagedDirectPropAMM p = pools[_pool(m)];
            digest = keccak256(
                abi.encode(
                    digest, p.pair(_index(m)).access, p.priceAnchor(_index(m), true), p.priceAnchor(_index(m), false)
                )
            );
            for (uint256 u; u < 5; ++u) {
                address who = u < 3 ? users[u] : address(routers[u - 3]);
                digest = keccak256(
                    abi.encode(
                        digest, p.denied(who), p.takerAccess(_index(m), who, 0), p.takerAccess(_index(m), who, SPONSOR)
                    )
                );
                for (uint256 c; c < 3; ++c) {
                    digest = keccak256(
                        abi.encode(digest, p.roundingCredit(keccak256(abi.encode(_index(m), who, _customer(c)))))
                    );
                }
            }
        }
        for (uint256 p; p < 2; ++p) {
            digest = keccak256(abi.encode(digest, pools[p].owner(), pools[p].pendingOwner()));
        }
    }

    function assertModel() public view {
        for (uint256 t; t < 3; ++t) {
            uint256 sum;
            for (uint256 h; h < 8; ++h) {
                uint256 actual = tokens[t].balanceOf(holders[h]);
                assertEq(actual, balances[h][t], "exact ghost ledger including untouched users and ambient custody");
                sum += actual;
            }
            assertEq(sum, total[t], "per-token conservation");
            for (uint256 u; u < 3; ++u) {
                for (uint256 s; s < 5; ++s) {
                    assertEq(tokens[t].allowance(users[u], _spender(s)), allowances[t][u][s], "finite user approvals");
                }
            }
            for (uint256 p; p < 2; ++p) {
                assertEq(tokens[t].allowance(address(settler), address(pools[p])), 0, "Settler never approves a pool");
            }
            for (uint256 r; r < 2; ++r) {
                assertEq(tokens[t].allowance(address(routers[r]), address(settler)), 0, "router clears approvals");
            }
        }
        for (uint256 m; m < 4; ++m) {
            ManagedDirectPropAMM p = pools[_pool(m)];
            assertEq(uint8(p.pair(_index(m)).access), uint8(modes[m]), "mode model");
            assertEq(p.priceAnchor(_index(m), true), _price(m), "base anchor unchanged on revert");
            assertEq(p.priceAnchor(_index(m), false), _price(m), "quote anchor unchanged on revert");
            for (uint256 u; u < 5; ++u) {
                address who = u < 3 ? users[u] : address(routers[u - 3]);
                for (uint256 c; c < 3; ++c) {
                    assertEq(
                        p.roundingCredit(keccak256(abi.encode(_index(m), who, _customer(c)))),
                        credits[m][u][c],
                        "credit isolation by pool/pair/user/customer, shared by channels"
                    );
                }
                {
                    (uint16 sell, uint16 buy) = p.testFees(_index(m), who);
                    assertEq(sell, fees[m][u][0], "sell fee model");
                    assertEq(buy, fees[m][u][1], "buy fee model");
                    assertEq(uint8(p.takerAccess(_index(m), who, 0)), uint8(_access(m, u, 0)), "home access model");
                    assertEq(
                        uint8(p.takerAccess(_index(m), who, SPONSOR)),
                        uint8(_access(m, u, SPONSOR)),
                        "sponsor access model"
                    );
                    assertEq(uint8(p.takerAccess(_index(m), who, 9)), uint8(_access(m, u, 9)), "unknown sponsor model");
                }
            }
        }
        for (uint256 p; p < 2; ++p) {
            assertEq(pools[p].owner(), owners[p], "current owner model");
        }
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 48
/// forge-config: ci.invariant.runs = 256
/// forge-config: ci.invariant.depth = 48
/// forge-config: coverage.invariant.runs = 32
/// forge-config: coverage.invariant.depth = 32
contract RouterAsTakerInvariantTest is StdInvariant, Test {
    RouterAsTakerHandler internal handler;

    function setUp() external {
        handler = new RouterAsTakerHandler();
        // Seed actual dust credits through all entry points. Every campaign starts with real successful exact-in,
        // exact-out execution, not a zero-success counter hidden behind try/catch.
        handler.trade(0, 98, true, true);
        handler.trade(72, 2, false, false);
        handler.trade(108, 99, true, true);
        handler.trade(36, 5, false, false);
        handler.reentryAttempt();
        handler.atomicPolicyChange(false);
        handler.atomicPolicyChange(true);
        handler.assertModel();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = RouterAsTakerHandler.trade.selector;
        selectors[1] = RouterAsTakerHandler.reentryAttempt.selector;
        selectors[2] = RouterAsTakerHandler.routerListing.selector;
        selectors[3] = RouterAsTakerHandler.access.selector;
        selectors[4] = RouterAsTakerHandler.changeFees.selector;
        selectors[5] = RouterAsTakerHandler.transferOwner.selector;
        selectors[6] = RouterAsTakerHandler.atomicPolicyChange.selector;
        selectors[7] = RouterAsTakerHandler.ambientAttempt.selector;
        selectors[8] = RouterAsTakerHandler.trade.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
        // The outer fuzz driver is not a modeled identity: every user/owner/sponsor admin is selected independently
        // inside the handler. Pin it to avoid thousands of irrelevant mainnet fee-precompile storage reads when
        // running this same local model under --fork-url ... --network tempo.
        targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_independentLedgerCreditsAccessFeesAndCustody() external view {
        handler.assertModel();
    }

    function afterInvariant() external view {
        assertGt(handler.direct(), 0, "must execute direct path");
        assertGt(handler.routerSettled(), 0, "must execute routerSettled path");
        assertGt(handler.exactOutputs(), 0, "must execute exact output");
        assertGe(handler.policyRollbacks(), 2, "must roll back callback listing and access changes");
    }

    function test_directedHomeSponsorOpenClosedDeniedAndListingTransitions() external {
        handler.access(12, false); // Remove Alice from home, but keep sponsor membership.
        handler.trade(72, 100, true, true);
        handler.trade(216, 100, true, true);
        handler.access(24, false);
        handler.trade(216, 100, true, true);
        handler.access(24, true);
        handler.access(36, false); // Owner disables sponsor.
        handler.trade(216, 100, true, true);
        handler.access(24, true); // Even sponsor admin cannot list while disabled.
        handler.access(36, true);
        handler.access(48, false); // Owner removes admission.
        handler.trade(216, 100, true, true);
        handler.access(48, true);
        handler.access(0, false); // Closed.
        handler.trade(72, 100, true, true);
        handler.access(168, false); // Open, entered while paused.
        handler.trade(360, 100, true, true); // Unknown sponsor ignored on Open.
        handler.access(60, true); // Deny user; Open cannot bypass this.
        handler.trade(72, 100, true, true);
        handler.access(60, false);
        handler.access(312, true); // Deny router; all routerSettled users blocked.
        handler.trade(72, 100, true, true);
        handler.access(312, false);
        handler.access(84, false); // Listed: home membership matters again.
        handler.access(12, true); // Restore Alice before testing router membership independently.
        handler.routerListing(4, true); // Sponsor admin cannot grant.
        handler.routerListing(4, false); // Sponsor admin cannot revoke.
        handler.routerListing(0, false); // Only the owner revokes.
        handler.trade(72, 100, true, true);
        handler.routerListing(8, true); // Stranger cannot grant.
        handler.routerListing(0, true); // Owner restores listing.
        handler.trade(72, 100, true, true);
        handler.assertModel();
        assertGe(handler.refusals(), 8, "must reach concrete access/listing refusals");
        emit log_named_uint("access/listing expected trade refusals", handler.refusals());
    }

    function test_directedCoverageAllFeesUsersCustomersChannelsAndOwnership() external {
        handler.creditOnlyExercise();
        for (uint256 rate; rate < 4; ++rate) {
            for (uint256 u; u < 3; ++u) {
                for (uint256 m; m < 4; ++m) {
                    handler.changeFees(m + 4 * u + 12 * rate + 48 * rate);
                    for (uint256 c; c < 3; ++c) {
                        for (uint256 channel; channel < 4; ++channel) {
                            uint256 seed = m + 4 * u + 12 * c + 36 * channel;
                            handler.trade(seed, 100 + rate, true, true);
                            handler.trade(seed, 2 + rate, false, false);
                            handler.trade(seed, 3 + rate, true, false);
                            handler.trade(seed, 103 + rate, false, true);
                        }
                    }
                }
            }
        }
        handler.transferOwner(0);
        handler.transferOwner(1);
        handler.routerListing(0, false);
        handler.trade(72, 100, true, true);
        handler.routerListing(0, true);
        handler.routerListing(1, false);
        handler.trade(75, 100, true, true);
        handler.routerListing(1, true);
        handler.reentryAttempt();
        handler.atomicPolicyChange(false);
        handler.atomicPolicyChange(true);
        handler.ambientAttempt(0);
        handler.assertModel();
        emit log_named_uint("successful fills", handler.successes());
        emit log_named_uint("exact outputs", handler.exactOutputs());
        emit log_named_uint("direct fills", handler.direct());
        emit log_named_uint("routerSettled single fills", handler.routerSettled());
        emit log_named_uint("atomic policy rollbacks", handler.policyRollbacks());
        emit log_named_uint("expected refusals", handler.refusals());
        emit log_named_uint("live hook rate changes", handler.feeChanges());
        emit log_named_uint("owner handovers", handler.ownershipTransfers());
        emit log_named_uint("credit-only exact outputs", handler.creditOnlyOutputs());
    }
}

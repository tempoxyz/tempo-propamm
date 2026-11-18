// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestFeeHook, TestFeeHookLib } from "../../managed/utils/TestFeeHook.sol";
using TestFeeHookLib for ManagedDirectPropAMM;

import { Test, Vm, console } from "forge-std/Test.sol";

import { DirectPropAMM } from "../../../src/DirectPropAMM.sol";
import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockOracle } from "../../mocks/MockOracle.sol";
import { MockTIP20 } from "../../mocks/MockTIP20.sol";
import { MockVirtualAddressRegistry } from "../../v2/mocks/MockVirtualAddressRegistry.sol";

/// @dev The gas cheatcode that replaced the deprecated `lastCallGas`. forge-std's `Vm` doesn't declare it yet.
interface IVmFrameGas {
    function lastFrameGas() external view returns (Vm.Gas memory gas);
}

/// @notice Transaction gas of `ManagedDirectPropAMM` swaps under each access path, and of its pair, access and
/// deployment calls, on Tempo's gas schedule (TIP-1000 storage creation included). Each figure must stay within 2% of
/// the one recorded here either way, so a cheaper path fails too; `-vv` logs them to re-measure:
/// `forge test --network tempo --match-path contracts/test/fork/managed/ManagedDirectPropAMMGas.t.sol -vv`.
/// @dev Skipped without `--network tempo`, whose gas schedule the figures are for; the address registry's code is the
/// marker. It is under `test/fork/`, so neither the unit run nor `forge snapshot --check` includes it. Each figure is
/// `lastFrameGas().gasTotalUsed` of one isolated transaction (`isolate = true`), the 21,000 base included; tokens are
/// mocks. A swap sells 10 PRIME (exact input) or buys 10 PRIME (exact output) on the pool's first pair, measured on its
/// second run, with every slot it writes already created.
contract ManagedDirectPropAMMGasTest is Test {
    uint256 internal constant BPS = 10_000;
    /// @dev 2% either side of the recorded figure.
    uint256 internal constant TOLERANCE_BPS = 200;
    address internal constant ADDRESS_REGISTRY = 0xfDC0000000000000000000000000000000000000;
    /// @dev Tempo's per-transaction gas cap (TIP-1000).
    uint256 internal constant TX_GAS_CAP = 30_000_000;
    /// @dev v2's measured gap between a Moderato estimate and this kind of local figure (`VenueAccessGas`), applied
    /// to the pool's deployment the same way until a Moderato estimate of it is recorded.
    uint256 internal constant MODERATO_ESTIMATE_GAP = 1_208_812;
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant PRICE = 105_000_000;
    uint64 internal constant HOME = 0;
    uint64 internal constant SPONSOR = 7;

    // Recorded figures (forge 1.8.1, 2026-11-08). The gas tables in contracts/README.md copy them.
    uint256 internal constant FIRST_HOOK_GAS = 286_457;
    uint256 internal constant UPDATE_HOOK_GAS = 37_145;
    uint256 internal constant CLEAR_HOOK_GAS = 38_733;
    uint256 internal constant RESTORE_HOOK_GAS = 41_457;
    uint256 internal constant DEPLOY_GAS = 13_566_197;
    uint256 internal constant IN_HOME_FEE_GAS = 109_994;
    uint256 internal constant OUT_HOME_FEE_GAS = 110_475;
    uint256 internal constant SET_HOOK_RATES_GAS = 37_098;
    uint256 internal constant FIRST_HOOK_RATES_GAS = 282_098;
    uint256 internal constant UPDATE_HOOK_RATES_GAS = 32_810;
    uint256 internal constant CLEAR_HOOK_RATES_GAS = 37_674;
    uint256 internal constant IN_HOME_GAS = 102_163;
    uint256 internal constant IN_SPONSOR_GAS = 106_807;
    uint256 internal constant IN_HOME_DENIED_GAS = 104_346;
    uint256 internal constant IN_SPONSOR_DENIED_GAS = 108_990;
    uint256 internal constant IN_OPEN_GAS = 99_847;
    uint256 internal constant OUT_HOME_GAS = 102_597;
    uint256 internal constant OUT_SPONSOR_GAS = 107_241;
    uint256 internal constant OUT_HOME_DENIED_GAS = 104_780;
    uint256 internal constant OUT_SPONSOR_DENIED_GAS = 109_424;
    uint256 internal constant OUT_OPEN_GAS = 100_281;
    uint256 internal constant ADD_PAIR_NEW_TOKENS_GAS = 1_308_761;
    uint256 internal constant ADD_PAIR_KNOWN_TOKENS_GAS = 814_161;
    uint256 internal constant FIRST_OPEN_GAS = 552_244;
    uint256 internal constant REOPEN_GAS = 46_444;
    uint256 internal constant CLOSE_PAIR_GAS = 31_280;
    uint256 internal constant ADD_SPONSOR_GAS = 280_731;
    uint256 internal constant ADMIT_GAS = 285_488;
    uint256 internal constant HOME_MEMBER_GAS = 284_287;
    uint256 internal constant SPONSOR_MEMBER_GAS = 286_785;
    uint256 internal constant DENY_GAS = 284_423;
    uint256 internal constant RESET_GAS = 34_211;
    uint256 internal constant WITHDRAW_GAS = 46_922;
    uint256 internal constant V1_IN_GAS = 99_447;
    uint256 internal constant V1_OUT_GAS = 99_874;
    uint256 internal constant LIFT_GAS = 40_005;
    uint256 internal constant DELIST_GAS = 37_644;
    uint256 internal constant UNADMIT_GAS = 33_962;
    uint256 internal constant READMIT_GAS = 36_188;
    uint256 internal constant DISABLE_GAS = 31_144;
    uint256 internal constant ENABLE_GAS = 31_156;
    uint256 internal constant TRANSFER_ADMIN_GAS = 280_723;
    uint256 internal constant ACCEPT_ADMIN_GAS = 39_023;
    uint256 internal constant PAUSE_GAS = 27_761;
    uint256 internal constant UNPAUSE_GAS = 27_834;
    uint256 internal constant REMOVE_PAIR_GAS = 68_538;
    uint256 internal constant FUND_GAS = 56_593;
    /// @dev The access scripts' chunk: 50 new members, which fits the cap at Forge's 130%; a full `MAX_BATCH` of 100
    /// doesn't.
    uint256 internal constant MEMBER_CHUNK = 50;
    uint256 internal constant CHUNK_GAS = 12_781_959;
    uint256 internal constant FULL_BATCH_GAS = 25_534_711;

    address internal taker = makeAddr("taker");
    address internal admin = makeAddr("sponsorAdmin");
    address internal guardian = makeAddr("guardian");
    MockTIP20 internal prime;
    MockTIP20 internal pathUsd;
    MockOracle internal oracle;
    ManagedDirectPropAMM internal pool;

    function setUp() external {
        vm.warp(1_000_000);
        prime = new MockTIP20("PRIME", 6);
        pathUsd = new MockTIP20("pathUSD", 6);
        oracle = new MockOracle(8, PRICE, block.timestamp);
    }

    function _skipped() internal returns (bool) {
        if (ADDRESS_REGISTRY.code.length != 0) return false;
        vm.skip(true, "needs --network tempo");
        return true;
    }

    /// @dev The pool's deployment is one transaction; at Forge's 130% gas limit it must fit Tempo's cap.
    function test_deployTransactionFitsTheTransactionCap() external {
        if (_skipped()) return;
        new ManagedDirectPropAMM(address(this), address(0));
        uint256 used = _lastGas();
        _check("deploy", used, DEPLOY_GAS);
        console.log("deploy: Forge's gas limit at the Moderato estimate", (used + MODERATO_ESTIMATE_GAP) * 130 / 100);
        assertLe((used + MODERATO_ESTIMATE_GAP) * 130 / 100, TX_GAS_CAP, "Forge's 130% gas limit tops the cap");
    }

    function test_pairGas() external {
        if (_skipped()) return;
        _deploy();
        pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        _check("addPair, two new tokens", _lastGas(), ADD_PAIR_NEW_TOKENS_GAS);
        pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        _check("addPair, known tokens", _lastGas(), ADD_PAIR_KNOWN_TOKENS_GAS);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        _check("setPairAccess Closed to Listed, first (creates the anchors)", _lastGas(), FIRST_OPEN_GAS);
        pool.closePair(0);
        _check("closePair", _lastGas(), CLOSE_PAIR_GAS);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        _check("setPairAccess Closed to Listed, again", _lastGas(), REOPEN_GAS);
    }

    /// @dev The rows that clear a slot (accepting a handover, lifting a denial, delisting, removing a pair) come last:
    /// under `--network tempo` a slot cleared earlier in the test makes a later slot creation far cheaper, so every
    /// row that creates one runs first.
    function test_accessCallGas() external {
        if (_skipped()) return;
        _deploy();
        pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        pool.setMembers(0, HOME, _one(taker), true);
        _check("setMembers, home list, 1 new", _lastGas(), HOME_MEMBER_GAS);
        pool.addSponsor(SPONSOR, admin);
        _check("addSponsor", _lastGas(), ADD_SPONSOR_GAS);
        pool.setPairSponsor(0, SPONSOR, true);
        _check("setPairSponsor, admit", _lastGas(), ADMIT_GAS);
        pool.setPairSponsor(0, SPONSOR, false);
        _check("setPairSponsor, remove", _lastGas(), UNADMIT_GAS);
        pool.setPairSponsor(0, SPONSOR, true);
        _check("setPairSponsor, re-admit (rewrites the kept slot)", _lastGas(), READMIT_GAS);
        vm.prank(admin);
        pool.setMembers(0, SPONSOR, _one(taker), true);
        _check("setMembers, sponsor list, 1 new", _lastGas(), SPONSOR_MEMBER_GAS);
        pool.setSponsorEnabled(SPONSOR, false);
        _check("setSponsorEnabled(false)", _lastGas(), DISABLE_GAS);
        pool.setSponsorEnabled(SPONSOR, true);
        _check("setSponsorEnabled(true)", _lastGas(), ENABLE_GAS);
        pool.setDenied(_one(makeAddr("denied")), true);
        _check("setDenied, 1 new", _lastGas(), DENY_GAS);
        pool.resetSponsor(SPONSOR, admin);
        _check("resetSponsor", _lastGas(), RESET_GAS);
        vm.prank(admin);
        pool.transferSponsorAdmin(SPONSOR, makeAddr("next admin"));
        _check("transferSponsorAdmin (new pending slot)", _lastGas(), TRANSFER_ADMIN_GAS);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        pool.closePair(0);
        _check("closePair", _lastGas(), CLOSE_PAIR_GAS);
        pool.unpause();
        pool.pause();
        _check("pause", _lastGas(), PAUSE_GAS);
        pool.unpause();
        _check("unpause", _lastGas(), UNPAUSE_GAS);

        vm.prank(makeAddr("next admin"));
        pool.acceptSponsorAdmin(SPONSOR);
        _check("acceptSponsorAdmin (clears the pending slot)", _lastGas(), ACCEPT_ADMIN_GAS);
        pool.setDenied(_one(makeAddr("denied")), false);
        _check("setDenied, 1 lifted", _lastGas(), LIFT_GAS);
        pool.setMembers(0, HOME, _one(taker), false);
        _check("setMembers, home list, 1 delisted", _lastGas(), DELIST_GAS);
        pool.removePair(0);
        _check("removePair", _lastGas(), REMOVE_PAIR_GAS);
    }

    /// @dev A chunk of `MEMBER_CHUNK` new members fits Tempo's cap at Forge's 130% gas limit; a full `MAX_BATCH`
    /// doesn't, which is why the access script sends 50 at a time.
    function test_memberChunksFitTheTransactionCap() external {
        if (_skipped()) return;
        _deploy();
        pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        pool.setMembers(0, HOME, _fresh("chunk-", MEMBER_CHUNK), true);
        uint256 chunk = _lastGas();
        _check("setMembers, 50 new", chunk, CHUNK_GAS);
        assertLe(chunk * 130 / 100, TX_GAS_CAP, "a chunk tops the cap at Forge's gas limit");
        pool.setMembers(0, HOME, _fresh("full-", pool.MAX_BATCH()), true);
        uint256 batch = _lastGas();
        _check("setMembers, 100 new (MAX_BATCH)", batch, FULL_BATCH_GAS);
        assertGt(batch * 130 / 100, TX_GAS_CAP, "a full batch fits the cap: the script's chunk could grow");
    }

    function test_hookRegistrationGas() external {
        if (_skipped()) return;
        _deploy();
        pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        TestFeeHook first = new TestFeeHook(pool);
        TestFeeHook second = new TestFeeHook(pool);
        pool.setPairHook(0, address(first), 1);
        _check("setPairHook, first registration", _lastGas(), FIRST_HOOK_GAS);
        pool.setPairHook(0, address(second), 1);
        _check("setPairHook, replacement", _lastGas(), UPDATE_HOOK_GAS);
        pool.setPairHook(0, address(0), 0);
        _check("setPairHook, remove", _lastGas(), CLEAR_HOOK_GAS);
        pool.setPairHook(0, address(first), 1);
        _check("setPairHook, restore after removal", _lastGas(), RESTORE_HOOK_GAS);
    }

    function test_testHookRateConfigurationGas() external {
        if (_skipped()) return;
        _deploy();
        pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        pool.configureFees(0, taker, 100, 100);
        _check("test hook setFees, first configuration before any quote", _lastGas(), FIRST_HOOK_RATES_GAS);
        pool.configureFees(0, taker, 200, 300);
        _check("test hook setFees, update", _lastGas(), UPDATE_HOOK_RATES_GAS);
        pool.configureFees(0, taker, 0, 0);
        _check("test hook setFees, clear", _lastGas(), CLEAR_HOOK_RATES_GAS);
        pool.configureFees(0, taker, 100, 100);
        _check("test hook setFees, after clear", _lastGas(), SET_HOOK_RATES_GAS);
    }

    /// @dev Each path's second swap, exact input and exact output.
    function test_swapGas() external {
        if (_skipped()) return;
        _deploy();
        pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50);
        pool.setMembers(0, HOME, _one(taker), true);
        pool.addSponsor(SPONSOR, admin);
        pool.setPairSponsor(0, SPONSOR, true);
        vm.prank(admin);
        pool.setMembers(0, SPONSOR, _one(taker), true);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        prime.mint(address(pool), 1_000_000 * UNIT);
        pathUsd.mint(address(pool), 1_000_000 * UNIT);
        prime.mint(taker, 1_000_000 * UNIT);
        pathUsd.mint(taker, 1_000_000 * UNIT);
        vm.startPrank(taker);
        prime.approve(address(pool), type(uint256).max);
        pathUsd.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        pool.unpause();

        _measure("home list", HOME, IN_HOME_GAS, OUT_HOME_GAS);
        _measure("sponsor list", SPONSOR, IN_SPONSOR_GAS, OUT_SPONSOR_GAS);
        pool.setDenied(_one(makeAddr("someoneElse")), true);
        _measure("home list, one account denied", HOME, IN_HOME_DENIED_GAS, OUT_HOME_DENIED_GAS);
        _measure("sponsor list, one account denied", SPONSOR, IN_SPONSOR_DENIED_GAS, OUT_SPONSOR_DENIED_GAS);
        pool.setDenied(_one(makeAddr("someoneElse")), false);
        pool.pause();
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Open);
        pool.unpause();
        _measure("Open", 4242, IN_OPEN_GAS, OUT_OPEN_GAS);

        pool.withdraw(address(pathUsd), makeAddr("treasury"), UNIT, bytes32(0));
        pool.withdraw(address(pathUsd), makeAddr("treasury"), UNIT, bytes32(0));
        _check("withdraw", _lastGas(), WITHDRAW_GAS);
        prime.mint(address(this), 2 * UNIT);
        prime.approve(address(pool), type(uint256).max);
        pool.fund(address(prime), UNIT, bytes32(0));
        pool.fund(address(prime), UNIT, bytes32(0));
        _check("fund", _lastGas(), FUND_GAS);

        pool.closePair(0);
        pool.configureFees(0, taker, 100, 100);
        _check("test hook setFees, both directions", _lastGas(), FIRST_HOOK_RATES_GAS);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        _measure("home list, 100 bps quote-hook fee", HOME, IN_HOME_FEE_GAS, OUT_HOME_FEE_GAS);
    }

    /// @dev `DirectPropAMM` on the same mock tokens and oracle, for comparison: its taker and recipient lists (against
    /// a mock TIP-1022 registry, which v1 resolves its recipient with), then the same two swaps, each on its second
    /// run.
    function test_v1SwapGasForComparison() external {
        if (_skipped()) return;
        DirectPropAMM v1 = new DirectPropAMM(
            prime, pathUsd, oracle, new MockVirtualAddressRegistry(), address(this), guardian, 90_000, 50
        );
        v1.setTakerAllowed(taker, true);
        v1.setRecipientAllowed(taker, true);
        prime.mint(address(v1), 1_000_000 * UNIT);
        pathUsd.mint(address(v1), 1_000_000 * UNIT);
        prime.mint(taker, 1_000_000 * UNIT);
        pathUsd.mint(taker, 1_000_000 * UNIT);
        vm.startPrank(taker);
        prime.approve(address(v1), type(uint256).max);
        pathUsd.approve(address(v1), type(uint256).max);
        vm.stopPrank();
        v1.unpause();
        for (uint256 round; round < 2; ++round) {
            vm.prank(taker);
            v1.swapExactInput(true, 10 * UNIT, 0, taker, "c", "t", block.timestamp, PRICE, 0, 0);
        }
        _check("DirectPropAMM swapExactInput", _lastGas(), V1_IN_GAS);
        for (uint256 round; round < 2; ++round) {
            vm.prank(taker);
            v1.swapExactOutput(false, 10 * UNIT, type(uint256).max, taker, "c", "t", block.timestamp, PRICE, 0, 0);
        }
        _check("DirectPropAMM swapExactOutput", _lastGas(), V1_OUT_GAS);
    }

    function _measure(string memory label, uint64 sponsorId, uint256 recordedIn, uint256 recordedOut) internal {
        for (uint256 round; round < 2; ++round) {
            vm.prank(taker);
            pool.swapExactInput(0, true, 10 * UNIT, 0, sponsorId, "c", "t", block.timestamp, PRICE, 0, 0);
        }
        _check(string.concat("swapExactInput, ", label), _lastGas(), recordedIn);
        for (uint256 round; round < 2; ++round) {
            vm.prank(taker);
            pool.swapExactOutput(
                0, false, 10 * UNIT, type(uint256).max, sponsorId, "c", "t", block.timestamp, PRICE, 0, 0
            );
        }
        _check(string.concat("swapExactOutput, ", label), _lastGas(), recordedOut);
    }

    function _deploy() internal {
        pool = new ManagedDirectPropAMM(address(this), address(0));
    }

    function _fresh(string memory prefix, uint256 n) internal pure returns (address[] memory accounts) {
        accounts = new address[](n);
        for (uint256 i; i < n; ++i) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode(prefix, i)))));
        }
    }

    function _check(string memory label, uint256 used, uint256 recorded) internal pure {
        console.log(label, used);
        uint256 slack = recorded * TOLERANCE_BPS / BPS;
        assertGe(used, recorded - slack, string.concat(label, ": cheaper than recorded; update the figure"));
        assertLe(used, recorded + slack, string.concat(label, ": dearer than recorded"));
    }

    function _lastGas() internal view returns (uint256) {
        return IVmFrameGas(address(vm)).lastFrameGas().gasTotalUsed;
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}

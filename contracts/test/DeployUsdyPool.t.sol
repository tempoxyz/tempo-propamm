// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DeployUsdyPool } from "../script/DeployUsdyPool.s.sol";
import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { OndoUSDYPriceOracleAdapter } from "../src/OndoUSDYPriceOracleAdapter.sol";
import { TempoMainnet } from "../src/TempoMainnet.sol";
import { ITIP20 } from "../src/interfaces/ITIP20.sol";
import { MockOndoUSDYOracleWrapper } from "./OndoUSDYPriceOracleAdapter.t.sol";
import { MockVirtualAddressRegistry } from "./v2/mocks/MockVirtualAddressRegistry.sol";
import { VirtualAddress } from "./v2/utils/VirtualAddress.sol";

/// @dev Most tests use storage rather than process-global environment variables.
contract DeployUsdyPoolHarness is DeployUsdyPool {
    Config internal config;
    bool internal readRiskEnvironment;

    function useRiskEnvironment() external {
        readRiskEnvironment = true;
    }

    function setConfig(Config memory config_) external {
        config = config_;
    }

    function optionalUint(string memory field, uint256 defaultValue) external view returns (uint256) {
        return _optionalUint(field, defaultValue);
    }

    function _readConfig() internal view override returns (Config memory c) {
        c = config;
        if (readRiskEnvironment) {
            // The production parser, with test-only keys: OWNER_ADDRESS and GUARDIAN_ADDRESS are also used by
            // DeployManagedPool's parallel environment test. Never mutate those process-global inputs here.
            c.maxOracleAge = _optionalUint("PROPAMM_TEST_USDY_AGE", 90_000);
            c.maxPriceDeviationBps = _optionalUint("PROPAMM_TEST_USDY_DEVIATION", 50);
        }
    }
}

contract DeployUsdyPoolTest is Test {
    uint256 internal constant START_TIME = 1_788_220_800;
    uint256 internal constant PRICE = 1_144_967_860_000_000_000;
    bytes4 internal constant INVALID_CONFIG = bytes4(keccak256("InvalidConfig(string)"));

    DeployUsdyPoolHarness internal script;
    MockOndoUSDYOracleWrapper internal wrapper;
    MockVirtualAddressRegistry internal registry = MockVirtualAddressRegistry(TempoMainnet.ADDRESS_REGISTRY);
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");

    function setUp() external {
        vm.chainId(TempoMainnet.CHAIN_ID);
        vm.warp(START_TIME + 3 days + 1 hours);
        vm.etch(TempoMainnet.ADDRESS_REGISTRY, address(new MockVirtualAddressRegistry()).code);
        _mockToken(TempoMainnet.USDY);
        _mockToken(TempoMainnet.PATH_USD);
        wrapper = new MockOndoUSDYOracleWrapper(PRICE);
        script = new DeployUsdyPoolHarness();
        script.setConfig(_config());
    }

    function test_deploysPausedPoolWithFinalRolesAndRiskSettings() external {
        (OndoUSDYPriceOracleAdapter adapter, DirectPropAMM pool) = script.run();
        assertEq(address(adapter.wrapper()), address(wrapper));
        assertEq(address(pool.oracle()), address(adapter));
        assertEq(address(pool.baseToken()), TempoMainnet.USDY);
        assertEq(address(pool.quoteToken()), TempoMainnet.PATH_USD);
        assertEq(pool.owner(), owner);
        assertEq(pool.guardian(), guardian);
        assertEq(pool.maxOracleAge(), 90_000);
        assertEq(pool.maxPriceDeviationBps(), 50);
        assertTrue(pool.paused());
        vm.prank(owner);
        pool.unpause();
        assertFalse(pool.paused());
        vm.prank(guardian);
        pool.pause();
        assertTrue(pool.paused());
    }

    function test_rejectsRegisteredVirtualOwner() external {
        _rejectVirtualRole(true, true);
    }

    function test_rejectsRegisteredVirtualGuardian() external {
        _rejectVirtualRole(false, true);
    }

    function test_rejectsUnregisteredVirtualOwner() external {
        _rejectVirtualRole(true, false);
    }

    function test_rejectsUnregisteredVirtualGuardian() external {
        _rejectVirtualRole(false, false);
    }

    function test_rejectsZeroRolesBeforeAdapterConstruction() external {
        DeployUsdyPool.Config memory config = _config();
        // An unusable wrapper makes this fail if validation slips past the first CREATE.
        config.wrapper = address(0);
        config.owner = address(0);
        script.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(INVALID_CONFIG, "OWNER_ADDRESS"));
        script.run();
        config.owner = owner;
        config.guardian = address(0);
        script.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(INVALID_CONFIG, "GUARDIAN_ADDRESS"));
        script.run();
    }

    function test_registryFailuresFailClosedBeforeAdapterConstruction() external {
        DeployUsdyPool.Config memory config = _config();
        config.wrapper = address(0);
        script.setConfig(config);
        registry.setReturnZero(true);
        vm.expectRevert(abi.encodeWithSelector(INVALID_CONFIG, "OWNER_ADDRESS"));
        script.run();
    }

    function test_acceptsSelfResolvingContractRoles() external {
        // The preflight must not impose an EOA-only check on Safe/controller roles.
        vm.etch(owner, hex"00");
        vm.etch(guardian, hex"00");
        (, DirectPropAMM pool) = script.run();
        assertEq(pool.owner(), owner);
        assertEq(pool.guardian(), guardian);
    }

    function test_rejectsWrongChain() external {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployUsdyPool.UnexpectedChain.selector, uint256(1)));
        script.run();
    }

    function test_preservesOptionalDefaultsWhenUnset() external view {
        // Unique keys keep this independent of a caller's deployment environment and other script tests.
        string memory ageKey = "PROPAMM_TEST_USDY_UNSET_AGE_24aab90d";
        string memory deviationKey = "PROPAMM_TEST_USDY_UNSET_DEVIATION_24aab90d";
        assertFalse(vm.envExists(ageKey));
        assertFalse(vm.envExists(deviationKey));
        assertEq(script.optionalUint(ageKey, 90_000), 90_000);
        assertEq(script.optionalUint(deviationKey, 50), 50);
    }

    function test_rejectsMalformedRiskInputsAndPreservesValidValues() external {
        // Exercise the real numeric parser and deployment entry point with unique environment keys, so
        // this regression remains deterministic beside every other script suite.
        string[2] memory fields = ["PROPAMM_TEST_USDY_AGE", "PROPAMM_TEST_USDY_DEVIATION"];
        string[2] memory saved;
        for (uint256 i; i < fields.length; ++i) {
            saved[i] = vm.envOr(fields[i], string(""));
        }
        vm.setEnv(fields[0], "86400");
        vm.setEnv(fields[1], "0");
        script.useRiskEnvironment();
        (, DirectPropAMM pool) = script.run();
        assertEq(pool.maxOracleAge(), 1 days);
        assertEq(pool.maxPriceDeviationBps(), 0);

        string[7] memory invalid = [
            "typo",
            "",
            " ",
            "-1",
            "1.5",
            "0xzz",
            "115792089237316195423570985008687907853269984665640564039457584007913129639936"
        ];
        uint256 acceptedMalformed;
        for (uint256 field; field < fields.length; ++field) {
            for (uint256 i; i < invalid.length; ++i) {
                vm.setEnv(fields[field], invalid[i]);
                try script.run() {
                    ++acceptedMalformed;
                    emit log_named_string(fields[field], invalid[i]);
                } catch { }
            }
            vm.setEnv(fields[field], field == 0 ? "86400" : "0");
        }
        // Both explicit non-default values survive parsing unchanged as well.
        vm.setEnv(fields[0], "172800");
        vm.setEnv(fields[1], "125");
        (, pool) = script.run();
        assertEq(pool.maxOracleAge(), 2 days);
        assertEq(pool.maxPriceDeviationBps(), 125);
        for (uint256 i; i < fields.length; ++i) {
            vm.setEnv(fields[i], saved[i]);
        }
        assertEq(acceptedMalformed, 0, "malformed risk inputs must never deploy");
    }

    function test_preservesNumericRiskBounds() external {
        DeployUsdyPool.Config memory config = _config();
        config.maxOracleAge = 86399;
        script.setConfig(config);
        vm.expectRevert(abi.encodeWithSelector(DeployUsdyPool.InvalidMaxOracleAge.selector, uint256(86399)));
        script.run();
        config.maxOracleAge = uint256(type(uint80).max) + 1;
        script.setConfig(config);
        vm.expectRevert(DirectPropAMM.InvalidMaxOracleAge.selector);
        script.run();
        // A reverted constructor leaves Forge's local broadcast context active, unlike the EVM state.
        vm.stopBroadcast();
        config.maxOracleAge = 90_000;
        config.maxPriceDeviationBps = 10001;
        script.setConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.InvalidMaxPriceDeviationBps.selector, uint256(10001), uint256(10000))
        );
        script.run();
    }

    function _rejectVirtualRole(bool isOwner, bool registered) internal {
        address virtualRole = VirtualAddress.make(77, 1);
        if (registered) registry.setVirtual(virtualRole, makeAddr("master"));
        DeployUsdyPool.Config memory config = _config();
        if (isOwner) config.owner = virtualRole;
        else config.guardian = virtualRole;
        script.setConfig(config);
        if (registered) {
            vm.expectRevert(abi.encodeWithSelector(INVALID_CONFIG, isOwner ? "OWNER_ADDRESS" : "GUARDIAN_ADDRESS"));
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(MockVirtualAddressRegistry.VirtualAddressUnregistered.selector, virtualRole)
            );
        }
        script.run();
    }

    function _config() internal view returns (DeployUsdyPool.Config memory) {
        return DeployUsdyPool.Config(TempoMainnet.USDY, address(wrapper), owner, guardian, 90_000, 50);
    }

    function _mockToken(address token) internal {
        vm.etch(token, hex"00");
        vm.mockCall(token, abi.encodeCall(ITIP20.decimals, ()), abi.encode(uint8(6)));
    }
}

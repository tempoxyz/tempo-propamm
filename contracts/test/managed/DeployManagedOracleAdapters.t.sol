// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DeployManagedOracleAdapters } from "../../script/managed/DeployManagedOracleAdapters.s.sol";
import { Chainlink18To8PriceOracleAdapter } from "../../src/Chainlink18To8PriceOracleAdapter.sol";
import { ChainlinkPriceOracleAdapter } from "../../src/ChainlinkPriceOracleAdapter.sol";
import { OndoUSDYPriceOracleAdapter } from "../../src/OndoUSDYPriceOracleAdapter.sol";
import { TempoMainnet } from "../../src/TempoMainnet.sol";
import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";
import { ScriptFeed, ScriptUsdyWrapper } from "./utils/OracleSourceFixtures.sol";

/// @dev Reads its inputs from storage instead of the process environment, which parallel tests share.
contract DeployManagedOracleAdaptersHarness is DeployManagedOracleAdapters {
    bytes internal _encoded;

    function setInput(Config calldata config) external {
        _encoded = abi.encode(config);
    }

    /// @notice The real environment reader, for the one test that sets the environment.
    function readEnvConfig() external view returns (Config memory) {
        return super._readConfig();
    }

    function _readConfig() internal view override returns (Config memory) {
        return abi.decode(_encoded, (Config));
    }
}

/// @dev A feed without `description()`.
contract UndescribedFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract DeployManagedOracleAdaptersTest is Test {
    uint256 internal constant MAINNET = 4217;
    uint256 internal constant MODERATO = 42431;
    string internal constant PRIME_DESCRIPTION = "PRIME / USD";
    int256 internal constant PRIME_18 = 1_052_345_678_912_345_678;
    uint256 internal constant PRIME_8 = 105_234_567;

    DeployManagedOracleAdaptersHarness internal script;
    address internal deployer = makeAddr("deployer");
    ScriptFeed internal feed18;
    ScriptFeed internal feed8;
    ScriptUsdyWrapper internal wrapper;
    uint256 internal observedAt;

    function setUp() external {
        vm.warp(1_000_000);
        vm.chainId(MODERATO);
        observedAt = block.timestamp - 600;
        script = new DeployManagedOracleAdaptersHarness();
        feed18 = new ScriptFeed(18, PRIME_DESCRIPTION, PRIME_18, observedAt);
        feed8 = new ScriptFeed(8, "EUR / USD", 108_000_000, observedAt);
        wrapper = new ScriptUsdyWrapper();
    }

    function test_deploysEachKindAtTheDeployersNextAddresses() external {
        DeployManagedOracleAdapters.Config memory c = _config(4);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed18), PRIME_DESCRIPTION, 18);
        c.adapters[1] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink18To8, address(feed18), PRIME_DESCRIPTION, 8);
        c.adapters[2] = _adapter(DeployManagedOracleAdapters.Kind.OndoUsdy, address(wrapper), "-", 18);
        c.adapters[3] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed8), "EUR / USD", 8);
        script.setInput(c);
        uint64 nonce = vm.getNonce(deployer);

        address[] memory adapters = script.run();

        assertEq(adapters.length, 4);
        assertEq(vm.getNonce(deployer), nonce + 4, "one CREATE per adapter and nothing else");
        for (uint256 i; i < 4; ++i) {
            assertEq(adapters[i], vm.computeCreateAddress(deployer, nonce + i));
        }
        assertEq(address(ChainlinkPriceOracleAdapter(adapters[0]).feed()), address(feed18));
        assertEq(IPriceOracle(adapters[0]).decimals(), 18);
        (uint256 price, uint256 updatedAt) = IPriceOracle(adapters[0]).latestPrice();
        assertEq(price, uint256(PRIME_18));
        assertEq(updatedAt, observedAt);

        assertEq(address(Chainlink18To8PriceOracleAdapter(adapters[1]).feed()), address(feed18));
        assertEq(IPriceOracle(adapters[1]).decimals(), 8);
        (price,) = IPriceOracle(adapters[1]).latestPrice();
        assertEq(price, PRIME_8, "rounded down to 8 decimals");

        assertEq(address(OndoUSDYPriceOracleAdapter(adapters[2]).wrapper()), address(wrapper));
        assertEq(IPriceOracle(adapters[2]).decimals(), 18);
        assertEq(address(ChainlinkPriceOracleAdapter(adapters[3]).feed()), address(feed8));
    }

    /// @dev Two pairs on one feed need an adapter each: the pool refuses an oracle a second pair already uses.
    function test_oneSourceMayBackSeveralAdapters() external {
        DeployManagedOracleAdapters.Config memory c = _config(2);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed18), PRIME_DESCRIPTION, 18);
        c.adapters[1] = c.adapters[0];
        script.setInput(c);
        address[] memory adapters = script.run();
        assertTrue(adapters[0] != adapters[1]);
        assertEq(address(ChainlinkPriceOracleAdapter(adapters[1]).feed()), address(feed18));
    }

    /// @dev The adapter of the pool being replaced reads the same feed at 8 decimals: a native 18-decimal adapter and
    /// a fresh 8-decimal one both agree with it; another feed, price or observation time does not.
    function test_theNewAdapterMustAgreeWithTheOneItReplaces() external {
        address old = address(new Chainlink18To8PriceOracleAdapter(feed18));
        DeployManagedOracleAdapters.Config memory c = _config(2);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed18), PRIME_DESCRIPTION, 18);
        c.adapters[0].baseline = old;
        c.adapters[1] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink18To8, address(feed18), PRIME_DESCRIPTION, 8);
        c.adapters[1].baseline = old;
        script.setInput(c);
        assertEq(script.run().length, 2);

        // An 8-decimal adapter also agrees with an 18-decimal baseline.
        c = _config(1);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink18To8, address(feed18), PRIME_DESCRIPTION, 8);
        c.adapters[0].baseline = address(new ChainlinkPriceOracleAdapter(feed18));
        script.setInput(c);
        assertEq(script.run().length, 1);

        // Another price.
        c.adapters[0].baseline = address(new MockOracle(8, PRIME_8 + 1, observedAt));
        script.setInput(c);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployManagedOracleAdapters.ReferenceMismatch.selector,
                c.adapters[0].baseline,
                PRIME_8,
                observedAt,
                PRIME_8 + 1,
                observedAt
            )
        );
        script.run();

        // The same price observed at another time is another round.
        c.adapters[0].baseline = address(new MockOracle(8, PRIME_8, observedAt - 1));
        script.setInput(c);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployManagedOracleAdapters.ReferenceMismatch.selector,
                c.adapters[0].baseline,
                PRIME_8,
                observedAt,
                PRIME_8,
                observedAt - 1
            )
        );
        script.run();

        // Not an oracle, and no code.
        c.adapters[0].baseline = address(wrapper);
        script.setInput(c);
        _expectInvalid("ORACLE_REFERENCES[0] has no decimals()");
        script.run();
        c.adapters[0].baseline = makeAddr("no code");
        script.setInput(c);
        _expectInvalid("ORACLE_REFERENCES[0]");
        script.run();
        assertEq(vm.getNonce(deployer), 3, "a refused run sends nothing");
    }

    function test_refusesASourceWithoutAFreshPositiveObservation() external {
        DeployManagedOracleAdapters.Config memory c = _config(1);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed18), PRIME_DESCRIPTION, 18);
        c.adapters[0].maxOracleAge = 599;
        script.setInput(c);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployManagedOracleAdapters.InvalidObservation.selector,
                address(feed18),
                uint256(PRIME_18),
                observedAt,
                599
            )
        );
        script.run();

        c.adapters[0].maxOracleAge = 600;
        script.setInput(c);
        assertEq(script.run().length, 1, "exactly the age limit is fresh");

        feed18.setRound(0, observedAt);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployManagedOracleAdapters.InvalidObservation.selector, address(feed18), 0, observedAt, 600
            )
        );
        script.run();

        feed18.setRound(PRIME_18, block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployManagedOracleAdapters.InvalidObservation.selector,
                address(feed18),
                uint256(PRIME_18),
                block.timestamp + 1,
                600
            )
        );
        script.run();
        assertEq(vm.getNonce(deployer), 1);
    }

    function test_refusesFeedsThatDoNotMatchTheReviewedInputs() external {
        DeployManagedOracleAdapters.Config memory c = _config(1);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed18), "PRIME / EUR", 18);
        script.setInput(c);
        _expectInvalid("ORACLE_SOURCE_DESCRIPTIONS[0]: the feed says \"PRIME / USD\"");
        script.run();

        c.adapters[0].description = "-";
        script.setInput(c);
        _expectInvalid("ORACLE_SOURCE_DESCRIPTIONS[0]");
        script.run();

        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed18), PRIME_DESCRIPTION, 8);
        script.setInput(c);
        _expectInvalid("ORACLE_DECIMALS[0]: the feed has 18");
        script.run();

        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink18To8, address(feed8), "EUR / USD", 8);
        script.setInput(c);
        _expectInvalid("ORACLE_SOURCES[0] is not an 18-decimal feed");
        script.run();

        c.adapters[0] =
            _adapter(DeployManagedOracleAdapters.Kind.Chainlink18To8, address(feed18), PRIME_DESCRIPTION, 18);
        script.setInput(c);
        _expectInvalid("ORACLE_DECIMALS[0] must be 8");
        script.run();

        c.adapters[0] =
            _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(new UndescribedFeed()), "EUR / USD", 8);
        script.setInput(c);
        _expectInvalid("ORACLE_SOURCES[0] has no description()");
        script.run();

        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(wrapper), "EUR / USD", 8);
        script.setInput(c);
        _expectInvalid("ORACLE_SOURCES[0] has no description()");
        script.run();

        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, makeAddr("no code"), "EUR / USD", 8);
        script.setInput(c);
        _expectInvalid("ORACLE_SOURCES[0]");
        script.run();

        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.None, address(feed8), "EUR / USD", 8);
        script.setInput(c);
        _expectInvalid("ORACLE_KINDS[0]");
        script.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function test_usdyTakesOnlyOndosWrapperOnMainnet() external {
        DeployManagedOracleAdapters.Config memory c = _config(1);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.OndoUsdy, address(wrapper), "USDY / USD", 18);
        script.setInput(c);
        _expectInvalid("ORACLE_SOURCE_DESCRIPTIONS[0] must be -");
        script.run();

        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.OndoUsdy, address(wrapper), "-", 8);
        script.setInput(c);
        _expectInvalid("ORACLE_DECIMALS[0] must be 18");
        script.run();

        vm.chainId(MAINNET);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.OndoUsdy, address(wrapper), "-", 18);
        script.setInput(c);
        _expectInvalid("ORACLE_SOURCES[0] is not Ondo's USDY wrapper");
        script.run();

        vm.etch(TempoMainnet.USDY_ORACLE_WRAPPER, address(wrapper).code);
        c.adapters[0].source = TempoMainnet.USDY_ORACLE_WRAPPER;
        script.setInput(c);
        address[] memory adapters = script.run();
        assertEq(address(OndoUSDYPriceOracleAdapter(adapters[0]).wrapper()), TempoMainnet.USDY_ORACLE_WRAPPER);
    }

    function test_refusesOtherChainsDeployersAndCounts() external {
        DeployManagedOracleAdapters.Config memory c = _config(1);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed8), "EUR / USD", 8);
        script.setInput(c);
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployManagedOracleAdapters.UnexpectedChain.selector, 1));
        script.run();
        vm.chainId(MODERATO);

        address[3] memory bad = [address(0), 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, VirtualAddress.make(1, 1)];
        for (uint256 i; i < bad.length; ++i) {
            c.deployer = bad[i];
            script.setInput(c);
            _expectInvalid("DEPLOYER_ADDRESS");
            script.run();
        }

        script.setInput(_config(0));
        _expectInvalid("ORACLE_* lists need 1 to 16 adapters");
        script.run();
        c = _config(17);
        for (uint256 i; i < 17; ++i) {
            c.adapters[i] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed8), "EUR / USD", 8);
        }
        script.setInput(c);
        _expectInvalid("ORACLE_* lists need 1 to 16 adapters");
        script.run();

        c = _config(1);
        c.adapters[0] = _adapter(DeployManagedOracleAdapters.Kind.Chainlink, address(feed8), "EUR / USD", 8);
        c.adapters[0].maxOracleAge = 0;
        script.setInput(c);
        _expectInvalid("ORACLE_MAX_AGES[0]");
        script.run();
        c.adapters[0].maxOracleAge = 365 days + 1;
        script.setInput(c);
        _expectInvalid("ORACLE_MAX_AGES[0]");
        script.run();
    }

    function test_readsTheEnvironment() external {
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("ORACLE_KINDS", "CHAINLINK_18_TO_8,ONDO_USDY,CHAINLINK");
        vm.setEnv(
            "ORACLE_SOURCES",
            string.concat(
                vm.toString(address(feed18)), ",", vm.toString(address(wrapper)), ",", vm.toString(address(feed8))
            )
        );
        vm.setEnv("ORACLE_SOURCE_DESCRIPTIONS", "PRIME / USD|-|EUR / USD");
        vm.setEnv("ORACLE_DECIMALS", "8,18,8");
        vm.setEnv("ORACLE_MAX_AGES", "90000,3600,7200");
        vm.setEnv(
            "ORACLE_REFERENCES",
            string.concat(vm.toString(address(feed8)), ",", vm.toString(address(0)), ",", vm.toString(address(0)))
        );
        DeployManagedOracleAdapters.Config memory c = script.readEnvConfig();
        assertEq(c.deployer, deployer);
        assertEq(c.adapters.length, 3);
        assertEq(uint8(c.adapters[0].kind), uint8(DeployManagedOracleAdapters.Kind.Chainlink18To8));
        assertEq(uint8(c.adapters[1].kind), uint8(DeployManagedOracleAdapters.Kind.OndoUsdy));
        assertEq(uint8(c.adapters[2].kind), uint8(DeployManagedOracleAdapters.Kind.Chainlink));
        assertEq(c.adapters[0].source, address(feed18));
        assertEq(c.adapters[0].description, PRIME_DESCRIPTION);
        assertEq(c.adapters[1].description, "-");
        assertEq(c.adapters[2].description, "EUR / USD");
        assertEq(c.adapters[0].decimals, 8);
        assertEq(c.adapters[2].maxOracleAge, 7200);
        assertEq(c.adapters[0].baseline, address(feed8));
        assertEq(c.adapters[1].baseline, address(0));

        vm.setEnv("ORACLE_KINDS", "CHAINLINK_18_TO_8,ONDO_USDY,chainlink");
        _expectInvalid("ORACLE_KINDS[2]");
        script.readEnvConfig();
        vm.setEnv("ORACLE_KINDS", "CHAINLINK_18_TO_8,ONDO_USDY,CHAINLINK");
        vm.setEnv("ORACLE_DECIMALS", "8,18,256");
        _expectInvalid("ORACLE_DECIMALS[2]");
        script.readEnvConfig();
        vm.setEnv("ORACLE_DECIMALS", "8,18");
        _expectInvalid("ORACLE_* lists need one entry per adapter");
        script.readEnvConfig();
    }

    // ---------------------------------------------------------------- helpers

    function _config(uint256 count) internal view returns (DeployManagedOracleAdapters.Config memory config) {
        config.deployer = deployer;
        config.adapters = new DeployManagedOracleAdapters.AdapterConfig[](count);
    }

    function _adapter(DeployManagedOracleAdapters.Kind kind, address source, string memory description, uint8 decimals)
        internal
        pure
        returns (DeployManagedOracleAdapters.AdapterConfig memory)
    {
        return DeployManagedOracleAdapters.AdapterConfig({
            kind: kind,
            source: source,
            description: description,
            decimals: decimals,
            maxOracleAge: 90_000,
            baseline: address(0)
        });
    }

    function _expectInvalid(string memory field) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployManagedOracleAdapters.InvalidConfig.selector, field));
    }
}

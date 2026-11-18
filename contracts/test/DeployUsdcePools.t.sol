// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DeployUsdcePools } from "../script/DeployUsdcePools.s.sol";
import { ChainlinkPriceOracleAdapter } from "../src/ChainlinkPriceOracleAdapter.sol";
import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { OndoUSDYPriceOracleAdapter } from "../src/OndoUSDYPriceOracleAdapter.sol";
import { TempoMainnet } from "../src/TempoMainnet.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { IOndoUSDYOracleWrapper } from "../src/interfaces/IOndoUSDYOracle.sol";
import { ITIP20 } from "../src/interfaces/ITIP20.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";

/// @dev EVM storage is isolated per test; process environment variables are not.
contract DeployUsdcePoolsHarness is DeployUsdcePools {
    mapping(string field => string value) public input;

    function setInput(string memory field, string memory value) external {
        input[field] = value;
    }

    function _readConfig() internal view override returns (Config memory) {
        return Config({
            deployer: vm.parseAddress(input["DEPLOYER_ADDRESS"]),
            owner: vm.parseAddress(input["OWNER_ADDRESS"]),
            guardian: vm.parseAddress(input["GUARDIAN_ADDRESS"]),
            primeMaxOracleAge: vm.parseUint(input["PRIME_MAX_ORACLE_AGE"]),
            primeMaxPriceDeviationBps: vm.parseUint(input["PRIME_MAX_PRICE_DEVIATION_BPS"]),
            usdyMaxOracleAge: vm.parseUint(input["USDY_MAX_ORACLE_AGE"]),
            usdyMaxPriceDeviationBps: vm.parseUint(input["USDY_MAX_PRICE_DEVIATION_BPS"])
        });
    }
}

contract DeployUsdcePoolsTest is Test {
    uint256 internal constant START_TIME = 1_788_220_800;
    uint256 internal constant PRIME_PRICE = 105_000_000;
    uint256 internal constant USDY_PRICE = 1_144_967_860_000_000_000;

    DeployUsdcePoolsHarness internal deploymentScript;
    address internal deployer;
    address internal owner;
    address internal guardian;

    function setUp() external {
        vm.chainId(TempoMainnet.CHAIN_ID);
        vm.warp(START_TIME + 3 days + 1 hours);
        deployer = makeAddr("deployer");
        owner = makeAddr("owner");
        guardian = makeAddr("guardian");
        deploymentScript = new DeployUsdcePoolsHarness();
        deploymentScript.setInput("DEPLOYER_ADDRESS", vm.toString(deployer));
        deploymentScript.setInput("OWNER_ADDRESS", vm.toString(owner));
        deploymentScript.setInput("GUARDIAN_ADDRESS", vm.toString(guardian));
        deploymentScript.setInput("PRIME_MAX_ORACLE_AGE", "3600");
        deploymentScript.setInput("PRIME_MAX_PRICE_DEVIATION_BPS", "25");
        deploymentScript.setInput("USDY_MAX_ORACLE_AGE", "90000");
        deploymentScript.setInput("USDY_MAX_PRICE_DEVIATION_BPS", "50");

        _mockToken(TempoMainnet.PRIME, "PRIME");
        _mockToken(TempoMainnet.USDY, "USDY");
        _mockToken(TempoMainnet.USDCE, "USDC.e");
        vm.etch(TempoMainnet.ADDRESS_REGISTRY, address(new MockAddressRegistry()).code);
        vm.etch(TempoMainnet.PRIME_USD_CHAINLINK, hex"00");
        vm.mockCall(TempoMainnet.PRIME_USD_CHAINLINK, abi.encodeCall(IAggregatorV3.decimals, ()), abi.encode(uint8(8)));
        vm.mockCall(
            TempoMainnet.PRIME_USD_CHAINLINK, abi.encodeCall(IAggregatorV3.description, ()), abi.encode("PRIME / USD")
        );
        _primeRound(int256(PRIME_PRICE), block.timestamp - 60, block.timestamp);

        vm.etch(TempoMainnet.USDY_ORACLE_WRAPPER, hex"00");
        _usdyPrice(USDY_PRICE);
    }

    function test_deploysOnlyFourContractsWithFinalRolesAndSeparateRiskLimits() external {
        uint64 nonceBefore = vm.getNonce(deployer);
        DeployUsdcePools.Deployment memory deployed = deploymentScript.run();
        // The two preflight adapters are local probes, not deployer transactions.
        assertEq(vm.getNonce(deployer), nonceBefore + 4);
        assertEq(address(deployed.primeAdapter.feed()), TempoMainnet.PRIME_USD_CHAINLINK);
        assertEq(address(deployed.usdyAdapter.wrapper()), TempoMainnet.USDY_ORACLE_WRAPPER);
        _assertPool(deployed.primePool, TempoMainnet.PRIME, address(deployed.primeAdapter), 8, 3600, 25);
        _assertPool(deployed.usdyPool, TempoMainnet.USDY, address(deployed.usdyAdapter), 18, 90000, 50);
    }

    function test_preservesPrimeDonationAtPredictedPool() external {
        _assertDonationPreserved(true, true);
    }

    function test_preservesUsdceDonationAtPredictedPrimePool() external {
        _assertDonationPreserved(true, false);
    }

    function test_preservesUsdyDonationAtPredictedPool() external {
        _assertDonationPreserved(false, true);
    }

    function test_preservesUsdceDonationAtPredictedUsdyPool() external {
        _assertDonationPreserved(false, false);
    }

    function testFuzz_rejectsChangedDonationSnapshot(bool prime, bool base, bool increase) external {
        address target = vm.computeCreateAddress(deployer, prime ? 1 : 3);
        address token = base ? (prime ? TempoMainnet.PRIME : TempoMainnet.USDY) : TempoMainnet.USDCE;
        bytes[] memory balances = new bytes[](2);
        balances[0] = abi.encode(increase ? uint256(0) : uint256(1));
        balances[1] = abi.encode(increase ? uint256(1) : uint256(0));
        // A changed read after deployment must still fail, in either direction, rather than skipping inventory checks.
        vm.mockCalls(token, abi.encodeCall(ITIP20.balanceOf, (target)), balances);
        vm.expectRevert(abi.encodeWithSelector(DeployUsdcePools.UnexpectedPoolState.selector, target));
        deploymentScript.run();
    }

    function test_finalOwnerCanActivateBothPoolsAndGuardianCanPause() external {
        DeployUsdcePools.Deployment memory deployed = deploymentScript.run();
        vm.prank(owner);
        deployed.primePool.unpause();
        vm.prank(owner);
        deployed.usdyPool.unpause();
        assertEq(deployed.primePool.baseToQuotePriceAnchor(), PRIME_PRICE);
        assertEq(deployed.primePool.quoteToBasePriceAnchor(), PRIME_PRICE);
        assertEq(deployed.usdyPool.baseToQuotePriceAnchor(), USDY_PRICE);
        assertEq(deployed.usdyPool.quoteToBasePriceAnchor(), USDY_PRICE);
        (uint256 primeOut,, uint256 primeTimestamp) = deployed.primePool.quoteExactInput(true, 1e6);
        (uint256 usdyOut,, uint256 usdyTimestamp) = deployed.usdyPool.quoteExactInput(true, 1e6);
        assertEq(primeOut, 1_050_000);
        assertEq(usdyOut, 1_144_967);
        assertEq(primeTimestamp, block.timestamp - 60);
        assertEq(usdyTimestamp, block.timestamp);
        vm.prank(guardian);
        deployed.primePool.pause();
        vm.prank(guardian);
        deployed.usdyPool.pause();
        assertTrue(deployed.primePool.paused());
        assertTrue(deployed.usdyPool.paused());
    }

    function test_deployerCannotAdministerEitherPool() external {
        DeployUsdcePools.Deployment memory deployed = deploymentScript.run();
        _assertNoDeployerAuthority(deployed.primePool);
        _assertNoDeployerAuthority(deployed.usdyPool);
    }

    function test_rejectsWrongChain() external {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployUsdcePools.UnexpectedChain.selector, uint256(1)));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function test_requiresExplicitRoleAndRiskInputs() external {
        // This is the only test mutating the environment; every other test uses the isolated harness.
        DeployUsdcePools realScript = new DeployUsdcePools();
        // Even zero deviation must be explicit; an empty entry must not silently become a default.
        string[7] memory fields = [
            "DEPLOYER_ADDRESS",
            "OWNER_ADDRESS",
            "GUARDIAN_ADDRESS",
            "PRIME_MAX_ORACLE_AGE",
            "PRIME_MAX_PRICE_DEVIATION_BPS",
            "USDY_MAX_ORACLE_AGE",
            "USDY_MAX_PRICE_DEVIATION_BPS"
        ];
        for (uint256 i; i < fields.length; ++i) {
            vm.setEnv(fields[i], deploymentScript.input(fields[i]));
        }
        for (uint256 i; i < fields.length; ++i) {
            vm.setEnv(fields[i], "");
            vm.expectRevert();
            realScript.run();
            vm.setEnv(fields[i], deploymentScript.input(fields[i]));
        }
        assertEq(vm.getNonce(deployer), 0);
        DeployUsdcePools.Deployment memory deployed = realScript.run();
        _assertPool(deployed.primePool, TempoMainnet.PRIME, address(deployed.primeAdapter), 8, 3600, 25);
        _assertPool(deployed.usdyPool, TempoMainnet.USDY, address(deployed.usdyAdapter), 18, 90000, 50);
    }

    function test_rejectsZeroRolesAndDeployerAuthority() external {
        _rejectConfig("DEPLOYER_ADDRESS", vm.toString(address(0)), "DEPLOYER_ADDRESS");
        _rejectConfig("OWNER_ADDRESS", vm.toString(address(0)), "OWNER_ADDRESS");
        _rejectConfig("GUARDIAN_ADDRESS", vm.toString(address(0)), "GUARDIAN_ADDRESS");
        _rejectConfig("OWNER_ADDRESS", vm.toString(deployer), "deployer must have no pool authority");
        _rejectConfig("GUARDIAN_ADDRESS", vm.toString(deployer), "deployer must have no pool authority");
    }

    function test_rejectsInvalidRiskLimits() external {
        _rejectConfig("PRIME_MAX_ORACLE_AGE", "0", "PRIME_MAX_ORACLE_AGE");
        _rejectConfig("PRIME_MAX_ORACLE_AGE", vm.toString(uint256(type(uint80).max) + 1), "PRIME_MAX_ORACLE_AGE");
        _rejectConfig("USDY_MAX_ORACLE_AGE", "86399", "USDY_MAX_ORACLE_AGE");
        _rejectConfig("USDY_MAX_ORACLE_AGE", vm.toString(uint256(type(uint80).max) + 1), "USDY_MAX_ORACLE_AGE");
        _rejectConfig("PRIME_MAX_PRICE_DEVIATION_BPS", "10001", "PRIME_MAX_PRICE_DEVIATION_BPS");
        _rejectConfig("USDY_MAX_PRICE_DEVIATION_BPS", "10001", "USDY_MAX_PRICE_DEVIATION_BPS");
    }

    function test_acceptsExplicitZeroDeviationAndOneDayUsdyAge() external {
        deploymentScript.setInput("PRIME_MAX_PRICE_DEVIATION_BPS", "0");
        deploymentScript.setInput("USDY_MAX_PRICE_DEVIATION_BPS", "0");
        deploymentScript.setInput("USDY_MAX_ORACLE_AGE", "86400");
        DeployUsdcePools.Deployment memory deployed = deploymentScript.run();
        assertEq(deployed.primePool.maxPriceDeviationBps(), 0);
        assertEq(deployed.usdyPool.maxPriceDeviationBps(), 0);
        assertEq(deployed.usdyPool.maxOracleAge(), 1 days);
    }

    function test_rejectsVirtualAdministrativeAddress() external {
        MockAddressRegistry(TempoMainnet.ADDRESS_REGISTRY).setResolution(owner, makeAddr("master"));
        vm.expectRevert(abi.encodeWithSelector(DeployUsdcePools.InvalidConfig.selector, "OWNER_ADDRESS"));
        deploymentScript.run();
    }

    function test_rejectsUnexpectedTokenDecimalsOrSymbol() external {
        vm.mockCall(TempoMainnet.USDCE, abi.encodeCall(ITIP20.decimals, ()), abi.encode(uint8(18)));
        vm.expectRevert(abi.encodeWithSelector(DeployUsdcePools.UnexpectedToken.selector, TempoMainnet.USDCE));
        deploymentScript.run();
        vm.mockCall(TempoMainnet.USDCE, abi.encodeCall(ITIP20.decimals, ()), abi.encode(uint8(6)));
        vm.mockCall(TempoMainnet.USDY, abi.encodeCall(ITIP20.symbol, ()), abi.encode("WRONG"));
        vm.expectRevert(abi.encodeWithSelector(DeployUsdcePools.UnexpectedToken.selector, TempoMainnet.USDY));
        deploymentScript.run();
    }

    function test_rejectsUnexpectedPrimeFeed() external {
        vm.mockCall(
            TempoMainnet.PRIME_USD_CHAINLINK, abi.encodeCall(IAggregatorV3.description, ()), abi.encode("WRONG")
        );
        vm.expectRevert(DeployUsdcePools.UnexpectedPrimeFeed.selector);
        deploymentScript.run();
        vm.mockCall(
            TempoMainnet.PRIME_USD_CHAINLINK, abi.encodeCall(IAggregatorV3.description, ()), abi.encode("PRIME / USD")
        );
        vm.mockCall(TempoMainnet.PRIME_USD_CHAINLINK, abi.encodeCall(IAggregatorV3.decimals, ()), abi.encode(uint8(18)));
        vm.expectRevert(DeployUsdcePools.UnexpectedPrimeFeed.selector);
        deploymentScript.run();
    }

    function test_rejectsDelayedPrimeObservationDespiteFreshPublication() external {
        uint256 observedAt = block.timestamp - 3601;
        _primeRound(int256(PRIME_PRICE), observedAt, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployUsdcePools.InvalidObservation.selector,
                TempoMainnet.PRIME_USD_CHAINLINK,
                PRIME_PRICE,
                observedAt,
                uint256(3600)
            )
        );
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function test_rejectsZeroAndFuturePrimeObservation() external {
        _primeRound(0, block.timestamp, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployUsdcePools.InvalidObservation.selector,
                TempoMainnet.PRIME_USD_CHAINLINK,
                uint256(0),
                block.timestamp,
                uint256(3600)
            )
        );
        deploymentScript.run();
        _primeRound(int256(PRIME_PRICE), block.timestamp + 1, block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployUsdcePools.InvalidObservation.selector,
                TempoMainnet.PRIME_USD_CHAINLINK,
                PRIME_PRICE,
                block.timestamp + 1,
                uint256(3600)
            )
        );
        deploymentScript.run();
    }

    function test_rejectsInvalidPrimeTimestampRelationship() external {
        _primeRound(int256(PRIME_PRICE), block.timestamp, block.timestamp - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceOracleAdapter.InvalidFeedTimestamps.selector, block.timestamp, block.timestamp - 1
            )
        );
        deploymentScript.run();
    }

    function test_rejectsZeroUsdyPriceBeforeAnyBroadcast() external {
        _usdyPrice(0);
        vm.expectRevert(OndoUSDYPriceOracleAdapter.InvalidPrice.selector);
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function test_rejectsMissingOndoWrapper() external {
        vm.etch(TempoMainnet.USDY_ORACLE_WRAPPER, hex"");
        vm.expectRevert(OndoUSDYPriceOracleAdapter.InvalidWrapper.selector);
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
    }

    function _assertDonationPreserved(bool prime, bool base) internal {
        // Cross the RLP nonce boundary; local preflight probes must not shift the four broadcast CREATEs.
        vm.setNonce(deployer, 127);
        address predictedPrime = vm.computeCreateAddress(deployer, 128);
        address predictedUsdy = vm.computeCreateAddress(deployer, 130);
        address target = prime ? predictedPrime : predictedUsdy;
        address token = base ? (prime ? TempoMainnet.PRIME : TempoMainnet.USDY) : TempoMainnet.USDCE;
        address donor = makeAddr("donor");
        MockTIP20(token).mint(donor, 1);
        vm.prank(donor);
        ITIP20(token).transferWithMemo(target, 1, bytes32(0));
        assertEq(ITIP20(token).balanceOf(target), 1);
        assertEq(target.code.length, 0);

        DeployUsdcePools.Deployment memory deployed = deploymentScript.run();
        assertEq(address(deployed.primeAdapter), vm.computeCreateAddress(deployer, 127));
        assertEq(address(deployed.primePool), predictedPrime);
        assertEq(address(deployed.usdyAdapter), vm.computeCreateAddress(deployer, 129));
        assertEq(address(deployed.usdyPool), predictedUsdy);
        assertEq(vm.getNonce(deployer), 131);
        assertEq(ITIP20(token).balanceOf(target), 1);
        assertEq(ITIP20(token).balanceOf(donor), 0);
        // Clear only the fixture donation to reuse the full zero-inventory, role and anchor assertions.
        vm.prank(owner);
        DirectPropAMM(target).withdraw(token, owner, 1, bytes32(0));
        _assertPool(deployed.primePool, TempoMainnet.PRIME, address(deployed.primeAdapter), 8, 3600, 25);
        _assertPool(deployed.usdyPool, TempoMainnet.USDY, address(deployed.usdyAdapter), 18, 90000, 50);
        _assertNoDeployerAuthority(deployed.primePool);
        _assertNoDeployerAuthority(deployed.usdyPool);
    }

    function _mockToken(address token, string memory symbol) internal {
        vm.etch(token, address(new MockTIP20(symbol, 6)).code);
        vm.mockCall(token, abi.encodeCall(ITIP20.decimals, ()), abi.encode(uint8(6)));
        vm.mockCall(token, abi.encodeCall(ITIP20.symbol, ()), abi.encode(symbol));
    }

    function _primeRound(int256 price, uint256 observedAt, uint256 publishedAt) internal {
        vm.mockCall(
            TempoMainnet.PRIME_USD_CHAINLINK,
            abi.encodeCall(IAggregatorV3.latestRoundData, ()),
            abi.encode(uint80(12), price, observedAt, publishedAt, uint80(12))
        );
    }

    function _usdyPrice(uint256 price) internal {
        vm.mockCall(
            TempoMainnet.USDY_ORACLE_WRAPPER,
            abi.encodeCall(IOndoUSDYOracleWrapper.getPriceData, ()),
            abi.encode(price, block.timestamp)
        );
    }

    function _rejectConfig(string memory field, string memory value, string memory reason) internal {
        string memory previous = deploymentScript.input(field);
        deploymentScript.setInput(field, value);
        vm.expectRevert(abi.encodeWithSelector(DeployUsdcePools.InvalidConfig.selector, reason));
        deploymentScript.run();
        assertEq(vm.getNonce(deployer), 0);
        deploymentScript.setInput(field, previous);
    }

    function _assertPool(
        DirectPropAMM pool,
        address base,
        address oracle,
        uint8 decimals,
        uint256 age,
        uint16 deviation
    ) internal {
        assertEq(address(pool.baseToken()), base);
        assertEq(address(pool.quoteToken()), TempoMainnet.USDCE);
        assertEq(address(pool.oracle()), oracle);
        assertEq(address(pool.addressRegistry()), TempoMainnet.ADDRESS_REGISTRY);
        assertEq(pool.baseDecimals(), 6);
        assertEq(pool.quoteDecimals(), 6);
        assertEq(pool.oracleDecimals(), decimals);
        assertEq(pool.priceScale(), 10 ** uint256(decimals));
        assertEq(pool.owner(), owner);
        assertEq(pool.pendingOwner(), address(0));
        assertEq(pool.guardian(), guardian);
        assertEq(pool.maxOracleAge(), age);
        assertEq(pool.maxPriceDeviationBps(), deviation);
        assertTrue(pool.paused());
        assertEq(pool.baseToQuotePriceAnchor(), 0);
        assertEq(pool.quoteToBasePriceAnchor(), 0);
        assertEq(pool.baseToken().balanceOf(address(pool)), 0);
        assertEq(pool.quoteToken().balanceOf(address(pool)), 0);
        address[4] memory accounts = [deployer, owner, guardian, makeAddr("futureVault")];
        for (uint256 i; i < accounts.length; ++i) {
            assertFalse(pool.takerAllowed(accounts[i]));
            assertFalse(pool.recipientAllowed(accounts[i]));
        }
    }

    function _assertNoDeployerAuthority(DirectPropAMM pool) internal {
        vm.startPrank(deployer);
        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        pool.setTakerAllowed(deployer, true);
        vm.expectRevert(DirectPropAMM.NotOwner.selector);
        pool.unpause();
        vm.expectRevert(DirectPropAMM.NotGuardianOrOwner.selector);
        pool.pause();
        vm.stopPrank();
    }
}

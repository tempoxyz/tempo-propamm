// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { FundPool } from "../script/FundPool.s.sol";
import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockOracle } from "./mocks/MockOracle.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";

/// @dev Run the real parser and funding calls with test-specific keys, never process-global deployment inputs.
contract FundPoolHarness is FundPool {
    Config internal config;
    string internal baseKey;
    string internal quoteKey;

    constructor(Config memory config_, string memory baseKey_, string memory quoteKey_) {
        config = config_;
        baseKey = baseKey_;
        quoteKey = quoteKey_;
    }

    function _readConfig() internal view override returns (Config memory result) {
        result = config;
        result.baseAmount = _optionalUint(baseKey);
        result.quoteAmount = _optionalUint(quoteKey);
    }
}

/// @dev An unrelated target can report any tokens and accept funding without implementing the reviewed pool.
contract UnattestedFundPool {
    MockTIP20 public baseToken;
    MockTIP20 public quoteToken;
    address public owner;

    constructor(MockTIP20 base_, MockTIP20 quote_, address owner_) {
        require(owner_ != address(0), "fixture owner");
        baseToken = base_;
        quoteToken = quote_;
        owner = owner_;
    }

    function fund(address token, uint256 amount, bytes32 memo) external {
        require(MockTIP20(token).transferFromWithMemo(msg.sender, address(this), amount, memo), "fixture transfer");
    }
}

contract FundPoolTest is Test {
    MockTIP20 internal base;
    MockTIP20 internal quote;
    DirectPropAMM internal pool;

    function setUp() external {
        base = new MockTIP20("BASE", 6);
        quote = new MockTIP20("QUOTE", 6);
        pool = new DirectPropAMM(
            base,
            quote,
            new MockOracle(8, 1e8, block.timestamp),
            new MockAddressRegistry(),
            tx.origin,
            makeAddr("guardian"),
            90_000,
            50
        );
        base.mint(tx.origin, 1000);
        quote.mint(tx.origin, 1000);
    }

    function test_absentAmountsSkipBothLegs() external {
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script("absent");
        assertFalse(vm.envExists(baseKey));
        assertFalse(vm.envExists(quoteKey));
        script.run();
        _assertBalances(0, 0);
    }

    function test_validAmountsFundBothLegs() external {
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script("valid");
        vm.setEnv(baseKey, "123");
        vm.setEnv(quoteKey, "456");
        script.run();
        _assertBalances(123, 456);
    }

    function test_successExplicitlyClearsEachApproval() external {
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script("cleanup");
        vm.setEnv(baseKey, "123");
        vm.setEnv(quoteKey, "456");
        vm.expectCall(address(base), abi.encodeWithSelector(MockTIP20.approve.selector, address(pool), 0));
        vm.expectCall(address(quote), abi.encodeWithSelector(MockTIP20.approve.selector, address(pool), 0));
        script.run();
        assertEq(base.allowance(tx.origin, address(pool)), 0);
        assertEq(quote.allowance(tx.origin, address(pool)), 0);
    }

    function test_explicitZeroBaseSkipsOnlyBase() external {
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script("zeroBase");
        vm.setEnv(baseKey, "0");
        vm.setEnv(quoteKey, "456");
        script.run();
        _assertBalances(0, 456);
    }

    function test_explicitZeroQuoteSkipsOnlyQuote() external {
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script("zeroQuote");
        vm.setEnv(baseKey, "123");
        vm.setEnv(quoteKey, "0");
        script.run();
        _assertBalances(123, 0);
    }

    function test_malformedEitherAmountRejectsBeforeBroadcastOrTokenMovement() external {
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script("malformed");
        string[7] memory invalid = [
            "typo",
            "",
            " ",
            "-1",
            "1.5",
            "0xzz",
            "115792089237316195423570985008687907853269984665640564039457584007913129639936"
        ];
        for (uint256 leg; leg < 2; ++leg) {
            for (uint256 i; i < invalid.length; ++i) {
                vm.setEnv(baseKey, leg == 0 ? invalid[i] : "123");
                vm.setEnv(quoteKey, leg == 1 ? invalid[i] : "456");
                uint64 nonceBefore = vm.getNonce(tx.origin);
                vm.expectRevert();
                script.run();
                (Vm.CallerMode mode,,) = vm.readCallers();
                assertEq(uint256(mode), 0, "must reject before startBroadcast");
                assertEq(vm.getNonce(tx.origin), nonceBefore, "no broadcast transactions");
                _assertBalances(0, 0);
                assertEq(base.allowance(tx.origin, address(pool)), 0);
                assertEq(quote.allowance(tx.origin, address(pool)), 0);
            }
        }
    }

    function test_unattestedTargetRejectsBeforeApprovingItsChosenTokens() external {
        MockTIP20 victim = new MockTIP20("VICTIM", 6);
        victim.mint(tx.origin, 1000);
        UnattestedFundPool target = new UnattestedFundPool(victim, quote, tx.origin);
        FundPool.Config memory config = _config();
        config.pool = DirectPropAMM(address(target));
        _assertRejected(config, "EXPECTED_POOL_CODEHASH", "unattested");
        assertEq(victim.balanceOf(tx.origin), 1000);
        assertEq(victim.balanceOf(address(target)), 0);
        assertEq(victim.allowance(tx.origin, address(target)), 0);
    }

    function test_selfReportedOwnerAndPairDoNotAttestTarget() external {
        UnattestedFundPool target = new UnattestedFundPool(base, quote, tx.origin);
        FundPool.Config memory config = _config();
        config.pool = DirectPropAMM(address(target));
        _assertRejected(config, "EXPECTED_POOL_CODEHASH", "lookalike");
        assertEq(base.balanceOf(address(target)), 0);
        assertEq(quote.balanceOf(address(target)), 0);
    }

    function test_wrongChainRejectsBeforeBroadcast() external {
        FundPool.Config memory config = _config();
        vm.chainId(block.chainid + 1);
        _assertRejected(config, "EXPECTED_CHAIN_ID", "wrongChain");
    }

    function test_wrongOwnerRejectsBeforeBroadcast() external {
        FundPool.Config memory config = _config();
        config.owner = makeAddr("unreviewedOwner");
        _assertRejected(config, "EXPECTED_OWNER", "wrongOwner");
    }

    function test_wrongEitherTokenRejectsBeforeBroadcast() external {
        FundPool.Config memory config = _config();
        config.base = makeAddr("unreviewedBase");
        _assertRejected(config, "EXPECTED_BASE", "wrongBase");
        config = _config();
        config.quote = makeAddr("unreviewedQuote");
        _assertRejected(config, "EXPECTED_QUOTE", "wrongQuote");
    }

    function test_wrongCodehashRejectsBeforeBroadcast() external {
        FundPool.Config memory config = _config();
        config.poolCodehash = keccak256("unreviewed code");
        _assertRejected(config, "EXPECTED_POOL_CODEHASH", "wrongCodehash");
    }

    function test_missingIdentityInputsRejectBeforeBroadcast() external {
        FundPool.Config memory config = _config();
        config.chainId = 0;
        _assertRejected(config, "EXPECTED_CHAIN_ID", "missingChain");
        config = _config();
        config.owner = address(0);
        _assertRejected(config, "EXPECTED_OWNER", "missingOwner");
        config = _config();
        config.base = address(0);
        _assertRejected(config, "EXPECTED_BASE", "missingBase");
        config = _config();
        config.quote = address(0);
        _assertRejected(config, "EXPECTED_QUOTE", "missingQuote");
        config = _config();
        config.poolCodehash = bytes32(0);
        _assertRejected(config, "EXPECTED_POOL_CODEHASH", "missingCodehash");
    }

    function test_noCodeTargetRejectsBeforeBroadcast() external {
        FundPool.Config memory config = _config();
        config.pool = DirectPropAMM(makeAddr("noCode"));
        _assertRejected(config, "POOL_ADDRESS", "noCode");
    }

    function test_sameTokenPairRejectsBeforeBroadcast() external {
        FundPool.Config memory config = _config();
        config.quote = config.base;
        _assertRejected(config, "EXPECTED_QUOTE", "sameToken");
    }

    function test_replacesExistingAllowancesWithExactAmountsThenClears() external {
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script("existingAllowance");
        vm.setEnv(baseKey, "123");
        vm.setEnv(quoteKey, "456");
        vm.startPrank(tx.origin);
        assertTrue(base.approve(address(pool), type(uint256).max));
        assertTrue(quote.approve(address(pool), type(uint256).max));
        vm.stopPrank();
        vm.expectCall(address(base), abi.encodeWithSelector(MockTIP20.approve.selector, address(pool), 123));
        vm.expectCall(address(quote), abi.encodeWithSelector(MockTIP20.approve.selector, address(pool), 456));
        script.run();
        _assertBalances(123, 456);
        assertEq(base.allowance(tx.origin, address(pool)), 0);
        assertEq(quote.allowance(tx.origin, address(pool)), 0);
    }

    function test_independentlyReviewedGenericPairWithDifferentDecimals() external {
        base = new MockTIP20("OTHER_BASE", 18);
        quote = new MockTIP20("OTHER_QUOTE", 6);
        pool = new DirectPropAMM(
            base,
            quote,
            new MockOracle(8, 1e8, block.timestamp),
            new MockAddressRegistry(),
            tx.origin,
            makeAddr("guardian"),
            90_000,
            50
        );
        base.mint(tx.origin, 1000);
        quote.mint(tx.origin, 1000);
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script("genericPair");
        vm.setEnv(baseKey, "201");
        vm.setEnv(quoteKey, "202");
        script.run();
        _assertBalances(201, 202);
        assertEq(base.allowance(tx.origin, address(pool)), 0);
        assertEq(quote.allowance(tx.origin, address(pool)), 0);
    }

    function _config() internal view returns (FundPool.Config memory) {
        // This fixture deploys the genuine runtime itself; no expected value is derived from a candidate target.
        return FundPool.Config({
            pool: pool,
            chainId: block.chainid,
            owner: tx.origin,
            base: address(base),
            quote: address(quote),
            poolCodehash: address(pool).codehash,
            baseAmount: 0,
            quoteAmount: 0
        });
    }

    function _assertRejected(FundPool.Config memory config, string memory field, string memory suffix) internal {
        (FundPoolHarness script, string memory baseKey, string memory quoteKey) = _script(config, suffix);
        vm.setEnv(baseKey, "123");
        vm.setEnv(quoteKey, "456");
        uint64 nonceBefore = vm.getNonce(tx.origin);
        vm.expectRevert(abi.encodeWithSelector(FundPool.InvalidConfig.selector, field));
        script.run();
        (Vm.CallerMode mode,,) = vm.readCallers();
        assertEq(uint256(mode), 0, "must reject before startBroadcast");
        assertEq(vm.getNonce(tx.origin), nonceBefore, "no broadcast transactions");
        _assertBalances(0, 0);
        assertEq(base.allowance(tx.origin, address(config.pool)), 0);
        assertEq(quote.allowance(tx.origin, address(config.pool)), 0);
    }

    function _script(string memory suffix)
        internal
        returns (FundPoolHarness script, string memory baseKey, string memory quoteKey)
    {
        return _script(_config(), suffix);
    }

    function _script(FundPool.Config memory config, string memory suffix)
        internal
        returns (FundPoolHarness script, string memory baseKey, string memory quoteKey)
    {
        baseKey = string.concat("PROPAMM_TEST_FUND_6660_BASE_", suffix);
        quoteKey = string.concat("PROPAMM_TEST_FUND_6660_QUOTE_", suffix);
        script = new FundPoolHarness(config, baseKey, quoteKey);
    }

    function _assertBalances(uint256 baseAmount, uint256 quoteAmount) internal view {
        assertEq(base.balanceOf(address(pool)), baseAmount);
        assertEq(quote.balanceOf(address(pool)), quoteAmount);
        assertEq(base.balanceOf(tx.origin), 1000 - baseAmount);
        assertEq(quote.balanceOf(tx.origin), 1000 - quoteAmount);
        assertTrue(pool.paused());
    }
}

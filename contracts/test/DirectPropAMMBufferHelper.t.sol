// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestFeeHook, TestFeeHookLib } from "./managed/utils/TestFeeHook.sol";
using TestFeeHookLib for ManagedDirectPropAMM;

import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { DirectPropAMMBufferHelper } from "../src/DirectPropAMMBufferHelper.sol";
import { ManagedDirectPropAMM } from "../src/managed/ManagedDirectPropAMM.sol";
import { PoolFactory } from "../src/managed/PoolFactory.sol";
import { IDirectPropAMM } from "../src/interfaces/IDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { ISettler } from "../src/managed/interfaces/ISettler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockOracle } from "./mocks/MockOracle.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";

contract MockBoringVault {
    error ManageCallFailed(uint256 index, bytes reason);

    function manage(address[] memory targets, bytes[] memory data, uint256[] memory values) external {
        for (uint256 i; i < targets.length; ++i) {
            (bool success, bytes memory reason) = targets[i].call{ value: values[i] }(data[i]);
            if (!success) revert ManageCallFailed(i, reason);
        }
    }
}

contract DirectPropAMMBufferHelperTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant PRICE = 105_000_000; // 1 PRIME = 1.05 pathUSD.
    bytes32 internal constant CUSTOMER_ID = keccak256("earn-pathusd-prime-veda");

    MockTIP20 internal prime;
    MockTIP20 internal pathUsd;
    MockBoringVault internal vault;
    MockOracle internal oracle;
    DirectPropAMM internal pool;
    DirectPropAMMBufferHelper internal helper;

    function setUp() external {
        vm.warp(1_000_000);

        MockAddressRegistry registry = new MockAddressRegistry();
        prime = new MockTIP20("PRIME", 6);
        pathUsd = new MockTIP20("pathUSD", 6);
        oracle = new MockOracle(8, PRICE, block.timestamp);
        prime.setResolver(registry);
        pathUsd.setResolver(registry);

        vault = new MockBoringVault();
        pool = new DirectPropAMM(prime, pathUsd, oracle, registry, address(this), address(this), 90_000, 50);
        helper = new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(vault), CUSTOMER_ID, 50, 0, 0);

        pool.setTakerAllowed(address(vault), true);
        pool.setRecipientAllowed(address(vault), true);
        prime.mint(address(pool), 1_000_000 * UNIT);
        pathUsd.mint(address(pool), 1_000_000 * UNIT);
        pool.unpause();
    }

    function test_depositAndWithdrawLifecycleRunsFromBoringVault() external {
        uint256 depositAssets = 105 * UNIT;
        pathUsd.mint(address(vault), depositAssets);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), depositAssets);
        vault.manage(targets, data, values);

        assertEq(pathUsd.balanceOf(address(vault)), 0);
        assertEq(prime.balanceOf(address(vault)), 100 * UNIT);
        assertEq(pathUsd.allowance(address(vault), address(pool)), 0);

        uint256 redemptionAssets = 52_500_000;
        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), redemptionAssets);
        vault.manage(targets, data, values);

        assertEq(pathUsd.balanceOf(address(vault)), redemptionAssets);
        assertEq(prime.balanceOf(address(vault)), 50 * UNIT);
        assertEq(prime.allowance(address(vault), address(pool)), 0);
    }

    function test_fractionalAtomicRoundTripReturnsFullDeposit() external {
        uint256 depositAssets = 50_000;
        pathUsd.mint(address(vault), depositAssets);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), depositAssets);
        vault.manage(targets, data, values);

        uint256 baseReceived = prime.balanceOf(address(vault));
        assertEq(baseReceived, 47_619);

        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), depositAssets);
        vault.manage(targets, data, values);

        assertEq(pathUsd.balanceOf(address(vault)), depositAssets);
        assertEq(prime.balanceOf(address(vault)), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(address(vault), address(vault), CUSTOMER_ID)), 0);
    }

    function test_withdrawSwapsOnlyQuoteShortfall() external {
        uint256 redemptionAssets = 100 * UNIT;
        uint256 existingQuote = 80 * UNIT;
        uint256 shortfall = redemptionAssets - existingQuote;
        pathUsd.mint(address(vault), existingQuote);
        prime.mint(address(vault), 100 * UNIT);

        (uint256 expectedBaseIn,,) = pool.quoteExactOutput(true, shortfall);
        uint256 baseBefore = prime.balanceOf(address(vault));

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getWithdrawManageCall(address(pathUsd), redemptionAssets);
        vault.manage(targets, data, values);

        assertEq(pathUsd.balanceOf(address(vault)), redemptionAssets);
        assertEq(prime.balanceOf(address(vault)), baseBefore - expectedBaseIn);
        assertEq(prime.allowance(address(vault), address(pool)), 0);
    }

    function test_withdrawReturnsNoCallsWhenVaultHasExactQuoteBalance() external {
        uint256 redemptionAssets = 100 * UNIT;
        pathUsd.mint(address(vault), redemptionAssets);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getWithdrawManageCall(address(pathUsd), redemptionAssets);

        assertEq(targets.length, 0);
        assertEq(data.length, 0);
        assertEq(values.length, 0);
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), redemptionAssets);
    }

    function test_withdrawReturnsNoCallsWhenVaultHasExcessQuoteBalance() external {
        uint256 redemptionAssets = 100 * UNIT;
        uint256 existingQuote = 120 * UNIT;
        pathUsd.mint(address(vault), existingQuote);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getWithdrawManageCall(address(pathUsd), redemptionAssets);

        assertEq(targets.length, 0);
        assertEq(data.length, 0);
        assertEq(values.length, 0);
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), existingQuote);
    }

    function test_withdrawSucceedsWhenPoolCanCoverShortfallButNotGrossAmount() external {
        uint256 redemptionAssets = 100 * UNIT;
        uint256 existingQuote = 80 * UNIT;
        uint256 poolQuoteLiquidity = 30 * UNIT;
        pathUsd.mint(address(vault), existingQuote);
        prime.mint(address(vault), 100 * UNIT);

        pool.pause();
        pool.withdraw(
            address(pathUsd),
            address(this),
            pathUsd.balanceOf(address(pool)) - poolQuoteLiquidity,
            keccak256("CONSTRAIN_POOL_LIQUIDITY")
        );
        pool.unpause();

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getWithdrawManageCall(address(pathUsd), redemptionAssets);
        vault.manage(targets, data, values);

        assertEq(pathUsd.balanceOf(address(vault)), redemptionAssets);
        assertEq(pathUsd.balanceOf(address(pool)), poolQuoteLiquidity - (redemptionAssets - existingQuote));
    }

    function test_onlyBoringVaultNeedsPoolPermissions() external {
        pathUsd.mint(address(vault), 105 * UNIT);
        pool.setTakerAllowed(address(vault), false);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        vm.expectPartialRevert(MockBoringVault.ManageCallFailed.selector);
        vault.manage(targets, data, values);
    }

    function test_depositManageCallExpiresAfterItsConstructionBlock() external {
        uint256 depositAssets = 105 * UNIT;
        pathUsd.mint(address(vault), depositAssets);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), depositAssets);
        uint256 deadline = 1_000_000;
        vm.warp(deadline + 1);

        bytes memory poolReason =
            abi.encodeWithSelector(DirectPropAMM.DeadlineExpired.selector, deadline, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);
    }

    function test_depositManageCallAcceptsNewerTimestampAtQuotedPrice() external {
        uint256 depositAssets = 105 * UNIT;
        pathUsd.mint(address(vault), depositAssets);
        oracle.setPrice(PRICE, block.timestamp - 1);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), depositAssets);
        oracle.setPrice(PRICE, block.timestamp);

        vault.manage(targets, data, values);

        assertEq(pathUsd.balanceOf(address(vault)), 0);
        assertEq(prime.balanceOf(address(vault)), 100 * UNIT);
    }

    function test_depositManageCallBindsQuotedOraclePrice() external {
        uint256 depositAssets = 105 * UNIT;
        pathUsd.mint(address(vault), depositAssets);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), depositAssets);
        uint256 newPrice = PRICE + PRICE / pool.BPS();
        oracle.setPrice(newPrice, block.timestamp);

        bytes memory poolReason =
            abi.encodeWithSelector(DirectPropAMM.OraclePriceToleranceExceeded.selector, PRICE, newPrice, 0);
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);
    }

    function test_rejectsNonQuoteAsset() external {
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMBufferHelper.UnsupportedAsset.selector, address(prime)));
        helper.getDepositManageCall(address(prime), UNIT);
    }

    function test_directPoolKeepsItsRecipientEncoding() external view {
        assertFalse(helper.managed());
        assertEq(helper.pairIndex(), 0);
        assertEq(helper.sponsorId(), 0);
        assertEq(helper.settler(), address(0), "a DirectPropAMM has no Settler");
        (address[] memory targets, bytes[] memory data,) = helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        assertEq(targets[0], address(pathUsd));
        assertEq(targets[1], address(pathUsd));
        assertEq(targets[2], address(pool));
        assertEq(targets[3], address(pathUsd));
        assertEq(data[0], abi.encodeCall(IERC20.approve, (address(pool), 0)));
        assertEq(data[1], abi.encodeCall(IERC20.approve, (address(pool), 105 * UNIT)));
        assertEq(data[3], abi.encodeCall(IERC20.approve, (address(pool), 0)));
        (uint256 quotedOut, uint256 price, uint256 updatedAt) = pool.quoteExactInput(false, 105 * UNIT);
        bytes32 tradeId = keccak256(
            abi.encode(
                keccak256("DIRECT_PROP_VEDA_DEPOSIT"), CUSTOMER_ID, vault, 105 * UNIT, block.chainid, block.number
            )
        );
        assertEq(
            data[2],
            abi.encodeCall(
                IDirectPropAMM.swapExactInput,
                (
                    false,
                    105 * UNIT,
                    quotedOut * 9_950 / 10_000,
                    address(vault),
                    CUSTOMER_ID,
                    tradeId,
                    block.timestamp,
                    price,
                    0,
                    updatedAt
                )
            )
        );
    }

    function test_directPoolRejectsAPairIndexOrASponsorId() external {
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMBufferHelper.PairIndexUnsupported.selector, uint16(1)));
        new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(vault), CUSTOMER_ID, 50, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMBufferHelper.SponsorIdUnsupported.selector, uint64(7)));
        new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(vault), CUSTOMER_ID, 50, 0, 7);
    }

    function test_rejectsZeroAddressesAZeroCustomerAndAZeroAmount() external {
        vm.expectRevert(DirectPropAMMBufferHelper.InvalidAddress.selector);
        new DirectPropAMMBufferHelper(IDirectPropAMM(address(0)), address(vault), CUSTOMER_ID, 50, 0, 0);
        vm.expectRevert(DirectPropAMMBufferHelper.InvalidAddress.selector);
        new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(0), CUSTOMER_ID, 50, 0, 0);
        vm.expectRevert(DirectPropAMMBufferHelper.CustomerIdIsZero.selector);
        new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(vault), bytes32(0), 50, 0, 0);

        vm.expectRevert(DirectPropAMMBufferHelper.AmountIsZero.selector);
        helper.getDepositManageCall(address(pathUsd), 0);
        vm.expectRevert(DirectPropAMMBufferHelper.AmountIsZero.selector);
        helper.getWithdrawManageCall(address(pathUsd), 0);
    }

    function test_rejectsExcessiveSlippage() external {
        vm.expectRevert(abi.encodeWithSelector(DirectPropAMMBufferHelper.SlippageTooHigh.selector, 1_001, 1_000));
        new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(vault), CUSTOMER_ID, 1_001, 0, 0);
    }
}

/// @notice The helper on a `ManagedDirectPropAMM`: its manage calls name the pair and the list that admits the vault
/// and no recipient, and the swap pays the vault, its caller. The vault's pair is the pool's second, so a helper that
/// ignored `pairIndex` would trade the wrong pair.
contract ManagedDirectPropAMMBufferHelperTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant PRICE = 105_000_000; // 1 PRIME = 1.05 pathUSD.
    bytes32 internal constant CUSTOMER_ID = keccak256("earn-pathusd-prime-veda");
    /// @dev The sponsor whose list holds the vault (a fintech), and the vault's pair.
    uint64 internal constant PARTNER = 7;
    uint16 internal constant PAIR = 1;
    uint64 internal constant HOME = 0;

    address internal partner = makeAddr("partner");
    MockTIP20 internal prime;
    MockTIP20 internal pathUsd;
    MockTIP20 internal other;
    MockBoringVault internal vault;
    MockOracle internal oracle;
    ManagedDirectPropAMM internal pool;

    function setUp() external {
        vm.warp(1_000_000);
        prime = new MockTIP20("PRIME", 6);
        pathUsd = new MockTIP20("pathUSD", 6);
        other = new MockTIP20("OTHER", 6);
        oracle = new MockOracle(8, PRICE, block.timestamp);
        vault = new MockBoringVault();
        pool = new ManagedDirectPropAMM(address(this), address(0));
        // Pair 0 trades another token against pathUSD at another price; the vault's pair is 1.
        pool.addPair(address(other), address(pathUsd), new MockOracle(8, 2 * PRICE, block.timestamp), 90_000, 50);
        assertEq(pool.addPair(address(prime), address(pathUsd), oracle, 90_000, 50), PAIR);
        pool.addSponsor(PARTNER, partner);
        pool.setPairSponsor(PAIR, PARTNER, true);
        vm.prank(partner);
        pool.setMembers(PAIR, PARTNER, _one(address(vault)), true);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        pool.setPairAccess(PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        prime.mint(address(pool), 1_000_000 * UNIT);
        pathUsd.mint(address(pool), 1_000_000 * UNIT);
        other.mint(address(pool), 1_000_000 * UNIT);
        pool.unpause();
    }

    function test_detectsTheManagedPoolAndStoresThePairAndTheSponsor() external {
        DirectPropAMMBufferHelper helper = _helper(PARTNER);
        assertTrue(helper.managed());
        assertEq(helper.pairIndex(), PAIR);
        assertEq(helper.sponsorId(), PARTNER);
        assertEq(helper.baseToken(), address(prime));
        assertEq(helper.quoteToken(), address(pathUsd));
        assertEq(address(helper.pool()), address(pool));
        assertTrue(_helper(HOME).managed());
    }

    /// @dev An unknown or removed pair reads all zero, which the helper refuses.
    function test_rejectsAPairThatIsNotLive() external {
        vm.expectRevert(DirectPropAMMBufferHelper.InvalidPair.selector);
        new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(vault), CUSTOMER_ID, 50, 9, HOME);
        pool.removePair(0);
        vm.expectRevert(DirectPropAMMBufferHelper.InvalidPair.selector);
        new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(vault), CUSTOMER_ID, 50, 0, HOME);
    }

    /// @dev Both manage calls encode the managed swaps with the pair first and the sponsor in the recipient's place.
    function test_manageCallsNameThePairAndTheSponsorAndNoRecipient() external {
        DirectPropAMMBufferHelper helper = _helper(PARTNER);
        (, bytes[] memory data,) = helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        (uint256 quotedOut, uint256 price, uint256 updatedAt) =
            pool.quoteExactInput(PAIR, address(vault), false, 105 * UNIT);
        assertEq(quotedOut, 100 * UNIT, "the vault's pair's price");
        assertEq(
            data[2],
            abi.encodeCall(
                IManagedDirectPropAMM.swapExactInput,
                (
                    PAIR,
                    false,
                    105 * UNIT,
                    quotedOut * 9_950 / 10_000,
                    PARTNER,
                    CUSTOMER_ID,
                    _tradeId("DIRECT_PROP_VEDA_DEPOSIT", 105 * UNIT),
                    block.timestamp,
                    price,
                    0,
                    updatedAt
                )
            )
        );

        (, data,) = helper.getWithdrawManageCall(address(pathUsd), 21 * UNIT);
        uint256 quotedIn;
        (quotedIn, price, updatedAt) = pool.quoteExactOutput(PAIR, address(vault), true, 21 * UNIT);
        assertEq(
            data[2],
            abi.encodeCall(
                IManagedDirectPropAMM.swapExactOutput,
                (
                    PAIR,
                    true,
                    21 * UNIT,
                    (quotedIn * 10_050 + 9_999) / 10_000,
                    PARTNER,
                    CUSTOMER_ID,
                    _tradeId("DIRECT_PROP_VEDA_WITHDRAW", 21 * UNIT),
                    block.timestamp,
                    price,
                    0,
                    updatedAt
                )
            )
        );
    }

    /// @dev No Settler fills a standalone pool (`factory() == 0`), so its helper keeps `settler() == 0` and the direct
    /// batch byte for byte: the vault approves and calls the pool. A settler the owner sets later changes nothing.
    function test_standalonePoolKeepsTheDirectBatch() external {
        DirectPropAMMBufferHelper helper = _helper(PARTNER);
        assertEq(pool.factory(), address(0));
        assertEq(helper.settler(), address(0));
        prime.mint(address(vault), 100 * UNIT);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        (uint256 quoted, uint256 price, uint256 updatedAt) =
            pool.quoteExactInput(PAIR, address(vault), false, 105 * UNIT);
        bytes memory swap = abi.encodeCall(
            IManagedDirectPropAMM.swapExactInput,
            (
                PAIR,
                false,
                105 * UNIT,
                quoted * 9_950 / 10_000,
                PARTNER,
                CUSTOMER_ID,
                _tradeId("DIRECT_PROP_VEDA_DEPOSIT", 105 * UNIT),
                block.timestamp,
                price,
                0,
                updatedAt
            )
        );
        bytes memory deposit = abi.encode(targets, data, values);
        assertEq(deposit, _directBatch(address(pathUsd), 105 * UNIT, swap));

        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 21 * UNIT);
        (quoted, price, updatedAt) = pool.quoteExactOutput(PAIR, address(vault), true, 21 * UNIT);
        uint256 maximumBaseIn = (quoted * 10_050 + 9_999) / 10_000;
        swap = abi.encodeCall(
            IManagedDirectPropAMM.swapExactOutput,
            (
                PAIR,
                true,
                21 * UNIT,
                maximumBaseIn,
                PARTNER,
                CUSTOMER_ID,
                _tradeId("DIRECT_PROP_VEDA_WITHDRAW", 21 * UNIT),
                block.timestamp,
                price,
                0,
                updatedAt
            )
        );
        bytes memory withdrawal = abi.encode(targets, data, values);
        assertEq(withdrawal, _directBatch(address(prime), maximumBaseIn, swap));

        pool.setSettler(makeAddr("settler"));
        (targets, data, values) = helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        assertEq(abi.encode(targets, data, values), deposit);
        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 21 * UNIT);
        assertEq(abi.encode(targets, data, values), withdrawal);
        assertEq(_helper(PARTNER).settler(), address(0), "a standalone pool's settler is not the vault's");
    }

    /// @dev Under the partner's list, and then under the home list, a deposit and a withdrawal run from the vault,
    /// pay the vault and leave no allowance; the route's credit is the vault's own, on its pair.
    function test_depositAndWithdrawRunFromTheVault() external {
        pool.setMembers(PAIR, HOME, _one(address(vault)), true);
        uint64[2] memory sponsors = [PARTNER, HOME];
        for (uint256 i; i < sponsors.length; ++i) {
            DirectPropAMMBufferHelper helper = _helper(sponsors[i]);
            pathUsd.mint(address(vault), 105 * UNIT);
            uint256 primeBefore = prime.balanceOf(address(vault));
            (address[] memory targets, bytes[] memory data, uint256[] memory values) =
                helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
            vault.manage(targets, data, values);
            assertEq(pathUsd.balanceOf(address(vault)), 0);
            assertEq(prime.balanceOf(address(vault)), primeBefore + 100 * UNIT);
            assertEq(pathUsd.allowance(address(vault), address(pool)), 0);

            (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 52_500_000);
            vault.manage(targets, data, values);
            assertEq(pathUsd.balanceOf(address(vault)), 52_500_000);
            assertEq(prime.balanceOf(address(vault)), primeBefore + 50 * UNIT);
            assertEq(prime.allowance(address(vault), address(pool)), 0);
            vm.prank(address(vault));
            pathUsd.transferWithMemo(address(this), 52_500_000, bytes32(0));
        }
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PAIR, address(vault), CUSTOMER_ID)), 0);
        assertEq(other.balanceOf(address(vault)), 0, "the other pair never traded");
    }

    function test_unsetVaultStaysFeeFreeWhenHelperAndCallerHaveFees() external {
        DirectPropAMMBufferHelper helper = _helper(PARTNER);
        address caller = makeAddr("fee-paying-teller");
        (address[] memory targets, bytes[] memory expected, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        pool.closePair(PAIR);
        pool.configureFees(PAIR, address(helper), 1_000, 1_000);
        pool.configureFees(PAIR, caller, 500, 500);
        pool.setPairAccess(PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        vm.prank(caller);
        (, bytes[] memory data,) = helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        assertEq(abi.encode(data), abi.encode(expected), "other takers must not change the vault quote");
        pathUsd.mint(address(vault), 105 * UNIT);
        vault.manage(targets, data, values);
        assertEq(prime.balanceOf(address(vault)), 100 * UNIT);
        vm.prank(caller);
        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 105 * UNIT);
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), 105 * UNIT);
        assertEq(prime.balanceOf(address(vault)), 0);
        assertEq(pathUsd.allowance(address(vault), address(pool)), 0);
        assertEq(prime.allowance(address(vault), address(pool)), 0);
        (uint16 sell, uint16 buy) = pool.testFees(PAIR, address(vault));
        assertEq(sell, 0);
        assertEq(buy, 0);
    }

    function test_managedHelpersUseVaultFeesNotHelperCallerOrOtherPair() external {
        DirectPropAMMBufferHelper helper = _helper(PARTNER);
        address caller = makeAddr("teller");
        pool.closePair(PAIR);
        pool.configureFees(PAIR, address(vault), 500, 1_000);
        pool.configureFees(PAIR, address(helper), 100, 100);
        pool.configureFees(PAIR, caller, 200, 200);
        pool.setPairAccess(PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        pool.closePair(0);
        pool.configureFees(0, address(vault), 750, 750);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);

        pathUsd.mint(address(vault), 105 * UNIT);
        vm.prank(caller);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        assertEq(
            data[2],
            abi.encodeCall(
                IManagedDirectPropAMM.swapExactInput,
                (
                    PAIR,
                    false,
                    105 * UNIT,
                    90 * UNIT * 9_950 / 10_000,
                    PARTNER,
                    CUSTOMER_ID,
                    _tradeId("DIRECT_PROP_VEDA_DEPOSIT", 105 * UNIT),
                    block.timestamp,
                    PRICE,
                    0,
                    block.timestamp
                )
            )
        );
        vault.manage(targets, data, values);
        assertEq(prime.balanceOf(address(vault)), 90 * UNIT);
        assertEq(pathUsd.balanceOf(address(vault)), 0);
        assertEq(pathUsd.allowance(address(vault), address(pool)), 0);

        pathUsd.mint(address(vault), 5 * UNIT);
        uint256 gross = (20 * UNIT * 10_000 + 9_499) / 9_500;
        uint256 maximum = (gross * 10_050 + 9_999) / 10_000;
        vm.prank(caller);
        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 26 * UNIT);
        assertEq(
            data[2],
            abi.encodeCall(
                IManagedDirectPropAMM.swapExactOutput,
                (
                    PAIR,
                    true,
                    21 * UNIT,
                    maximum,
                    PARTNER,
                    CUSTOMER_ID,
                    _tradeId("DIRECT_PROP_VEDA_WITHDRAW", 21 * UNIT),
                    block.timestamp,
                    PRICE,
                    0,
                    block.timestamp
                )
            )
        );
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), 26 * UNIT);
        assertEq(prime.balanceOf(address(vault)), 90 * UNIT - gross);
        assertEq(prime.allowance(address(vault), address(pool)), 0);
        assertEq(prime.balanceOf(address(helper)), 0);
        assertEq(prime.balanceOf(caller), 0);
        assertEq(other.balanceOf(address(vault)), 0);
        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 26 * UNIT);
        assertEq(targets.length, 0, "existing quote inventory needs no fee-bearing trade");
        assertEq(data.length, 0);
        assertEq(values.length, 0);
    }

    /// @dev A sponsor switched off, or removed from the pair, rejects the vault's next manage call at the swap with
    /// the pool's reason; restoring it restores the vault.
    function test_aSponsorSwitchedOffOrRemovedRejectsTheManageCall() external {
        DirectPropAMMBufferHelper helper = _helper(PARTNER);
        pathUsd.mint(address(vault), 210 * UNIT);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);

        pool.setSponsorEnabled(PARTNER, false);
        bytes memory poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.SponsorDisabled.selector, PARTNER);
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);
        pool.setSponsorEnabled(PARTNER, true);

        pool.setPairSponsor(PAIR, PARTNER, false);
        poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.SponsorNotAdmitted.selector, PAIR, PARTNER);
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);

        pool.setPairSponsor(PAIR, PARTNER, true);
        vault.manage(targets, data, values);
        assertEq(prime.balanceOf(address(vault)), 100 * UNIT);
    }

    /// @dev Under the home list, the vault must be on the pair's home list.
    function test_homeListMustAdmitTheVault() external {
        DirectPropAMMBufferHelper helper = _helper(HOME);
        pathUsd.mint(address(vault), 105 * UNIT);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        bytes memory poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.TakerNotAllowed.selector, address(vault));
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);
        assertEq(
            uint8(pool.takerAccess(PAIR, address(vault), HOME)), uint8(IManagedDirectPropAMM.TakerAccess.NotListed)
        );
    }

    /// @dev The helper reads no access when it builds a call: quotes still succeed for a closed pair or an
    /// unregistered sponsor id, and the swap the call encodes reverts with the pool's reason.
    function test_theSwapNotTheQuoteChecksAccess() external {
        pathUsd.mint(address(vault), 105 * UNIT);
        DirectPropAMMBufferHelper unknown = _helper(42);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            unknown.getDepositManageCall(address(pathUsd), 105 * UNIT);
        bytes memory poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.UnknownSponsor.selector, uint64(42));
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);

        DirectPropAMMBufferHelper helper = _helper(PARTNER);
        pool.closePair(PAIR);
        pathUsd.mint(address(vault), 105 * UNIT);
        (targets, data, values) = helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.TakerNotAllowed.selector, address(vault));
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);
    }

    /// @dev The vault's rounding credit accrues on its own pair's route, never on another pair's.
    function test_roundingCreditIsKeyedToTheVaultsPair() external {
        DirectPropAMMBufferHelper helper = _helper(PARTNER);
        pathUsd.mint(address(vault), 50_000);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 50_000);
        vault.manage(targets, data, values);
        assertEq(prime.balanceOf(address(vault)), 47_619);
        assertGt(pool.roundingCredit(pool.roundingRouteKey(PAIR, address(vault), CUSTOMER_ID)), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(0, address(vault), CUSTOMER_ID)), 0);

        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 50_000);
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), 50_000, "the round trip returns the full deposit");
        assertEq(prime.balanceOf(address(vault)), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(PAIR, address(vault), CUSTOMER_ID)), 0);
    }

    function _helper(uint64 sponsorId) internal returns (DirectPropAMMBufferHelper) {
        return new DirectPropAMMBufferHelper(
            IDirectPropAMM(address(pool)), address(vault), CUSTOMER_ID, 50, PAIR, sponsorId
        );
    }

    /// @dev The direct batch: clear the pool's allowance, approve it, swap on it, clear again.
    function _directBatch(address token, uint256 approved, bytes memory swap) internal view returns (bytes memory) {
        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        (targets[0], targets[1], targets[2], targets[3]) = (token, token, address(pool), token);
        data[0] = abi.encodeCall(IERC20.approve, (address(pool), 0));
        data[1] = abi.encodeCall(IERC20.approve, (address(pool), approved));
        data[2] = swap;
        data[3] = data[0];
        return abi.encode(targets, data, new uint256[](4));
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _tradeId(string memory operation, uint256 amount) internal view returns (bytes32) {
        return keccak256(
            abi.encode(keccak256(bytes(operation)), CUSTOMER_ID, address(vault), amount, block.chainid, block.number)
        );
    }
}

/// @notice The helper on a `ManagedDirectPropAMM` a `PoolFactory` created: the vault approves and calls the factory's
/// default Settler, which fills the pool with the vault, its caller, as the taker. `twin` is a standalone pool
/// configured alike, whose helper keeps the direct swaps: both paths must move the same amounts and leave the same
/// route credit.
contract FactoryPoolBufferHelperTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant PRICE = 105_000_000; // 1 PRIME = 1.05 pathUSD.
    bytes32 internal constant CUSTOMER_ID = keccak256("earn-pathusd-prime-veda");
    uint64 internal constant PARTNER = 7;
    uint16 internal constant PAIR = 1;
    uint64 internal constant HOME = 0;

    address internal partner = makeAddr("partner");
    address internal replacement = makeAddr("replacement settler");
    MockTIP20 internal prime;
    MockTIP20 internal pathUsd;
    MockTIP20 internal other;
    MockOracle internal oracle;
    PoolFactory internal factory;
    address internal settler;
    ManagedDirectPropAMM internal pool;
    MockBoringVault internal vault;
    ManagedDirectPropAMM internal twin;
    MockBoringVault internal twinVault;

    function setUp() external {
        vm.warp(1_000_000);
        prime = new MockTIP20("PRIME", 6);
        pathUsd = new MockTIP20("pathUSD", 6);
        other = new MockTIP20("OTHER", 6);
        oracle = new MockOracle(8, PRICE, block.timestamp);
        vault = new MockBoringVault();
        twinVault = new MockBoringVault();
        factory = new PoolFactory();
        settler = factory.defaultSettler();
        pool = ManagedDirectPropAMM(factory.createPool(address(this), bytes32("vault pool")));
        twin = new ManagedDirectPropAMM(address(this), address(0));
        _configure(pool, vault);
        _configure(twin, twinVault);
    }

    function test_factoryPoolUsesItsFactorysDefaultSettler() external {
        DirectPropAMMBufferHelper helper = _helper(pool, vault, PARTNER);
        assertTrue(helper.managed());
        assertEq(helper.pairIndex(), PAIR);
        assertEq(helper.sponsorId(), PARTNER);
        assertEq(pool.factory(), address(factory));
        assertTrue(factory.isPool(address(pool)));
        assertTrue(settler != address(0));
        assertEq(helper.settler(), settler);
        assertEq(helper.settler(), factory.defaultSettler());
        assertEq(helper.settler(), pool.settler());
    }

    /// @dev Both batches approve and call the Settler, never the pool, and the Settler's swap carries the fields the
    /// direct call carries: the twin's helper, built for the same vault, encodes the same values as a direct swap.
    function test_manageCallsApproveAndCallTheSettlerWithTheDirectSwapsFields() external {
        DirectPropAMMBufferHelper helper = _helper(pool, vault, PARTNER);
        DirectPropAMMBufferHelper direct = _helper(twin, vault, PARTNER);
        prime.mint(address(vault), 100 * UNIT);

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        (uint256 quoted, uint256 price, uint256 updatedAt) =
            pool.quoteExactInput(PAIR, address(vault), false, 105 * UNIT);
        assertEq(quoted, 100 * UNIT);
        IManagedDirectPropAMM.SwapParams memory params = IManagedDirectPropAMM.SwapParams({
            pairIndex: PAIR,
            baseToQuote: false,
            exactInput: true,
            amount: 105 * UNIT,
            limit: quoted * 9_950 / 10_000,
            sponsorId: PARTNER,
            customerId: CUSTOMER_ID,
            tradeId: _tradeId("DIRECT_PROP_VEDA_DEPOSIT", 105 * UNIT),
            deadline: block.timestamp,
            expectedOraclePrice: price,
            oraclePriceToleranceBps: 0,
            minimumOracleUpdatedAt: updatedAt
        });
        assertEq(abi.encode(targets, data, values), _settlerBatch(address(pathUsd), 105 * UNIT, params));
        (, data,) = direct.getDepositManageCall(address(pathUsd), 105 * UNIT);
        assertEq(data[2], _directSwap(params));

        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 21 * UNIT);
        (quoted, price, updatedAt) = pool.quoteExactOutput(PAIR, address(vault), true, 21 * UNIT);
        params.baseToQuote = true;
        params.exactInput = false;
        params.amount = 21 * UNIT;
        params.limit = (quoted * 10_050 + 9_999) / 10_000;
        params.tradeId = _tradeId("DIRECT_PROP_VEDA_WITHDRAW", 21 * UNIT);
        params.expectedOraclePrice = price;
        params.minimumOracleUpdatedAt = updatedAt;
        assertEq(abi.encode(targets, data, values), _settlerBatch(address(prime), params.limit, params));
        (, data,) = direct.getWithdrawManageCall(address(pathUsd), 21 * UNIT);
        assertEq(data[2], _directSwap(params));
    }

    /// @dev Under the partner's list, then the home list: the vault runs each batch, the pool's trade names the vault
    /// as its taker, vault and pool change by exactly the swap's amounts, no allowance is left to the Settler or the
    /// pool, and the Settler holds nothing.
    function test_depositAndWithdrawSettleThroughTheSettler() external {
        pool.setMembers(PAIR, HOME, _one(address(vault)), true);
        uint64[2] memory sponsors = [PARTNER, HOME];
        for (uint256 i; i < sponsors.length; ++i) {
            DirectPropAMMBufferHelper helper = _helper(pool, vault, sponsors[i]);
            pathUsd.mint(address(vault), 105 * UNIT);
            uint256 poolPrime = prime.balanceOf(address(pool));
            uint256 poolQuote = pathUsd.balanceOf(address(pool));
            (address[] memory targets, bytes[] memory data, uint256[] memory values) =
                helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
            vm.expectEmit(address(pool));
            emit IManagedDirectPropAMM.TradeExecuted(
                PAIR,
                address(vault),
                CUSTOMER_ID,
                sponsors[i],
                _tradeId("DIRECT_PROP_VEDA_DEPOSIT", 105 * UNIT),
                address(pathUsd),
                address(prime),
                105 * UNIT,
                100 * UNIT,
                PRICE,
                block.timestamp
            );
            vault.manage(targets, data, values);
            assertEq(pathUsd.balanceOf(address(vault)), 0);
            assertEq(prime.balanceOf(address(vault)), 100 * UNIT);
            assertEq(pathUsd.balanceOf(address(pool)), poolQuote + 105 * UNIT);
            assertEq(prime.balanceOf(address(pool)), poolPrime - 100 * UNIT);
            _assertNothingLeftBehind();

            (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 52_500_000);
            vm.expectEmit(address(pool));
            emit IManagedDirectPropAMM.TradeExecuted(
                PAIR,
                address(vault),
                CUSTOMER_ID,
                sponsors[i],
                _tradeId("DIRECT_PROP_VEDA_WITHDRAW", 52_500_000),
                address(prime),
                address(pathUsd),
                50 * UNIT,
                52_500_000,
                PRICE,
                block.timestamp
            );
            vault.manage(targets, data, values);
            assertEq(pathUsd.balanceOf(address(vault)), 52_500_000);
            assertEq(prime.balanceOf(address(vault)), 50 * UNIT);
            assertEq(pathUsd.balanceOf(address(pool)), poolQuote + 52_500_000);
            assertEq(prime.balanceOf(address(pool)), poolPrime - 50 * UNIT);
            _assertNothingLeftBehind();

            _payOut(vault, pathUsd, 52_500_000);
            _payOut(vault, prime, 50 * UNIT);
        }
        assertEq(other.balanceOf(address(vault)), 0, "the other pair never traded");
    }

    /// @dev Fractional deposits and shortfall redemptions leave the route `(pairIndex, vault, customerId)` the credit
    /// the direct path leaves its own vault, step by step, and the same balances. No other route holds credit.
    function test_routeCreditAccruesToTheVaultAsOnTheDirectPath() external {
        DirectPropAMMBufferHelper helper = _helper(pool, vault, PARTNER);
        DirectPropAMMBufferHelper direct = _helper(twin, twinVault, PARTNER);
        uint256[5] memory amounts = [uint256(50_000), 33_333, 20_001, 7, 63_339];
        bool[5] memory deposits = [true, true, false, true, false];
        bool accrued;
        for (uint256 i; i < amounts.length; ++i) {
            _run(helper, vault, deposits[i], amounts[i]);
            _run(direct, twinVault, deposits[i], amounts[i]);
            uint256 credit = pool.roundingCredit(pool.roundingRouteKey(PAIR, address(vault), CUSTOMER_ID));
            assertEq(credit, twin.roundingCredit(twin.roundingRouteKey(PAIR, address(twinVault), CUSTOMER_ID)));
            accrued = accrued || credit != 0;
            assertEq(prime.balanceOf(address(vault)), prime.balanceOf(address(twinVault)));
            assertEq(pathUsd.balanceOf(address(vault)), pathUsd.balanceOf(address(twinVault)));
            assertEq(prime.balanceOf(address(pool)), prime.balanceOf(address(twin)));
            assertEq(pathUsd.balanceOf(address(pool)), pathUsd.balanceOf(address(twin)));
            assertEq(pool.roundingCredit(pool.roundingRouteKey(PAIR, settler, CUSTOMER_ID)), 0);
            assertEq(pool.roundingCredit(pool.roundingRouteKey(PAIR, address(helper), CUSTOMER_ID)), 0);
            assertEq(pool.roundingCredit(pool.roundingRouteKey(0, address(vault), CUSTOMER_ID)), 0);
            _assertNothingLeftBehind();
        }
        assertTrue(accrued, "the sequence must exercise a nonzero credit");
        assertEq(prime.balanceOf(address(vault)), 0, "the round trip returns every deposit");
    }

    /// @dev The Settler passes its caller as the taker, so the pool's access check is the vault's own: listing the
    /// Settler admits nobody, and a denial of the vault stops its batch.
    function test_theVaultNotTheSettlerIsTheTaker() external {
        DirectPropAMMBufferHelper helper = _helper(pool, vault, HOME);
        pathUsd.mint(address(vault), 105 * UNIT);
        pool.setMembers(PAIR, HOME, _one(settler), true);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        bytes memory poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.TakerNotAllowed.selector, address(vault));
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);

        pool.setMembers(PAIR, HOME, _one(address(vault)), true);
        pool.setDenied(_one(address(vault)), true);
        poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.TakerDenied.selector, address(vault));
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);

        pool.setDenied(_one(address(vault)), false);
        vault.manage(targets, data, values);
        assertEq(prime.balanceOf(address(vault)), 100 * UNIT);
        _assertNothingLeftBehind();
    }

    function test_withdrawalCoveredByVaultInventoryReturnsNoCalls() external {
        DirectPropAMMBufferHelper helper = _helper(pool, vault, PARTNER);
        pathUsd.mint(address(vault), 100 * UNIT);
        prime.mint(address(vault), 100 * UNIT);
        uint256[2] memory redemptions = [100 * UNIT, 99 * UNIT];
        for (uint256 i; i < redemptions.length; ++i) {
            (address[] memory targets, bytes[] memory data, uint256[] memory values) =
                helper.getWithdrawManageCall(address(pathUsd), redemptions[i]);
            assertEq(targets.length, 0);
            assertEq(data.length, 0);
            assertEq(values.length, 0);
            vault.manage(targets, data, values);
        }
        assertEq(pathUsd.balanceOf(address(vault)), 100 * UNIT);
        assertEq(prime.balanceOf(address(vault)), 100 * UNIT);
    }

    /// @dev On a hooked pair the limits come from the vault's fee-inclusive quotes, not the Settler's, the helper's
    /// or the caller's rates, and the fee stays in the pool.
    function test_hookedPairQuotesTheVaultsFeesThroughTheSettler() external {
        DirectPropAMMBufferHelper helper = _helper(pool, vault, PARTNER);
        address caller = makeAddr("teller");
        pool.closePair(PAIR);
        pool.configureFees(PAIR, address(vault), 500, 1_000);
        pool.configureFees(PAIR, settler, 300, 300);
        pool.configureFees(PAIR, address(helper), 100, 100);
        pool.configureFees(PAIR, caller, 200, 200);
        pool.setPairAccess(PAIR, IManagedDirectPropAMM.AccessMode.Listed);

        pathUsd.mint(address(vault), 105 * UNIT);
        uint256 poolPrime = prime.balanceOf(address(pool));
        vm.prank(caller);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        IManagedDirectPropAMM.SwapParams memory params = IManagedDirectPropAMM.SwapParams({
            pairIndex: PAIR,
            baseToQuote: false,
            exactInput: true,
            amount: 105 * UNIT,
            limit: 90 * UNIT * 9_950 / 10_000,
            sponsorId: PARTNER,
            customerId: CUSTOMER_ID,
            tradeId: _tradeId("DIRECT_PROP_VEDA_DEPOSIT", 105 * UNIT),
            deadline: block.timestamp,
            expectedOraclePrice: PRICE,
            oraclePriceToleranceBps: 0,
            minimumOracleUpdatedAt: block.timestamp
        });
        assertEq(data[2], abi.encodeCall(ISettler.swap, (address(pool), params)));
        vault.manage(targets, data, values);
        assertEq(prime.balanceOf(address(vault)), 90 * UNIT);
        assertEq(pathUsd.balanceOf(address(vault)), 0);
        _assertNothingLeftBehind();

        pathUsd.mint(address(vault), 5 * UNIT);
        uint256 gross = (20 * UNIT * 10_000 + 9_499) / 9_500;
        vm.prank(caller);
        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 26 * UNIT);
        params.baseToQuote = true;
        params.exactInput = false;
        params.amount = 21 * UNIT;
        params.limit = (gross * 10_050 + 9_999) / 10_000;
        params.tradeId = _tradeId("DIRECT_PROP_VEDA_WITHDRAW", 21 * UNIT);
        assertEq(abi.encode(targets, data, values), _settlerBatch(address(prime), params.limit, params));
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), 26 * UNIT);
        assertEq(prime.balanceOf(address(vault)), 90 * UNIT - gross);
        assertEq(prime.balanceOf(address(pool)), poolPrime - 90 * UNIT + gross, "the fee stays in the pool");
        _assertNothingLeftBehind();
    }

    /// @dev After the owner's `setSettler` both builders still return the Settler batch, naming the factory's default
    /// and never the replacement. The pool refuses that Settler's fill (`NotSettler`), so the vault's batch reverts as
    /// a whole with every balance, allowance and route credit unchanged. A redemption the vault's own inventory covers
    /// still returns no calls. Selecting the default again restores both swaps.
    function test_aReplacedSettlerRevertsTheSwapWithNothingMoved() external {
        DirectPropAMMBufferHelper helper = _helper(pool, vault, PARTNER);
        pathUsd.mint(address(vault), 105 * UNIT);
        prime.mint(address(vault), 100 * UNIT);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        bytes memory depositBatch = abi.encode(targets, data, values);

        pool.setSettler(replacement);
        assertEq(helper.settler(), settler);
        uint256[5] memory held = _holdings();
        (targets, data, values) = helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        assertEq(
            abi.encode(targets, data, values), depositBatch, "the deposit batch does not follow the pool's settler"
        );
        assertEq(targets[2], settler);
        assertEq(data[1], abi.encodeCall(IERC20.approve, (settler, 105 * UNIT)));

        bytes memory poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.NotSettler.selector);
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);
        _assertNothingMoved(held);

        // A redemption of 126 pathUSD from a vault holding 105: the shortfall's batch is the Settler's too.
        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 126 * UNIT);
        (uint256 quoted, uint256 price, uint256 updatedAt) =
            pool.quoteExactOutput(PAIR, address(vault), true, 21 * UNIT);
        IManagedDirectPropAMM.SwapParams memory params = IManagedDirectPropAMM.SwapParams({
            pairIndex: PAIR,
            baseToQuote: true,
            exactInput: false,
            amount: 21 * UNIT,
            limit: (quoted * 10_050 + 9_999) / 10_000,
            sponsorId: PARTNER,
            customerId: CUSTOMER_ID,
            tradeId: _tradeId("DIRECT_PROP_VEDA_WITHDRAW", 21 * UNIT),
            deadline: block.timestamp,
            expectedOraclePrice: price,
            oraclePriceToleranceBps: 0,
            minimumOracleUpdatedAt: updatedAt
        });
        assertEq(abi.encode(targets, data, values), _settlerBatch(address(prime), params.limit, params));
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);
        _assertNothingMoved(held);

        (address[] memory none,,) = helper.getWithdrawManageCall(address(pathUsd), 105 * UNIT);
        assertEq(none.length, 0, "existing quote inventory needs no swap");

        pool.setSettler(settler);
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), 126 * UNIT);
        assertEq(prime.balanceOf(address(vault)), 80 * UNIT);
        (targets, data, values) = helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), 21 * UNIT);
        assertEq(prime.balanceOf(address(vault)), 180 * UNIT);
        _assertNothingLeftBehind();
    }

    /// @dev A helper built on a factory pool whose owner already selected another settler still names the factory's
    /// default, never the replacement: its batch reverts at the swap with the pool's `NotSettler` and nothing moved,
    /// and settles once the owner selects the default again.
    function test_constructionOnAReplacedSettlerKeepsTheFactoryDefault() external {
        pool.setSettler(replacement);
        DirectPropAMMBufferHelper helper = _helper(pool, vault, PARTNER);
        assertEq(helper.settler(), settler);
        assertEq(helper.settler(), factory.defaultSettler());
        assertEq(pool.settler(), replacement);

        pathUsd.mint(address(vault), 105 * UNIT);
        uint256[5] memory held = _holdings();
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);
        assertEq(targets[2], settler);
        assertEq(data[1], abi.encodeCall(IERC20.approve, (settler, 105 * UNIT)));
        bytes memory poolReason = abi.encodeWithSelector(IManagedDirectPropAMM.NotSettler.selector);
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, poolReason));
        vault.manage(targets, data, values);
        _assertNothingMoved(held);

        pool.setSettler(settler);
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), 0);
        assertEq(prime.balanceOf(address(vault)), 100 * UNIT);
        _assertNothingLeftBehind();
    }

    /// @dev The Settler's swap keeps the direct call's deadline (the construction block's timestamp) and its binding
    /// to the quoted oracle price.
    function test_settlerSwapKeepsTheDeadlineAndTheOracleBinding() external {
        DirectPropAMMBufferHelper helper = _helper(pool, vault, PARTNER);
        pathUsd.mint(address(vault), 105 * UNIT);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 105 * UNIT);

        uint256 newPrice = PRICE + PRICE / 10_000;
        oracle.setPrice(newPrice, block.timestamp);
        bytes memory reason =
            abi.encodeWithSelector(IManagedDirectPropAMM.OraclePriceToleranceExceeded.selector, PRICE, newPrice, 0);
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, reason));
        vault.manage(targets, data, values);
        oracle.setPrice(PRICE, block.timestamp);

        uint256 deadline = 1_000_000;
        vm.warp(deadline + 1);
        reason = abi.encodeWithSelector(IManagedDirectPropAMM.DeadlineExpired.selector, deadline, deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(MockBoringVault.ManageCallFailed.selector, 2, reason));
        vault.manage(targets, data, values);
        assertEq(pathUsd.balanceOf(address(vault)), 105 * UNIT);
        _assertNothingLeftBehind();
    }

    /// @dev The same pairs, lists, inventory and oracle on either pool, with `account` on the partner's list.
    function _configure(ManagedDirectPropAMM target, MockBoringVault account) internal {
        // Pair 0 trades another token against pathUSD at another price; the vault's pair is 1.
        target.addPair(address(other), address(pathUsd), new MockOracle(8, 2 * PRICE, block.timestamp), 90_000, 50);
        assertEq(target.addPair(address(prime), address(pathUsd), oracle, 90_000, 50), PAIR);
        target.addSponsor(PARTNER, partner);
        target.setPairSponsor(PAIR, PARTNER, true);
        vm.prank(partner);
        target.setMembers(PAIR, PARTNER, _one(address(account)), true);
        target.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        target.setPairAccess(PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        prime.mint(address(target), 1_000_000 * UNIT);
        pathUsd.mint(address(target), 1_000_000 * UNIT);
        other.mint(address(target), 1_000_000 * UNIT);
        target.unpause();
    }

    /// @dev A deposit of `amount`, or a redemption of `amount` from a vault holding no quote, which it then pays out.
    function _run(DirectPropAMMBufferHelper helper, MockBoringVault account, bool deposit, uint256 amount) internal {
        if (deposit) pathUsd.mint(address(account), amount);
        (address[] memory targets, bytes[] memory data, uint256[] memory values) = deposit
            ? helper.getDepositManageCall(address(pathUsd), amount)
            : helper.getWithdrawManageCall(address(pathUsd), amount);
        assertEq(targets.length, 4);
        account.manage(targets, data, values);
        if (!deposit) _payOut(account, pathUsd, amount);
        assertEq(pathUsd.balanceOf(address(account)), 0);
    }

    function _payOut(MockBoringVault account, MockTIP20 token, uint256 amount) internal {
        vm.prank(address(account));
        token.transferWithMemo(address(this), amount, bytes32(0));
    }

    /// @dev No allowance from the vault to the Settler or the pool, and no balance on the Settler.
    function _assertNothingLeftBehind() internal view {
        MockTIP20[3] memory tokens = [prime, pathUsd, other];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].allowance(address(vault), settler), 0);
            assertEq(tokens[i].allowance(address(vault), address(pool)), 0);
            assertEq(tokens[i].balanceOf(settler), 0);
        }
    }

    /// @dev The vault's and the pool's balances of both pair tokens, and the vault's route credit.
    function _holdings() internal view returns (uint256[5] memory held) {
        held[0] = prime.balanceOf(address(vault));
        held[1] = pathUsd.balanceOf(address(vault));
        held[2] = prime.balanceOf(address(pool));
        held[3] = pathUsd.balanceOf(address(pool));
        held[4] = pool.roundingCredit(pool.roundingRouteKey(PAIR, address(vault), CUSTOMER_ID));
    }

    /// @dev Balances and route credit as `held`, no allowance from the vault to the Settler, the pool or the
    /// replacement settler, and nothing on either settler.
    function _assertNothingMoved(uint256[5] memory held) internal view {
        uint256[5] memory current = _holdings();
        for (uint256 i; i < held.length; ++i) {
            assertEq(current[i], held[i]);
        }
        _assertNothingLeftBehind();
        MockTIP20[3] memory tokens = [prime, pathUsd, other];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].allowance(address(vault), replacement), 0);
            assertEq(tokens[i].balanceOf(replacement), 0);
        }
    }

    /// @dev The Settler batch: clear the Settler's allowance, approve it, swap through it, clear again.
    function _settlerBatch(address token, uint256 approved, IManagedDirectPropAMM.SwapParams memory params)
        internal
        view
        returns (bytes memory)
    {
        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        (targets[0], targets[1], targets[2], targets[3]) = (token, token, settler, token);
        data[0] = abi.encodeCall(IERC20.approve, (settler, 0));
        data[1] = abi.encodeCall(IERC20.approve, (settler, approved));
        data[2] = abi.encodeCall(ISettler.swap, (address(pool), params));
        data[3] = data[0];
        return abi.encode(targets, data, new uint256[](4));
    }

    /// @dev The direct managed swap that carries `params`, field for field.
    function _directSwap(IManagedDirectPropAMM.SwapParams memory params) internal pure returns (bytes memory) {
        bytes4 selector = params.exactInput
            ? IManagedDirectPropAMM.swapExactInput.selector
            : IManagedDirectPropAMM.swapExactOutput.selector;
        return abi.encodeWithSelector(
            selector,
            params.pairIndex,
            params.baseToQuote,
            params.amount,
            params.limit,
            params.sponsorId,
            params.customerId,
            params.tradeId,
            params.deadline,
            params.expectedOraclePrice,
            params.oraclePriceToleranceBps,
            params.minimumOracleUpdatedAt
        );
    }

    function _helper(ManagedDirectPropAMM target, MockBoringVault account, uint64 sponsorId)
        internal
        returns (DirectPropAMMBufferHelper)
    {
        return new DirectPropAMMBufferHelper(
            IDirectPropAMM(address(target)), address(account), CUSTOMER_ID, 50, PAIR, sponsorId
        );
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _tradeId(string memory operation, uint256 amount) internal view returns (bytes32) {
        return keccak256(
            abi.encode(keccak256(bytes(operation)), CUSTOMER_ID, address(vault), amount, block.chainid, block.number)
        );
    }
}

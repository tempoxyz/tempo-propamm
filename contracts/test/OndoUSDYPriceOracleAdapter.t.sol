// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { DirectPropAMMBufferHelper } from "../src/DirectPropAMMBufferHelper.sol";
import { OndoUSDYPriceOracleAdapter } from "../src/OndoUSDYPriceOracleAdapter.sol";
import { IDirectPropAMM } from "../src/interfaces/IDirectPropAMM.sol";
import { IOndoUSDYOracleWrapper } from "../src/interfaces/IOndoUSDYOracle.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";

contract MockOndoUSDYOracleWrapper is IOndoUSDYOracleWrapper {
    uint256 public price;
    /// @dev 0 reports block.timestamp, as Ondo's wrapper does.
    uint256 public reportedTimestamp;

    constructor(uint256 price_) {
        price = price_;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function setReportedTimestamp(uint256 timestamp) external {
        reportedTimestamp = timestamp;
    }

    function getPriceData() external view returns (uint256, uint256) {
        return (price, reportedTimestamp == 0 ? block.timestamp : reportedTimestamp);
    }
}

contract MockUSDYBoringVault {
    error ManageCallFailed(uint256 index, bytes reason);

    function manage(address[] memory targets, bytes[] memory data, uint256[] memory values) external {
        for (uint256 i; i < targets.length; ++i) {
            (bool success, bytes memory reason) = targets[i].call{ value: values[i] }(data[i]);
            if (!success) revert ManageCallFailed(i, reason);
        }
    }
}

contract OndoUSDYPriceOracleAdapterTest is Test {
    uint256 internal constant START = 1_728_000;
    uint256 internal constant PRICE = 1_140_000_000_000_000_000;
    bytes32 internal constant CUSTOMER_ID = keccak256("usdy-customer");
    bytes32 internal constant TRADE_ID = keccak256("usdy-trade");

    MockOndoUSDYOracleWrapper internal wrapper;
    OndoUSDYPriceOracleAdapter internal adapter;

    function setUp() external {
        vm.warp(START);
        wrapper = new MockOndoUSDYOracleWrapper(PRICE);
        adapter = new OndoUSDYPriceOracleAdapter(wrapper);
    }

    function test_returnsWrapperPriceAtCurrentTime() external view {
        (uint256 price, uint256 updatedAt) = adapter.latestPrice();

        assertEq(price, PRICE);
        assertEq(updatedAt, block.timestamp);
        assertEq(adapter.decimals(), 18);
        assertEq(address(adapter.wrapper()), address(wrapper));
    }

    function test_followsAccruingPriceEveryRead() external {
        vm.warp(START + 1 minutes);
        wrapper.setPrice(PRICE + 80_000_000);

        (uint256 price, uint256 updatedAt) = adapter.latestPrice();

        assertEq(price, PRICE + 80_000_000);
        assertEq(updatedAt, START + 1 minutes);
    }

    function test_ignoresWrapperTimestamp() external {
        wrapper.setReportedTimestamp(START - 1 days);

        (, uint256 updatedAt) = adapter.latestPrice();

        assertEq(updatedAt, block.timestamp);
    }

    function test_rejectsZeroPrice() external {
        wrapper.setPrice(0);

        vm.expectRevert(OndoUSDYPriceOracleAdapter.InvalidPrice.selector);
        adapter.latestPrice();
    }

    function test_rejectsWrapperWithoutCode() external {
        vm.expectRevert(OndoUSDYPriceOracleAdapter.InvalidWrapper.selector);
        new OndoUSDYPriceOracleAdapter(IOndoUSDYOracleWrapper(address(0)));
    }

    function test_rejectsWrapperWithZeroPrice() external {
        MockOndoUSDYOracleWrapper zeroWrapper = new MockOndoUSDYOracleWrapper(0);

        vm.expectRevert(OndoUSDYPriceOracleAdapter.InvalidPrice.selector);
        new OndoUSDYPriceOracleAdapter(zeroWrapper);
    }

    function test_rejectsWrapperWithoutPriceData() external {
        address notAWrapper = address(new MockUSDYBoringVault());

        vm.expectRevert();
        new OndoUSDYPriceOracleAdapter(IOndoUSDYOracleWrapper(notAWrapper));
    }

    function test_poolQuoteExecutesInLaterBlockWhilePriceIsUnchanged() external {
        MockAddressRegistry registry = new MockAddressRegistry();
        MockTIP20 usdy = new MockTIP20("USDY", 18);
        MockTIP20 pathUsd = new MockTIP20("pathUSD", 6);
        address taker = makeAddr("taker");
        address recipient = makeAddr("recipient");
        DirectPropAMM pool =
            new DirectPropAMM(usdy, pathUsd, adapter, registry, address(this), address(this), 1 days, 50);

        usdy.setResolver(registry);
        pathUsd.setResolver(registry);
        pool.setTakerAllowed(taker, true);
        pool.setRecipientAllowed(recipient, true);
        usdy.mint(taker, 1e18);
        pathUsd.mint(address(pool), 2e6);
        vm.prank(taker);
        usdy.approve(address(pool), type(uint256).max);
        pool.unpause();

        (uint256 quotedOut, uint256 quotedPrice, uint256 quotedUpdatedAt) = pool.quoteExactInput(true, 1e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(block.number + 1);

        vm.prank(taker);
        uint256 amountOut = pool.swapExactInput(
            true, 1e18, quotedOut, recipient, CUSTOMER_ID, TRADE_ID, block.timestamp, quotedPrice, 0, quotedUpdatedAt
        );

        assertEq(amountOut, 1_140_000);
        assertEq(pathUsd.balanceOf(recipient), 1_140_000);
    }

    function test_poolStaysFreshAcrossDaysWithoutStepping() external {
        MockAddressRegistry registry = new MockAddressRegistry();
        MockTIP20 usdy = new MockTIP20("USDY", 18);
        MockTIP20 pathUsd = new MockTIP20("pathUSD", 6);
        DirectPropAMM pool =
            new DirectPropAMM(usdy, pathUsd, adapter, registry, address(this), address(this), 1 days, 50);

        usdy.setResolver(registry);
        pathUsd.setResolver(registry);
        pool.setTakerAllowed(address(this), true);
        pool.setRecipientAllowed(address(this), true);
        usdy.mint(address(this), 1e18);
        pathUsd.mint(address(pool), 2e6);
        usdy.approve(address(pool), type(uint256).max);
        pool.unpause();

        (uint256 quotedOut, uint256 quotedPrice, uint256 quotedUpdatedAt) = pool.quoteExactInput(true, 1e18);
        vm.warp(START + 4 days);

        uint256 amountOut = pool.swapExactInput(
            true,
            1e18,
            quotedOut,
            address(this),
            CUSTOMER_ID,
            TRADE_ID,
            block.timestamp,
            quotedPrice,
            0,
            quotedUpdatedAt
        );

        assertEq(amountOut, quotedOut);
    }

    function test_poolRequiresRequoteWhenPriceAccrues() external {
        MockAddressRegistry registry = new MockAddressRegistry();
        MockTIP20 usdy = new MockTIP20("USDY", 18);
        MockTIP20 pathUsd = new MockTIP20("pathUSD", 6);
        DirectPropAMM pool =
            new DirectPropAMM(usdy, pathUsd, adapter, registry, address(this), address(this), 1 days, 50);

        usdy.setResolver(registry);
        pathUsd.setResolver(registry);
        pool.setTakerAllowed(address(this), true);
        pool.setRecipientAllowed(address(this), true);
        usdy.mint(address(this), 1e18);
        pathUsd.mint(address(pool), 2e6);
        usdy.approve(address(pool), type(uint256).max);
        pool.unpause();

        (uint256 quotedOut, uint256 quotedPrice, uint256 quotedUpdatedAt) = pool.quoteExactInput(true, 1e18);
        vm.warp(START + 4 days);
        uint256 newPrice = PRICE + 100_000_000_000_000;
        wrapper.setPrice(newPrice);

        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.OraclePriceToleranceExceeded.selector, quotedPrice, newPrice, 0)
        );
        pool.swapExactInput(
            true,
            1e18,
            quotedOut,
            address(this),
            CUSTOMER_ID,
            TRADE_ID,
            block.timestamp,
            quotedPrice,
            0,
            quotedUpdatedAt
        );
    }

    function test_downwardRepriceIsRejectedByPriceBinding() external {
        MockAddressRegistry registry = new MockAddressRegistry();
        MockTIP20 usdy = new MockTIP20("USDY", 18);
        MockTIP20 pathUsd = new MockTIP20("pathUSD", 6);
        DirectPropAMM pool =
            new DirectPropAMM(usdy, pathUsd, adapter, registry, address(this), address(this), 1 days, 50);

        usdy.setResolver(registry);
        pathUsd.setResolver(registry);
        pool.setTakerAllowed(address(this), true);
        pool.setRecipientAllowed(address(this), true);
        usdy.mint(address(this), 1e18);
        pathUsd.mint(address(pool), 2e6);
        usdy.approve(address(pool), type(uint256).max);
        pool.unpause();

        (uint256 quotedOut, uint256 quotedPrice, uint256 quotedUpdatedAt) = pool.quoteExactInput(true, 1e18);
        uint256 newPrice = PRICE - 1_000_000_000_000_000;
        wrapper.setPrice(newPrice);

        vm.expectRevert(
            abi.encodeWithSelector(DirectPropAMM.OraclePriceToleranceExceeded.selector, quotedPrice, newPrice, 0)
        );
        pool.swapExactInput(
            true,
            1e18,
            quotedOut,
            address(this),
            CUSTOMER_ID,
            TRADE_ID,
            block.timestamp,
            quotedPrice,
            0,
            quotedUpdatedAt
        );
    }

    function test_bufferHelperSupportsUSDYWithoutInterfaceChanges() external {
        MockAddressRegistry registry = new MockAddressRegistry();
        MockTIP20 usdy = new MockTIP20("USDY", 18);
        MockTIP20 pathUsd = new MockTIP20("pathUSD", 6);
        MockUSDYBoringVault vault = new MockUSDYBoringVault();
        DirectPropAMM pool =
            new DirectPropAMM(usdy, pathUsd, adapter, registry, address(this), address(this), 1 days, 50);
        DirectPropAMMBufferHelper helper = new DirectPropAMMBufferHelper(
            IDirectPropAMM(address(pool)), address(vault), keccak256("earn-pathusd-usdy-veda"), 0, 0, 0
        );

        usdy.setResolver(registry);
        pathUsd.setResolver(registry);
        pool.setTakerAllowed(address(vault), true);
        pool.setRecipientAllowed(address(vault), true);
        usdy.mint(address(pool), 1e18);
        pathUsd.mint(address(vault), 1_140_000);
        pool.unpause();

        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(pathUsd), 1_140_000);
        vault.manage(targets, data, values);

        assertEq(usdy.balanceOf(address(vault)), 1e18);
        assertEq(pathUsd.balanceOf(address(vault)), 0);

        (targets, data, values) = helper.getWithdrawManageCall(address(pathUsd), 1_140_000);
        vault.manage(targets, data, values);

        assertEq(usdy.balanceOf(address(vault)), 0);
        assertEq(pathUsd.balanceOf(address(vault)), 1_140_000);
    }
}

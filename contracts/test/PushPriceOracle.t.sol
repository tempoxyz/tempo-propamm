// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { PushPriceOracle } from "../src/PushPriceOracle.sol";

contract PushPriceOracleTest is Test {
    address internal reporter = makeAddr("reporter");
    address internal stranger = makeAddr("stranger");
    PushPriceOracle internal oracle;

    function setUp() external {
        vm.warp(1_000_000);
        oracle = new PushPriceOracle(8, address(this), reporter, 105_000_000, block.timestamp - 10);
    }

    function test_constructorAttributesSeedToConfiguredReporter() external {
        address deployer = makeAddr("deployer");
        assertNotEq(deployer, reporter);
        uint256 sourceUpdatedAt = block.timestamp - 10;

        vm.expectEmit();
        emit PushPriceOracle.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit PushPriceOracle.ReporterUpdated(address(0), reporter);
        vm.expectEmit();
        emit PushPriceOracle.PricePushed(105_000_000, sourceUpdatedAt, reporter);
        vm.prank(deployer);
        PushPriceOracle seeded = new PushPriceOracle(8, address(this), reporter, 105_000_000, sourceUpdatedAt);

        assertEq(seeded.reporter(), reporter);
        (uint256 price, uint256 updatedAt) = seeded.latestPrice();
        assertEq(price, 105_000_000);
        assertEq(updatedAt, sourceUpdatedAt);
    }

    function test_reporterPushesMonotonicSourceObservation() external {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit PushPriceOracle.PricePushed(106_000_000, block.timestamp - 5, reporter);
        vm.prank(reporter);
        oracle.pushPrice(106_000_000, block.timestamp - 5);

        (uint256 price, uint256 updatedAt) = oracle.latestPrice();
        assertEq(price, 106_000_000);
        assertEq(updatedAt, block.timestamp - 5);
    }

    function test_rejectsUnauthorizedReporter() external {
        vm.expectRevert(PushPriceOracle.NotReporter.selector);
        vm.prank(stranger);
        oracle.pushPrice(106_000_000, block.timestamp - 5);
    }

    function test_rejectsNonIncreasingTimestamp() external {
        vm.expectPartialRevert(PushPriceOracle.TimestampNotIncreasing.selector);
        vm.prank(reporter);
        oracle.pushPrice(106_000_000, block.timestamp - 10);
    }

    function test_rejectsFutureTimestamp() external {
        vm.expectPartialRevert(PushPriceOracle.FutureTimestamp.selector);
        vm.prank(reporter);
        oracle.pushPrice(106_000_000, block.timestamp + 1);
    }

    function test_rotatedReporterPushIsAttributedToNewReporter() external {
        oracle.setReporter(stranger);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit PushPriceOracle.PricePushed(106_000_000, block.timestamp - 5, stranger);
        vm.prank(stranger);
        oracle.pushPrice(106_000_000, block.timestamp - 5);

        vm.expectRevert(PushPriceOracle.NotReporter.selector);
        vm.prank(reporter);
        oracle.pushPrice(107_000_000, block.timestamp - 1);
    }

    function test_ownerRotatesReporterAndOwnership() external {
        oracle.setReporter(stranger);
        assertEq(oracle.reporter(), stranger);

        address newOwner = makeAddr("newOwner");
        oracle.transferOwnership(newOwner);
        vm.prank(newOwner);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), newOwner);
    }
}

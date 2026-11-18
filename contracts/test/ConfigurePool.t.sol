// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { ConfigurePool } from "../script/ConfigurePool.s.sol";
import { DirectPropAMM } from "../src/DirectPropAMM.sol";
import { MockAddressRegistry } from "./mocks/MockAddressRegistry.sol";
import { MockOracle } from "./mocks/MockOracle.sol";
import { MockTIP20 } from "./mocks/MockTIP20.sol";

/// @dev Only the environment transport changes: run uses the real parser, broadcast and pool permission calls.
contract ConfigurePoolHarness is ConfigurePool {
    mapping(string key => string value) internal _inputs;

    function setInput(string calldata key, string calldata value) external {
        _inputs[key] = value;
    }

    function _envString(string memory key) internal view override returns (string memory) {
        return _inputs[key];
    }
}

contract ConfigurePoolTest is Test {
    address internal taker = makeAddr("taker");
    address internal recipient = makeAddr("recipient");
    DirectPropAMM internal pool;
    ConfigurePoolHarness internal script;

    function setUp() external {
        pool = new DirectPropAMM(
            new MockTIP20("BASE", 6),
            new MockTIP20("QUOTE", 6),
            new MockOracle(8, 1e8, block.timestamp),
            new MockAddressRegistry(),
            tx.origin,
            makeAddr("guardian"),
            90_000,
            50
        );
        script = new ConfigurePoolHarness();
        script.setInput("POOL_ADDRESS", vm.toString(address(pool)));
    }

    function test_explicitGrantAndRevokeBothRoles() external {
        _bothAddresses();
        script.setInput("TAKER_ALLOWED", "true");
        script.setInput("RECIPIENT_ALLOWED", "true");
        script.run();
        assertTrue(pool.takerAllowed(taker));
        assertTrue(pool.recipientAllowed(recipient));
        script.setInput("TAKER_ALLOWED", "false");
        script.setInput("RECIPIENT_ALLOWED", "false");
        script.run();
        assertFalse(pool.takerAllowed(taker));
        assertFalse(pool.recipientAllowed(recipient));
    }

    function test_takerOnlyLeavesRecipientsUntouched() external {
        vm.prank(tx.origin);
        pool.setRecipientAllowed(recipient, true);
        script.setInput("TAKER_ADDRESS", vm.toString(taker));
        script.setInput("TAKER_ALLOWED", "true");
        _runOnly(keccak256("TakerPermissionUpdated(address,bool)"));
        assertTrue(pool.takerAllowed(taker));
        script.setInput("TAKER_ALLOWED", "false");
        _runOnly(keccak256("TakerPermissionUpdated(address,bool)"));
        assertFalse(pool.takerAllowed(taker));
        assertTrue(pool.recipientAllowed(recipient));
    }

    function test_recipientOnlyLeavesTakersUntouched() external {
        vm.prank(tx.origin);
        pool.setTakerAllowed(taker, true);
        script.setInput("RECIPIENT_ADDRESS", vm.toString(recipient));
        script.setInput("RECIPIENT_ALLOWED", "true");
        _runOnly(keccak256("RecipientPermissionUpdated(address,bool)"));
        assertTrue(pool.recipientAllowed(recipient));
        script.setInput("RECIPIENT_ALLOWED", "false");
        _runOnly(keccak256("RecipientPermissionUpdated(address,bool)"));
        assertFalse(pool.recipientAllowed(recipient));
        assertTrue(pool.takerAllowed(taker));
    }

    function test_rejectsMissingFlagsBeforeWrites() external {
        _bothAddresses();
        _reject("TAKER_ALLOWED");
        script.setInput("TAKER_ALLOWED", "true");
        _reject("RECIPIENT_ALLOWED");
    }

    function test_rejectsMalformedFlagsBeforeWrites() external {
        _bothAddresses();
        script.setInput("TAKER_ALLOWED", "flase");
        script.setInput("RECIPIENT_ALLOWED", "true");
        _reject("TAKER_ALLOWED");
        script.setInput("TAKER_ALLOWED", "true");
        script.setInput("RECIPIENT_ALLOWED", "flase");
        _reject("RECIPIENT_ALLOWED");
    }

    function test_rejectsFlagWithoutAddress() external {
        script.setInput("TAKER_ALLOWED", "false");
        _reject("TAKER_ADDRESS");
        script.setInput("TAKER_ALLOWED", "");
        script.setInput("RECIPIENT_ALLOWED", "true");
        _reject("RECIPIENT_ADDRESS");
    }

    function test_rejectsZeroRoleAddressBeforeWrites() external {
        _bothAddresses();
        script.setInput("TAKER_ALLOWED", "true");
        script.setInput("RECIPIENT_ALLOWED", "true");
        script.setInput("RECIPIENT_ADDRESS", vm.toString(address(0)));
        _reject("RECIPIENT_ADDRESS");
        script.setInput("TAKER_ADDRESS", vm.toString(address(0)));
        _reject("TAKER_ADDRESS");
    }

    function test_rejectsNoRequestedRole() external {
        _reject("no role requested");
    }

    function test_rejectsMalformedAddressBeforeWrites() external {
        _bothAddresses();
        script.setInput("TAKER_ALLOWED", "true");
        script.setInput("RECIPIENT_ALLOWED", "true");
        script.setInput("RECIPIENT_ADDRESS", "not-an-address");
        vm.recordLogs();
        vm.expectRevert();
        script.run();
        assertEq(vm.getRecordedLogs().length, 0, "no permission call before validation finishes");
        assertFalse(pool.takerAllowed(taker));
    }

    function testFuzz_rejectsEveryNonBooleanFlag(string memory flag) external {
        vm.assume(keccak256(bytes(flag)) != keccak256("true") && keccak256(bytes(flag)) != keccak256("false"));
        _bothAddresses();
        script.setInput("TAKER_ALLOWED", "true");
        script.setInput("RECIPIENT_ALLOWED", flag);
        _reject("RECIPIENT_ALLOWED");
    }

    function _bothAddresses() internal {
        script.setInput("TAKER_ADDRESS", vm.toString(taker));
        script.setInput("RECIPIENT_ADDRESS", vm.toString(recipient));
    }

    function _reject(string memory field) internal {
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(ConfigurePool.InvalidConfig.selector, field));
        script.run();
        assertEq(vm.getRecordedLogs().length, 0, "no permission call before validation finishes");
        assertFalse(pool.takerAllowed(taker));
        assertFalse(pool.recipientAllowed(recipient));
    }

    function _runOnly(bytes32 eventTopic) internal {
        vm.recordLogs();
        script.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only the requested role is written");
        assertEq(logs[0].emitter, address(pool));
        assertEq(logs[0].topics[0], eventTopic);
    }
}

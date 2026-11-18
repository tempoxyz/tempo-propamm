// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";

import { ITIP403Registry } from "../../src/interfaces/ITIP403Registry.sol";
import { ITIP403Precompile } from "./mocks/ITIP403Precompile.sol";
import { MockGuardedTIP20 } from "./mocks/MockGuardedTIP20.sol";
import { MockTIP403Registry } from "./mocks/MockTIP403Registry.sol";
import { MockVirtualAddressRegistry } from "./mocks/MockVirtualAddressRegistry.sol";
import { Sender } from "./mocks/Sender.sol";
import { VirtualAddress } from "./utils/VirtualAddress.sol";

/// @notice Pins the mocks in `test/v2/mocks` to the precompile semantics they stand in for, as read at tempo
/// origin/main: `tip403_registry/mod.rs`, `address_registry/mod.rs`, `tip20/mod.rs` and `receive_policy_guard/mod.rs`.
/// The TIP-403 guard and event checks also run on the precompile itself under `forge test --network tempo`.
contract MockFidelityTest is Test {
    /// @dev The TIP-403 registry precompile, which only `--network tempo` provides.
    address internal constant TIP403_PRECOMPILE = 0x403c000000000000000000000000000000000000;

    MockTIP403Registry internal registry;
    MockVirtualAddressRegistry internal addresses;
    MockGuardedTIP20 internal token;
    address internal virtualAccount;
    address internal receiver = makeAddr("receiver");
    address internal master = makeAddr("master");

    function setUp() public {
        registry = new MockTIP403Registry();
        addresses = new MockVirtualAddressRegistry();
        token = new MockGuardedTIP20("GUSD");
        virtualAccount = VirtualAddress.make(0x12345678, 0xAA);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // TIP-403 registry
    // ---------------------------------------------------------------------------------------------------------------

    function test_tip403_whitelistRefusesVirtualAccounts() public {
        uint64 policy = registry.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
        vm.expectRevert(MockTIP403Registry.VirtualAddressNotAllowed.selector);
        registry.modifyPolicyWhitelist(policy, virtualAccount, true);
        registry.modifyPolicyWhitelist(policy, master, true);
        assertTrue(registry.isAuthorizedSender(policy, master));
    }

    function test_tip403_unknownPolicyReverts() public {
        uint64 unknown = registry.policyIdCounter();
        vm.expectRevert(MockTIP403Registry.PolicyNotFound.selector);
        registry.isAuthorizedSender(unknown, master);
        vm.expectRevert(MockTIP403Registry.PolicyNotFound.selector);
        registry.isAuthorizedRecipient(unknown, master);
    }

    function test_tip403_builtinPoliciesHaveNoAdmin() public {
        for (uint64 policy; policy < 2; ++policy) {
            vm.expectRevert(MockTIP403Registry.Unauthorized.selector);
            registry.setPolicyAdmin(policy, address(this));
            vm.expectRevert(MockTIP403Registry.Unauthorized.selector);
            registry.modifyPolicyWhitelist(policy, master, true);
        }
    }

    function test_tip403_compoundPartsMustBeSimple() public {
        uint64 whitelist = registry.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
        uint64 compound = registry.createCompoundPolicy(whitelist, 1);
        registry.createCompoundPolicy(0, 1);
        vm.expectRevert(MockTIP403Registry.PolicyNotSimple.selector);
        registry.createCompoundPolicy(compound, 1);
        vm.expectRevert(MockTIP403Registry.PolicyNotSimple.selector);
        registry.createCompoundPolicy(whitelist, compound);
        uint64 unknown = registry.policyIdCounter();
        vm.expectRevert(MockTIP403Registry.PolicyNotFound.selector);
        registry.createCompoundPolicy(unknown, 1);
    }

    /// @dev From T6 the registry authorizes the ReceivePolicyGuard in both roles before it reads the policy id, so no
    /// policy rejects it: not policy 0, a whitelist without it, a blacklist that lists it, a compound of those, nor an
    /// unknown id. Any other account still gets each policy's own answer.
    function test_tip403_guardIsAuthorizedUnderEveryPolicy() public {
        address guard = registry.RECEIVE_POLICY_GUARD();
        assertEq(guard, token.GUARD());
        ITIP403Precompile[] memory registries = _registries();
        for (uint256 r; r < registries.length; ++r) {
            ITIP403Precompile tip403 = registries[r];
            uint64 whitelist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
            uint64 blacklist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST);
            tip403.modifyPolicyBlacklist(blacklist, guard, true);
            tip403.modifyPolicyBlacklist(blacklist, master, true);
            uint64 compound = tip403.createCompoundPolicy(whitelist, blacklist, 0);

            uint64[4] memory policies = [uint64(0), whitelist, blacklist, compound];
            for (uint256 i; i < policies.length; ++i) {
                assertTrue(tip403.isAuthorizedSender(policies[i], guard));
                assertTrue(tip403.isAuthorizedRecipient(policies[i], guard));
                assertFalse(tip403.isAuthorizedSender(policies[i], master));
                assertFalse(tip403.isAuthorizedRecipient(policies[i], master));
            }

            uint64 unknown = tip403.policyIdCounter();
            assertTrue(tip403.isAuthorizedSender(unknown, guard));
            assertTrue(tip403.isAuthorizedRecipient(unknown, guard));
            vm.expectRevert(MockTIP403Registry.PolicyNotFound.selector);
            tip403.isAuthorizedSender(unknown, master);
            vm.expectRevert(MockTIP403Registry.PolicyNotFound.selector);
            tip403.isAuthorizedRecipient(unknown, master);
        }
    }

    /// @dev `createPolicy` emits `PolicyCreated` and then `PolicyAdminUpdated`, and nothing else. Both name the caller as
    /// `updater`, even when it makes another account the admin.
    function test_tip403_createPolicyEmitsCreatedThenAdminUpdated() public {
        ITIP403Precompile[] memory registries = _registries();
        for (uint256 r; r < registries.length; ++r) {
            ITIP403Precompile tip403 = registries[r];
            for (uint8 t; t < 2; ++t) {
                ITIP403Registry.PolicyType policyType = ITIP403Registry.PolicyType(t);
                uint64 policyId = tip403.policyIdCounter();
                vm.recordLogs();
                vm.expectEmit(address(tip403));
                emit MockTIP403Registry.PolicyCreated(policyId, address(this), policyType);
                vm.expectEmit(address(tip403));
                emit MockTIP403Registry.PolicyAdminUpdated(policyId, address(this), master);
                assertEq(tip403.createPolicy(master, policyType), policyId);
                assertEq(_logsFrom(address(tip403)), 2);
            }
        }
    }

    /// @dev Every whitelist, blacklist and admin edit emits once, with the caller as `updater`, even when it changes
    /// nothing. The mock's unchecked `setBlacklisted` helper emits like `modifyPolicyBlacklist`.
    function test_tip403_editsEmitEvenWhenNothingChanges() public {
        ITIP403Precompile[] memory registries = _registries();
        for (uint256 r; r < registries.length; ++r) {
            ITIP403Precompile tip403 = registries[r];
            uint64 whitelist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
            uint64 blacklist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST);
            vm.recordLogs();
            vm.expectEmit(address(tip403));
            emit MockTIP403Registry.WhitelistUpdated(whitelist, address(this), master, false);
            tip403.modifyPolicyWhitelist(whitelist, master, false);
            vm.expectEmit(address(tip403));
            emit MockTIP403Registry.BlacklistUpdated(blacklist, address(this), master, false);
            tip403.modifyPolicyBlacklist(blacklist, master, false);
            vm.expectEmit(address(tip403));
            emit MockTIP403Registry.PolicyAdminUpdated(whitelist, address(this), address(this));
            tip403.setPolicyAdmin(whitelist, address(this));
            assertEq(_logsFrom(address(tip403)), 3);
            assertFalse(tip403.isAuthorizedSender(whitelist, master));
            assertTrue(tip403.isAuthorizedSender(blacklist, master));
        }

        uint64 helperBlacklist = registry.createPolicy(receiver, ITIP403Registry.PolicyType.BLACKLIST);
        vm.expectEmit(address(registry));
        emit MockTIP403Registry.BlacklistUpdated(helperBlacklist, address(this), master, true);
        registry.setBlacklisted(helperBlacklist, master, true);
        assertFalse(registry.isAuthorizedSender(helperBlacklist, master));
    }

    /// @dev `setPolicyAdmin` moves the admin `policyData` reports: only the new admin can edit, the old one is refused,
    /// and handing it to `address(0)` freezes the list for good. The type never changes.
    function test_tip403_setPolicyAdminMovesPolicyData() public {
        ITIP403Precompile[] memory registries = _registries();
        for (uint256 r; r < registries.length; ++r) {
            ITIP403Precompile tip403 = registries[r];
            uint64 list = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
            vm.expectEmit(address(tip403));
            emit MockTIP403Registry.PolicyAdminUpdated(list, address(this), receiver);
            tip403.setPolicyAdmin(list, receiver);
            (ITIP403Registry.PolicyType policyType, address admin) = tip403.policyData(list);
            assertEq(uint8(policyType), uint8(ITIP403Registry.PolicyType.WHITELIST));
            assertEq(admin, receiver);
            vm.expectRevert(MockTIP403Registry.Unauthorized.selector);
            tip403.modifyPolicyWhitelist(list, master, true);
            vm.prank(receiver);
            tip403.modifyPolicyWhitelist(list, master, true);
            assertTrue(tip403.isAuthorizedSender(list, master));

            vm.prank(receiver);
            tip403.setPolicyAdmin(list, address(0));
            (, admin) = tip403.policyData(list);
            assertEq(admin, address(0));
            vm.prank(receiver);
            vm.expectRevert(MockTIP403Registry.Unauthorized.selector);
            tip403.modifyPolicyWhitelist(list, master, false);
            assertTrue(tip403.isAuthorizedSender(list, master), "a frozen list keeps its members");
        }
    }

    /// @dev `modifyPolicyBlacklist` checks the account, then that the policy exists, then the caller, then the type,
    /// in `modifyPolicyWhitelist`'s order.
    function test_tip403_blacklistEditChecks() public {
        ITIP403Precompile[] memory registries = _registries();
        for (uint256 r; r < registries.length; ++r) {
            ITIP403Precompile tip403 = registries[r];
            uint64 whitelist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
            uint64 blacklist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST);
            uint64 unknown = tip403.policyIdCounter();

            vm.expectRevert(MockTIP403Registry.VirtualAddressNotAllowed.selector);
            tip403.modifyPolicyBlacklist(unknown, virtualAccount, true);
            vm.expectRevert(MockTIP403Registry.PolicyNotFound.selector);
            tip403.modifyPolicyBlacklist(unknown, master, true);
            vm.prank(receiver);
            vm.expectRevert(MockTIP403Registry.Unauthorized.selector);
            tip403.modifyPolicyBlacklist(whitelist, master, true);
            vm.expectRevert(MockTIP403Registry.IncompatiblePolicyType.selector);
            tip403.modifyPolicyBlacklist(whitelist, master, true);
            vm.expectRevert(MockTIP403Registry.IncompatiblePolicyType.selector);
            tip403.modifyPolicyWhitelist(blacklist, master, true);

            tip403.modifyPolicyBlacklist(blacklist, master, true);
            assertFalse(tip403.isAuthorizedSender(blacklist, master));
            assertFalse(tip403.isAuthorizedRecipient(blacklist, master));
        }
    }

    /// @dev `createCompoundPolicy` emits its three parts. The mock's two-part helper passes mint part 0.
    function test_tip403_createCompoundPolicyEmitsItsParts() public {
        ITIP403Precompile[] memory registries = _registries();
        for (uint256 r; r < registries.length; ++r) {
            ITIP403Precompile tip403 = registries[r];
            uint64 whitelist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
            uint64 blacklist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST);
            uint64 policyId = tip403.policyIdCounter();
            vm.recordLogs();
            vm.expectEmit(address(tip403));
            emit MockTIP403Registry.CompoundPolicyCreated(policyId, address(this), whitelist, blacklist, 1);
            assertEq(tip403.createCompoundPolicy(whitelist, blacklist, 1), policyId);
            assertEq(_logsFrom(address(tip403)), 1);
            (ITIP403Registry.PolicyType policyType, address admin) = tip403.policyData(policyId);
            assertEq(uint8(policyType), uint8(ITIP403Registry.PolicyType.COMPOUND));
            assertEq(admin, address(0));
        }

        uint64 helperCompound = registry.policyIdCounter();
        vm.expectEmit(address(registry));
        emit MockTIP403Registry.CompoundPolicyCreated(helperCompound, address(this), 1, 0, 0);
        assertEq(registry.createCompoundPolicy(1, 0), helperCompound);
    }

    /// @dev `createCompoundPolicy` checks the mint part like the sender and recipient parts (built-in or an existing
    /// simple policy), and checks the three in that order, so the first bad part names the error.
    function test_tip403_createCompoundPolicyChecksEveryPartInOrder() public {
        ITIP403Precompile[] memory registries = _registries();
        for (uint256 r; r < registries.length; ++r) {
            ITIP403Precompile tip403 = registries[r];
            uint64 whitelist = tip403.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
            uint64 compound = tip403.createCompoundPolicy(whitelist, 1, 0);
            uint64 unknown = tip403.policyIdCounter();

            vm.expectRevert(MockTIP403Registry.PolicyNotSimple.selector);
            tip403.createCompoundPolicy(whitelist, 1, compound);
            vm.expectRevert(MockTIP403Registry.PolicyNotFound.selector);
            tip403.createCompoundPolicy(1, 1, unknown);

            vm.expectRevert(MockTIP403Registry.PolicyNotFound.selector);
            tip403.createCompoundPolicy(unknown, compound, compound);
            vm.expectRevert(MockTIP403Registry.PolicyNotSimple.selector);
            tip403.createCompoundPolicy(compound, 1, unknown);
            vm.expectRevert(MockTIP403Registry.PolicyNotSimple.selector);
            tip403.createCompoundPolicy(1, compound, unknown);

            assertEq(tip403.createCompoundPolicy(1, 1, whitelist), unknown);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // TIP-1022 address registry
    // ---------------------------------------------------------------------------------------------------------------

    function test_addressRegistry_decodesOnlyTheVirtualLayout() public {
        // A plain address always resolves to itself and can't be registered.
        address plain = makeAddr("plain");
        vm.expectRevert(abi.encodeWithSelector(MockVirtualAddressRegistry.NotVirtual.selector, plain));
        addresses.setVirtual(plain, master);
        assertEq(addresses.resolveRecipient(plain), plain);

        // A virtual address reverts until its master id is registered, then every tag under it resolves.
        vm.expectRevert(
            abi.encodeWithSelector(MockVirtualAddressRegistry.VirtualAddressUnregistered.selector, virtualAccount)
        );
        addresses.resolveRecipient(virtualAccount);
        addresses.setVirtual(virtualAccount, master);
        assertEq(addresses.resolveRecipient(virtualAccount), master);
        assertEq(addresses.resolveRecipient(VirtualAddress.make(0x12345678, 0xBB)), master);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // TIP-1028 receive policies
    // ---------------------------------------------------------------------------------------------------------------

    function test_tip1028_blockParksFundsForTheOriginatorOnly() public {
        Sender originator = new Sender();
        token.mint(address(originator), 100e6);
        vm.prank(receiver);
        token.setReceivePolicy(true, true, address(0));

        // The transfer succeeds, but the receiver gets nothing: the guard holds it under a receipt.
        uint8 reason = token.RECEIVE_POLICY();
        vm.expectEmit(address(token));
        emit MockGuardedTIP20.TransferBlocked(0, address(originator), receiver, 40e6, reason);
        originator.send(token, receiver, 40e6);
        assertEq(token.balanceOf(address(originator)), 60e6);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(token.GUARD()), 40e6);
        (address from, address to, address authority, uint256 amount) = token.receipts(0);
        assertEq(from, address(originator));
        assertEq(to, receiver);
        assertEq(authority, address(0));
        assertEq(amount, 40e6);

        // Default recovery: only the originator can claim, so a contract without a claim path can never recover it.
        vm.prank(receiver);
        vm.expectRevert(MockGuardedTIP20.UnauthorizedClaimer.selector);
        token.claim(0, receiver);
        vm.prank(address(originator));
        token.claim(0, address(originator));
        assertEq(token.balanceOf(address(originator)), 100e6);
        assertEq(token.balanceOf(token.GUARD()), 0);
    }

    function test_tip1028_receiverRecoveryLetsTheReceiverClaim() public {
        Sender originator = new Sender();
        token.mint(address(originator), 10e6);
        vm.prank(receiver);
        token.setReceivePolicy(true, true, receiver);
        originator.send(token, receiver, 10e6);

        vm.prank(address(originator));
        vm.expectRevert(MockGuardedTIP20.UnauthorizedClaimer.selector);
        token.claim(0, address(originator));
        vm.prank(receiver);
        token.claim(0, receiver);
        assertEq(token.balanceOf(receiver), 10e6);
    }

    function test_tip1028_tokenFilterThenSenderPolicy() public {
        Sender originator = new Sender();
        token.mint(address(originator), 30e6);
        vm.startPrank(receiver);
        token.setReceivePolicy(false, true, address(0));
        token.setSenderListed(address(originator), true);
        vm.stopPrank();
        // The token filter is checked first, even for a listed sender.
        (uint8 tokenFilter, uint8 senderPolicy) = (token.TOKEN_FILTER(), token.RECEIVE_POLICY());
        vm.expectEmit(address(token));
        emit MockGuardedTIP20.TransferBlocked(0, address(originator), receiver, 10e6, tokenFilter);
        originator.send(token, receiver, 10e6);

        // A blacklist sender policy blocks only the senders it lists.
        vm.prank(receiver);
        token.setReceivePolicy(true, false, address(0));
        vm.expectEmit(address(token));
        emit MockGuardedTIP20.TransferBlocked(1, address(originator), receiver, 10e6, senderPolicy);
        originator.send(token, receiver, 10e6);
        vm.prank(receiver);
        token.setSenderListed(address(originator), false);
        originator.send(token, receiver, 10e6);
        assertEq(token.balanceOf(receiver), 10e6);
    }

    function test_tip1028_checksTheResolvedReceiverAgainstFrom() public {
        token.setResolver(addresses);
        addresses.setVirtual(virtualAccount, receiver);
        address holder = makeAddr("holder");
        address spender = makeAddr("spender");
        token.mint(holder, 10e6);
        vm.prank(holder);
        token.approve(spender, 10e6);
        // The receiver accepts the spender, but the originator is `from`, and the master's policy governs its virtual
        // addresses.
        vm.startPrank(receiver);
        token.setReceivePolicy(true, true, address(0));
        token.setSenderListed(spender, true);
        vm.stopPrank();
        vm.prank(spender);
        token.transferFromWithMemo(holder, virtualAccount, 10e6, bytes32(0));
        assertEq(token.balanceOf(receiver), 0);
        (address from, address to,,) = token.receipts(0);
        assertEq(from, holder);
        assertEq(to, receiver);
    }

    function test_tip1028_guardAddressIsReserved() public {
        token.mint(address(this), 1);
        address guard = token.GUARD();
        vm.expectRevert(MockGuardedTIP20.AddressReserved.selector);
        token.transferWithMemo(guard, 1, bytes32(0));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The mock, and under `--network tempo` the precompile too, so one check pins both to the same behaviour.
    function _registries() internal view returns (ITIP403Precompile[] memory registries) {
        bool precompile = TIP403_PRECOMPILE.code.length != 0;
        registries = new ITIP403Precompile[](precompile ? 2 : 1);
        registries[0] = ITIP403Precompile(address(registry));
        if (precompile) registries[1] = ITIP403Precompile(TIP403_PRECOMPILE);
    }

    /// @dev How many of the logs recorded since the last read `emitter` emitted. The recording also holds the test's
    /// own `vm.expectEmit` templates, so count by emitter.
    function _logsFrom(address emitter) internal view returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) ++count;
        }
    }
}

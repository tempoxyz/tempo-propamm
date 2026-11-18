// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { DirectPropAMMBufferHelper } from "../../src/DirectPropAMMBufferHelper.sol";
import { IDirectPropAMM } from "../../src/interfaces/IDirectPropAMM.sol";
import { MockAddressRegistry } from "../mocks/MockAddressRegistry.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";

/// @dev Executes the helper's full batch atomically, as BoringVault.manage does.
contract BufferInvariantVault {
    error ManageCallFailed(uint256 index, bytes reason);

    function manage(address[] memory targets, bytes[] memory data, uint256[] memory values) external {
        for (uint256 i; i < targets.length; ++i) {
            (bool success, bytes memory reason) = targets[i].call{ value: values[i] }(data[i]);
            if (!success) revert ManageCallFailed(i, reason);
        }
    }

    function pay(MockTIP20 token, address recipient, uint256 amount) external {
        token.transferWithMemo(recipient, amount, bytes32(0));
    }
}

contract BufferHelperInvariantHandler {
    uint256 internal constant MAX_AMOUNT = 10_000_000;
    bytes32 internal constant CUSTOMER_ID = keccak256("buffer-stateful-audit");

    DirectPropAMM public immutable pool;
    DirectPropAMMBufferHelper public immutable helper;
    BufferInvariantVault public immutable vault;
    MockTIP20 public immutable baseToken;
    MockTIP20 public immutable quoteToken;
    MockOracle public immutable oracle;

    uint256 public totalDeposited;
    bool public invariantBroken;
    uint256 public completedDeposits;
    uint256 public completedWithdrawals;
    uint256 public rejectedBatches;

    constructor(
        DirectPropAMM pool_,
        BufferInvariantVault vault_,
        MockTIP20 baseToken_,
        MockTIP20 quoteToken_,
        MockOracle oracle_
    ) {
        pool = pool_;
        vault = vault_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        oracle = oracle_;
        helper = new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool_)), address(vault_), CUSTOMER_ID, 50, 0, 0);
    }

    function deposit(uint256 seed, uint256 interference) external {
        uint256 amount = 100_000 + seed % MAX_AMOUNT;
        quoteToken.mint(address(vault), amount);
        totalDeposited += amount;
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(quoteToken), amount);
        _checkBatch(targets, data, values, address(quoteToken));

        uint256 quotedOut;
        (quotedOut,,,) = pool.quoteExactInputFor(address(vault), address(vault), CUSTOMER_ID, false, amount);
        uint256 baseBefore = baseToken.balanceOf(address(vault));
        uint256 quoteBefore = quoteToken.balanceOf(address(vault));
        uint256 poolBaseBefore = baseToken.balanceOf(address(pool));
        uint256 poolQuoteBefore = quoteToken.balanceOf(address(pool));
        uint256 creditBefore = _credit();
        if (interference % 4 == 0) oracle.setPrice(oracle.price() + 1, block.timestamp);

        try vault.manage(targets, data, values) {
            if (
                interference % 4 == 0 || quoteToken.balanceOf(address(vault)) != quoteBefore - amount
                    || baseToken.balanceOf(address(vault)) != baseBefore + quotedOut
                    || baseToken.balanceOf(address(pool)) != poolBaseBefore - quotedOut
                    || quoteToken.balanceOf(address(pool)) != poolQuoteBefore + amount
            ) invariantBroken = true;
            ++completedDeposits;
        } catch {
            if (
                interference % 4 != 0 || baseToken.balanceOf(address(vault)) != baseBefore
                    || quoteToken.balanceOf(address(vault)) != quoteBefore
                    || baseToken.balanceOf(address(pool)) != poolBaseBefore
                    || quoteToken.balanceOf(address(pool)) != poolQuoteBefore || _credit() != creditBefore
            ) {
                invariantBroken = true;
            }
            ++rejectedBatches;
        }
        if (
            baseToken.allowance(address(vault), address(pool)) != 0
                || quoteToken.allowance(address(vault), address(pool)) != 0
        ) invariantBroken = true;
        if (interference % 4 == 0) oracle.setPrice(oracle.price() - 1, block.timestamp);
    }

    function withdraw(uint256 seed, uint256 existingQuoteSeed, bool expire) external {
        uint256 existingQuote = quoteToken.balanceOf(address(vault));
        // Introduce a partial redemption buffer without minting base or changing pool inventory.
        uint256 additionalQuote = existingQuoteSeed % 1_000_000;
        quoteToken.mint(address(vault), additionalQuote);
        totalDeposited += additionalQuote;
        existingQuote += additionalQuote;
        uint256 amount = 1 + seed % MAX_AMOUNT;
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getWithdrawManageCall(address(quoteToken), amount);
        if (existingQuote >= amount) {
            if (targets.length != 0 || data.length != 0 || values.length != 0) invariantBroken = true;
            vault.pay(quoteToken, address(this), amount);
            ++completedWithdrawals;
            return;
        }
        _checkBatch(targets, data, values, address(baseToken));
        uint256 shortfall = amount - existingQuote;
        (uint256 quotedBaseIn,,,) =
            pool.quoteExactOutputFor(address(vault), address(vault), CUSTOMER_ID, true, shortfall);
        uint256 baseBefore = baseToken.balanceOf(address(vault));
        uint256 quotePoolBefore = quoteToken.balanceOf(address(pool));
        uint256 creditBefore = _credit();
        if (expire) vmWarp(block.timestamp + 1);

        try vault.manage(targets, data, values) {
            if (
                expire || quoteToken.balanceOf(address(vault)) != amount
                    || baseToken.balanceOf(address(vault)) != baseBefore - quotedBaseIn
                    || quoteToken.balanceOf(address(pool)) != quotePoolBefore - shortfall
            ) invariantBroken = true;
            vault.pay(quoteToken, address(this), amount);
            ++completedWithdrawals;
        } catch {
            if (!expire && quotedBaseIn <= baseBefore && shortfall <= quotePoolBefore) invariantBroken = true;
            if (
                quoteToken.balanceOf(address(vault)) != existingQuote
                    || baseToken.balanceOf(address(vault)) != baseBefore
                    || quoteToken.balanceOf(address(pool)) != quotePoolBefore || _credit() != creditBefore
            ) {
                invariantBroken = true;
            }
            ++rejectedBatches;
        }
        if (
            baseToken.allowance(address(vault), address(pool)) != 0
                || quoteToken.allowance(address(vault), address(pool)) != 0
        ) invariantBroken = true;
    }

    function _checkBatch(address[] memory targets, bytes[] memory data, uint256[] memory values, address approvalToken)
        internal
    {
        if (targets.length != 4 || data.length != 4 || values.length != 4) {
            invariantBroken = true;
            return;
        }
        if (
            targets[0] != approvalToken || targets[1] != approvalToken || targets[2] != address(pool)
                || targets[3] != approvalToken
        ) invariantBroken = true;
        for (uint256 i; i < 4; ++i) {
            if (values[i] != 0) invariantBroken = true;
        }
    }

    function _credit() internal view returns (uint256) {
        return pool.roundingCredit(pool.roundingRouteKey(address(vault), address(vault), CUSTOMER_ID));
    }

    function vmWarp(uint256 timestamp) internal {
        (bool success,) = address(uint160(uint256(keccak256("hevm cheat code"))))
            .call(abi.encodeWithSignature("warp(uint256)", timestamp));
        require(success);
    }
}

contract BufferHelperInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_BALANCE = 1e15;
    uint256 internal constant INITIAL_BASE_VAULT = 1e10;

    DirectPropAMM internal pool;
    BufferHelperInvariantHandler internal handler;
    BufferInvariantVault internal vault;
    MockTIP20 internal baseToken;
    MockTIP20 internal quoteToken;

    function setUp() external {
        vm.warp(1_000_000);
        MockAddressRegistry registry = new MockAddressRegistry();
        baseToken = new MockTIP20("BASE", 6);
        quoteToken = new MockTIP20("QUOTE", 6);
        MockOracle oracle = new MockOracle(8, 105_000_000, block.timestamp);
        baseToken.setResolver(registry);
        quoteToken.setResolver(registry);
        vault = new BufferInvariantVault();
        pool = new DirectPropAMM(baseToken, quoteToken, oracle, registry, address(this), address(this), 90_000, 50);
        handler = new BufferHelperInvariantHandler(pool, vault, baseToken, quoteToken, oracle);
        pool.setTakerAllowed(address(vault), true);
        pool.setRecipientAllowed(address(vault), true);
        baseToken.mint(address(pool), INITIAL_BALANCE);
        quoteToken.mint(address(pool), INITIAL_BALANCE);
        baseToken.mint(address(vault), INITIAL_BASE_VAULT);
        pool.unpause();

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        // Native-fork reproduction only: pin the outer fee payer to avoid irrelevant fee-state hydration.
        // Modeled actors are selected inside the handler; the default campaign remains unrestricted.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_balancesAndAllowancesRemainAccountedFor() external view {
        assertFalse(handler.invariantBroken());
        assertEq(
            baseToken.balanceOf(address(pool)) + baseToken.balanceOf(address(vault)),
            INITIAL_BALANCE + INITIAL_BASE_VAULT
        );
        assertEq(
            quoteToken.balanceOf(address(pool)) + quoteToken.balanceOf(address(vault))
                + quoteToken.balanceOf(address(handler)),
            INITIAL_BALANCE + handler.totalDeposited()
        );
        assertEq(baseToken.allowance(address(vault), address(pool)), 0);
        assertEq(quoteToken.allowance(address(vault), address(pool)), 0);
    }

    function test_partialRedemptionAfterDepositAndFailedManage() external {
        handler.deposit(5_000_000, 1);
        assertEq(handler.completedDeposits(), 1);
        handler.withdraw(8_000_000, 500_000, true);
        assertEq(handler.rejectedBatches(), 1);
        handler.withdraw(8_000_000, 500_000, false);
        assertEq(handler.completedWithdrawals(), 1);
        this.invariant_balancesAndAllowancesRemainAccountedFor();
    }
}

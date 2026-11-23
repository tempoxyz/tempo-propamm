// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { DirectPropAMMBufferHelper } from "../../src/DirectPropAMMBufferHelper.sol";
import { IDirectPropAMM } from "../../src/interfaces/IDirectPropAMM.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { PoolFactory } from "../../src/managed/PoolFactory.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
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

/// @dev The same campaign on a factory-created `ManagedDirectPropAMM`, whose batches settle through the factory's
/// default Settler. The handler owns the pool, so it can also replace the pool's settler and select the default again:
/// while another settler is selected the helper still builds the Settler batch, whose swap the pool must refuse
/// (`NotSettler`), and nothing may move.
contract SettlerBufferHelperInvariantHandler {
    uint256 internal constant MAX_AMOUNT = 10_000_000;
    bytes32 internal constant CUSTOMER_ID = keccak256("buffer-settler-stateful");
    uint16 internal constant PAIR = 0;

    ManagedDirectPropAMM public immutable pool;
    DirectPropAMMBufferHelper public immutable helper;
    BufferInvariantVault public immutable vault;
    MockTIP20 public immutable baseToken;
    MockTIP20 public immutable quoteToken;
    MockOracle public immutable oracle;
    address public immutable settler;
    address public immutable replacement = address(uint160(uint256(keccak256("replacement settler"))));

    uint256 public totalDeposited;
    bool public invariantBroken;
    uint256 public completedDeposits;
    uint256 public completedWithdrawals;
    uint256 public rejectedBatches;
    uint256 public refusedFills;

    constructor(
        PoolFactory factory,
        BufferInvariantVault vault_,
        MockTIP20 baseToken_,
        MockTIP20 quoteToken_,
        MockOracle oracle_,
        uint256 inventory
    ) {
        vault = vault_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        oracle = oracle_;
        settler = factory.defaultSettler();
        pool = ManagedDirectPropAMM(factory.createPool(address(this), bytes32("buffer")));
        pool.addPair(address(baseToken_), address(quoteToken_), oracle_, 90_000, 50);
        address[] memory members = new address[](1);
        members[0] = address(vault_);
        pool.setMembers(PAIR, 0, members, true);
        pool.setPairAccess(PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        baseToken_.mint(address(pool), inventory);
        quoteToken_.mint(address(pool), inventory);
        pool.unpause();
        helper = new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), address(vault_), CUSTOMER_ID, 50, PAIR, 0);
    }

    /// @dev The owner selects another settler one time in four, and the factory's default otherwise.
    function selectSettler(uint256 seed) external {
        pool.setSettler(seed % 4 == 0 ? replacement : settler);
    }

    function deposit(uint256 seed, uint256 interference) external {
        uint256 amount = 100_000 + seed % MAX_AMOUNT;
        quoteToken.mint(address(vault), amount);
        totalDeposited += amount;
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getDepositManageCall(address(quoteToken), amount);
        _checkBatch(targets, data, values, address(quoteToken), amount);
        bool selected = pool.settler() == settler;

        uint256 quotedOut;
        (quotedOut,,,) = pool.quoteExactInputFor(PAIR, address(vault), CUSTOMER_ID, false, amount);
        uint256 baseBefore = baseToken.balanceOf(address(vault));
        uint256 quoteBefore = quoteToken.balanceOf(address(vault));
        uint256 poolBaseBefore = baseToken.balanceOf(address(pool));
        uint256 poolQuoteBefore = quoteToken.balanceOf(address(pool));
        uint256 creditBefore = _credit();
        if (interference % 4 == 0) oracle.setPrice(oracle.price() + 1, block.timestamp);

        try vault.manage(targets, data, values) {
            if (
                !selected || interference % 4 == 0 || quoteToken.balanceOf(address(vault)) != quoteBefore - amount
                    || baseToken.balanceOf(address(vault)) != baseBefore + quotedOut
                    || baseToken.balanceOf(address(pool)) != poolBaseBefore - quotedOut
                    || quoteToken.balanceOf(address(pool)) != poolQuoteBefore + amount
            ) invariantBroken = true;
            ++completedDeposits;
        } catch (bytes memory reason) {
            if (
                (selected && interference % 4 != 0) || baseToken.balanceOf(address(vault)) != baseBefore
                    || quoteToken.balanceOf(address(vault)) != quoteBefore
                    || baseToken.balanceOf(address(pool)) != poolBaseBefore
                    || quoteToken.balanceOf(address(pool)) != poolQuoteBefore || _credit() != creditBefore
            ) {
                invariantBroken = true;
            }
            _countRejection(!selected, reason);
        }
        _checkNothingLeftBehind();
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
        if (existingQuote >= amount) {
            // Covered by the vault's own inventory: no swap to build, whichever settler the pool selects.
            (address[] memory none, bytes[] memory noData, uint256[] memory noValues) =
                helper.getWithdrawManageCall(address(quoteToken), amount);
            if (none.length != 0 || noData.length != 0 || noValues.length != 0) invariantBroken = true;
            vault.pay(quoteToken, address(this), amount);
            ++completedWithdrawals;
            return;
        }
        (address[] memory targets, bytes[] memory data, uint256[] memory values) =
            helper.getWithdrawManageCall(address(quoteToken), amount);
        bool selected = pool.settler() == settler;
        uint256 shortfall = amount - existingQuote;
        (uint256 quotedBaseIn,,,) = pool.quoteExactOutputFor(PAIR, address(vault), CUSTOMER_ID, true, shortfall);
        _checkBatch(targets, data, values, address(baseToken), 0);
        uint256 baseBefore = baseToken.balanceOf(address(vault));
        uint256 quotePoolBefore = quoteToken.balanceOf(address(pool));
        uint256 creditBefore = _credit();
        if (expire) vmWarp(block.timestamp + 1);

        try vault.manage(targets, data, values) {
            if (
                !selected || expire || quoteToken.balanceOf(address(vault)) != amount
                    || baseToken.balanceOf(address(vault)) != baseBefore - quotedBaseIn
                    || quoteToken.balanceOf(address(pool)) != quotePoolBefore - shortfall
            ) invariantBroken = true;
            vault.pay(quoteToken, address(this), amount);
            ++completedWithdrawals;
        } catch (bytes memory reason) {
            // The Settler checks the deadline, quotes and pulls the input before the pool can refuse its fill.
            bool fundable = !expire && quotedBaseIn <= baseBefore && shortfall <= quotePoolBefore;
            if (selected && fundable) invariantBroken = true;
            if (
                quoteToken.balanceOf(address(vault)) != existingQuote
                    || baseToken.balanceOf(address(vault)) != baseBefore
                    || quoteToken.balanceOf(address(pool)) != quotePoolBefore || _credit() != creditBefore
            ) {
                invariantBroken = true;
            }
            _countRejection(!selected && fundable, reason);
        }
        _checkNothingLeftBehind();
    }

    /// @dev A batch whose swap reaches the pool while it selects another settler (`refused`) must fail there, at the
    /// third call, with the pool's `NotSettler`: the fill the pool no longer takes from the factory's default Settler.
    function _countRejection(bool refused, bytes memory reason) internal {
        if (!refused) {
            ++rejectedBatches;
            return;
        }
        bytes memory notSettler = abi.encodeWithSelector(
            BufferInvariantVault.ManageCallFailed.selector,
            2,
            abi.encodeWithSelector(IManagedDirectPropAMM.NotSettler.selector)
        );
        if (keccak256(reason) != keccak256(notSettler)) invariantBroken = true;
        ++refusedFills;
    }

    /// @dev Approvals name the Settler, never the pool; `approved` is the exact approval, or 0 to skip that check.
    function _checkBatch(
        address[] memory targets,
        bytes[] memory data,
        uint256[] memory values,
        address approvalToken,
        uint256 approved
    ) internal {
        if (targets.length != 4 || data.length != 4 || values.length != 4) {
            invariantBroken = true;
            return;
        }
        if (
            targets[0] != approvalToken || targets[1] != approvalToken || targets[2] != settler
                || targets[3] != approvalToken
        ) invariantBroken = true;
        bytes32 clear = keccak256(abi.encodeWithSignature("approve(address,uint256)", settler, 0));
        if (keccak256(data[0]) != clear || keccak256(data[3]) != clear) invariantBroken = true;
        if (
            approved != 0
                && keccak256(data[1])
                    != keccak256(abi.encodeWithSignature("approve(address,uint256)", settler, approved))
        ) invariantBroken = true;
        for (uint256 i; i < 4; ++i) {
            if (values[i] != 0) invariantBroken = true;
        }
    }

    function _checkNothingLeftBehind() internal {
        if (
            baseToken.allowance(address(vault), settler) != 0 || quoteToken.allowance(address(vault), settler) != 0
                || baseToken.allowance(address(vault), address(pool)) != 0
                || quoteToken.allowance(address(vault), address(pool)) != 0 || baseToken.balanceOf(settler) != 0
                || quoteToken.balanceOf(settler) != 0
        ) invariantBroken = true;
        if (
            baseToken.allowance(address(vault), replacement) != 0
                || quoteToken.allowance(address(vault), replacement) != 0 || baseToken.balanceOf(replacement) != 0
                || quoteToken.balanceOf(replacement) != 0
        ) invariantBroken = true;
    }

    /// @dev The vault's route. The Settler's own route must never hold credit.
    function _credit() internal view returns (uint256) {
        return pool.roundingCredit(pool.roundingRouteKey(PAIR, address(vault), CUSTOMER_ID));
    }

    function vmWarp(uint256 timestamp) internal {
        (bool success,) = address(uint160(uint256(keccak256("hevm cheat code"))))
            .call(abi.encodeWithSignature("warp(uint256)", timestamp));
        require(success);
    }
}

contract SettlerBufferHelperInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_BALANCE = 1e15;
    uint256 internal constant INITIAL_BASE_VAULT = 1e10;
    bytes32 internal constant CUSTOMER_ID = keccak256("buffer-settler-stateful");

    ManagedDirectPropAMM internal pool;
    SettlerBufferHelperInvariantHandler internal handler;
    BufferInvariantVault internal vault;
    MockTIP20 internal baseToken;
    MockTIP20 internal quoteToken;
    address internal settler;

    function setUp() external {
        vm.warp(1_000_000);
        baseToken = new MockTIP20("BASE", 6);
        quoteToken = new MockTIP20("QUOTE", 6);
        MockOracle oracle = new MockOracle(8, 105_000_000, block.timestamp);
        vault = new BufferInvariantVault();
        PoolFactory factory = new PoolFactory();
        handler =
            new SettlerBufferHelperInvariantHandler(factory, vault, baseToken, quoteToken, oracle, INITIAL_BALANCE);
        pool = handler.pool();
        settler = handler.settler();
        assertEq(handler.helper().settler(), factory.defaultSettler());
        baseToken.mint(address(vault), INITIAL_BASE_VAULT);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.selectSettler.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        // Native-fork reproduction only, as in BufferHelperInvariantTest.
        if (vm.envOr("PROPAMM_PIN_INVARIANT_DRIVER", false)) targetSender(address(this));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: coverage.invariant.fail-on-revert = true
    function invariant_settlerBatchesLeaveNothingBehind() external view {
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
        assertEq(baseToken.allowance(address(vault), settler), 0);
        assertEq(quoteToken.allowance(address(vault), settler), 0);
        assertEq(baseToken.allowance(address(vault), address(pool)), 0);
        assertEq(quoteToken.allowance(address(vault), address(pool)), 0);
        assertEq(baseToken.balanceOf(settler), 0);
        assertEq(quoteToken.balanceOf(settler), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(0, settler, CUSTOMER_ID)), 0);
    }

    function test_settlerCampaignStepsAndAReplacedSettler() external {
        handler.deposit(5_000_000, 1);
        assertEq(handler.completedDeposits(), 1);
        handler.withdraw(8_000_000, 500_000, true);
        assertEq(handler.rejectedBatches(), 1);
        handler.selectSettler(0);
        handler.deposit(5_000_000, 1);
        handler.withdraw(8_000_000, 500_000, false);
        assertEq(handler.refusedFills(), 2);
        assertEq(handler.rejectedBatches(), 1);
        handler.selectSettler(1);
        handler.withdraw(8_000_000, 500_000, false);
        assertEq(handler.completedWithdrawals(), 1);
        this.invariant_settlerBatchesLeaveNothingBehind();
    }
}

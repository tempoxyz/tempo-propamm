// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { DirectPropAMMRebalanceController } from "../../src/DirectPropAMMRebalanceController.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { IAddressRegistry } from "../../src/interfaces/IAddressRegistry.sol";
import { IDirectPropAMM } from "../../src/interfaces/IDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { ITIP20 } from "../../src/interfaces/ITIP20.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
import { MockTIP20 } from "../mocks/MockTIP20.sol";
import { MockVirtualAddressRegistry } from "../v2/mocks/MockVirtualAddressRegistry.sol";
import { VirtualAddress } from "../v2/utils/VirtualAddress.sol";

interface IAddressRegistryPrecompile {
    function registerVirtualMaster(bytes32 salt) external returns (bytes4);
}

interface ITIP20Factory {
    function createToken(
        string memory name,
        string memory symbol,
        string memory currency,
        address quoteToken,
        address admin,
        bytes32 salt
    ) external returns (address);
}

interface ITIP20Issuer {
    function ISSUER_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function mint(address to, uint256 amount) external;
}

/// @notice Regressions for managed-pool bugs found in review (reproduced on main at d69180f), with the reproductions'
/// assertions inverted: each now holds as fixed.
/// - A rebalance to a TIP-1022 virtual liquidation address reverted `ExactBalanceDeltaFailed(token, amount, 0)` on
///   every call to the managed pool, because its `withdraw` checked the credit on the virtual address, while
///   `DirectPropAMM` resolves it and pays its master. The managed pool now pays no virtual address, as v2 `Venue`
///   (`withdraw` reverts `VirtualRecipient`), and `DirectPropAMMRebalanceController` refuses a virtual liquidation
///   address for a managed pool at construction (`VirtualLiquidationAddress`), so that keeper path can't be deployed
///   broken. A controller on a `DirectPropAMM` still takes one, and its rebalance pays the master; one on a managed
///   pool rebalances to a plain address. Run on mock tokens and registry, and on Tempo's own precompiles under
///   `--network tempo`.
/// @dev The review's access-script cases tested the TIP-403 `ManagedPoolAccess.s.sol`, which the access rewrite
/// replaced with the sponsor access script of the same name; their analogs live in
/// `contracts/test/managed/ManagedPoolAccess.t.sol` (`test_checkDescribesAnOddAdminWithoutAborting` and
/// `test_listAndDenyRefuseAVirtualAddress`).
contract ManagedDirectPropAMMRegressionTest is Test {
    uint256 internal constant UNIT = 1e6;
    address internal constant ADDRESS_REGISTRY = 0xfDC0000000000000000000000000000000000000;
    address internal constant TIP20_FACTORY = 0x20Fc000000000000000000000000000000000000;
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    /// @dev tempo `test_util::VIRTUAL_MASTER` / `VIRTUAL_SALT`: a precomputed 32-bit proof-of-work pair.
    address internal constant VIRTUAL_MASTER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 internal constant VIRTUAL_SALT = bytes32(uint256(0xabf52baf));

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    /// @dev A plain liquidation address, as a managed pool's controller needs.
    address internal plainLiquidation = makeAddr("plainLiquidation");

    /// @dev The tokens, the oracle, and a virtual liquidation address with its master, on mocks or on Tempo.
    struct Env {
        ITIP20 base;
        ITIP20 quote;
        MockOracle oracle;
        IAddressRegistry registry;
        address master;
        address liquidation;
    }

    // ---------------------------------------------------------------- Virtual liquidation addresses on mocks

    /// @dev The controller refuses a virtual liquidation address for a managed pool, registered or not, at
    /// construction, with the token it was given for.
    function test_mock_managedControllerRefusesAVirtualLiquidationAddress() external {
        _refusesVirtualForManaged(_mockEnv());
    }

    /// @dev On a `DirectPropAMM` the same virtual liquidation address is accepted and `rebalance` pays its master.
    function test_mock_v1ControllerPaysTheVirtualAddressMaster() external {
        _v1PaysTheMaster(_mockEnv());
    }

    /// @dev On a managed pool a plain liquidation address is accepted and `rebalance` pays it exactly.
    function test_mock_managedControllerRebalancesToAPlainAddress() external {
        _managedPaysAPlainAddress(_mockEnv());
    }

    // ---------------------------------------------------------------- Virtual liquidation addresses on Tempo

    /// @dev The same three on Tempo's own precompiles (`--network tempo`): real TIP-20s from the factory and the
    /// TIP-1022 address registry, with a registered virtual master.
    function test_tempo_managedControllerRefusesAVirtualLiquidationAddress() external {
        if (_skipped()) return;
        _refusesVirtualForManaged(_tempoEnv());
    }

    function test_tempo_v1ControllerPaysTheVirtualAddressMaster() external {
        if (_skipped()) return;
        _v1PaysTheMaster(_tempoEnv());
    }

    function test_tempo_managedControllerRebalancesToAPlainAddress() external {
        if (_skipped()) return;
        _managedPaysAPlainAddress(_tempoEnv());
    }

    // ---------------------------------------------------------------- the cases

    function _refusesVirtualForManaged(Env memory env) internal {
        ManagedDirectPropAMM managed = _managed(env);
        address unregistered = VirtualAddress.make(0x0dead001, 1);
        address[2] memory virtuals = [env.liquidation, unregistered];
        for (uint256 i; i < virtuals.length; ++i) {
            // As the base's liquidation address, then as the quote's.
            vm.expectRevert(
                abi.encodeWithSelector(
                    DirectPropAMMRebalanceController.VirtualLiquidationAddress.selector, address(env.base), virtuals[i]
                )
            );
            _newController(address(managed), env, virtuals[i], plainLiquidation);
            vm.expectRevert(
                abi.encodeWithSelector(
                    DirectPropAMMRebalanceController.VirtualLiquidationAddress.selector, address(env.quote), virtuals[i]
                )
            );
            _newController(address(managed), env, plainLiquidation, virtuals[i]);
        }
        // The pool would have refused it on every rebalance too.
        _mint(env.base, address(managed), 8 * UNIT);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, env.liquidation));
        managed.withdraw(address(env.base), env.liquidation, 3 * UNIT, bytes32(0));
        assertEq(env.base.balanceOf(address(managed)), 8 * UNIT);
    }

    function _v1PaysTheMaster(Env memory env) internal {
        DirectPropAMM v1 =
            new DirectPropAMM(env.base, env.quote, env.oracle, env.registry, address(this), guardian, 90_000, 50);
        DirectPropAMMRebalanceController controller =
            _newController(address(v1), env, env.liquidation, plainLiquidation);
        assertEq(controller.liquidationAddress(address(env.base)), env.liquidation);
        _adopt(controller, address(v1));
        _mint(env.base, address(v1), 8 * UNIT);

        vm.prank(keeper);
        controller.rebalance(address(env.base), 3 * UNIT);
        assertEq(env.base.balanceOf(env.master), 3 * UNIT, "v1: the TIP-20 forwards to the master");
        assertEq(env.base.balanceOf(env.liquidation), 0, "the virtual address holds nothing");
        assertEq(env.base.balanceOf(address(v1)), 5 * UNIT);
        assertFalse(v1.paused(), "pause unwound");
    }

    function _managedPaysAPlainAddress(Env memory env) internal {
        ManagedDirectPropAMM managed = _managed(env);
        DirectPropAMMRebalanceController controller =
            _newController(address(managed), env, plainLiquidation, makeAddr("quoteLiquidation"));
        _adopt(controller, address(managed));
        _mint(env.base, address(managed), 8 * UNIT);

        vm.prank(keeper);
        controller.rebalance(address(env.base), 3 * UNIT);
        assertEq(env.base.balanceOf(plainLiquidation), 3 * UNIT, "the plain address gets its exact credit");
        assertEq(env.base.balanceOf(address(managed)), 5 * UNIT, "exactly the amount left");
        assertFalse(managed.paused(), "pause unwound");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Mock tokens that forward a transfer to a registered virtual address to its master, as Tempo's TIP-20 does.
    function _mockEnv() internal returns (Env memory env) {
        vm.warp(1_000_000);
        MockVirtualAddressRegistry resolver = new MockVirtualAddressRegistry();
        MockTIP20 busd = new MockTIP20("BUSD", 6);
        MockTIP20 ousd = new MockTIP20("OUSD", 6);
        busd.setResolver(resolver);
        ousd.setResolver(resolver);
        env.base = busd;
        env.quote = ousd;
        env.oracle = new MockOracle(8, 1e8, block.timestamp);
        env.registry = resolver;
        env.master = makeAddr("bridgeMaster");
        env.liquidation = VirtualAddress.make(0x0badf00d, 1);
        resolver.setVirtual(env.liquidation, env.master);
    }

    /// @dev Factory TIP-20s and a virtual address registered on the TIP-1022 precompile.
    function _tempoEnv() internal returns (Env memory env) {
        vm.warp(1_000_000);
        env.base = _tip20("BUSD", 1);
        env.quote = _tip20("OUSD", 2);
        env.oracle = new MockOracle(8, 1e8, block.timestamp);
        env.registry = IAddressRegistry(ADDRESS_REGISTRY);
        env.master = VIRTUAL_MASTER;
        vm.prank(VIRTUAL_MASTER);
        bytes4 masterId = IAddressRegistryPrecompile(ADDRESS_REGISTRY).registerVirtualMaster(VIRTUAL_SALT);
        env.liquidation = VirtualAddress.make(uint32(masterId), 0x010203040506);
    }

    function _skipped() internal returns (bool) {
        if (ADDRESS_REGISTRY.code.length != 0) return false;
        vm.skip(true, "needs --network tempo");
        return true;
    }

    /// @dev A controller for `pool` (either kind) with `baseLiquidation` for the base and `quoteLiquidation` for the
    /// quote.
    function _newController(address pool, Env memory env, address baseLiquidation, address quoteLiquidation)
        internal
        returns (DirectPropAMMRebalanceController)
    {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(env.base), address(env.quote));
        address[] memory liquidations = new address[](2);
        (liquidations[0], liquidations[1]) = (baseLiquidation, quoteLiquidation);
        return new DirectPropAMMRebalanceController(IDirectPropAMM(pool), owner, keeper, tokens, liquidations);
    }

    /// @dev Hands `pool` (owned by this test until now) to `c` and unpauses it through `c`.
    function _adopt(DirectPropAMMRebalanceController c, address pool) internal {
        DirectPropAMM(pool).transferOwnership(address(c));
        vm.startPrank(owner);
        c.execute(abi.encodeCall(DirectPropAMM.acceptOwnership, ()));
        c.execute(abi.encodeCall(DirectPropAMM.unpause, ()));
        vm.stopPrank();
    }

    /// @dev A managed pool with the repro's one pair, `Listed` and still paused, owned by this test.
    function _managed(Env memory env) internal returns (ManagedDirectPropAMM managed) {
        managed = new ManagedDirectPropAMM(address(this), address(0));
        managed.addPair(address(env.base), address(env.quote), env.oracle, 90_000, 50);
        managed.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
    }

    function _tip20(string memory symbol, uint256 salt) internal returns (ITIP20 token) {
        token = ITIP20(
            ITIP20Factory(TIP20_FACTORY).createToken(symbol, symbol, "USD", PATH_USD, address(this), bytes32(salt))
        );
        ITIP20Issuer(address(token)).grantRole(ITIP20Issuer(address(token)).ISSUER_ROLE(), address(this));
    }

    /// @dev Mints a factory TIP-20 as its issuer, or a mock (whose `mint` has the same signature).
    function _mint(ITIP20 token, address to, uint256 amount) internal {
        ITIP20Issuer(address(token)).mint(to, amount);
    }
}

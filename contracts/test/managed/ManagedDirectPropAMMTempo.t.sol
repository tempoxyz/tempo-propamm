// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { DirectPropAMM } from "../../src/DirectPropAMM.sol";
import { ManagedDirectPropAMM } from "../../src/managed/ManagedDirectPropAMM.sol";
import { IAddressRegistry } from "../../src/interfaces/IAddressRegistry.sol";
import { IManagedDirectPropAMM } from "../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { ITIP20 } from "../../src/interfaces/ITIP20.sol";
import { MockOracle } from "../mocks/MockOracle.sol";
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

/// @notice `ManagedDirectPropAMM` on Tempo's own precompiles (`forge test --network tempo`): real TIP-20s from the
/// factory and the TIP-1022 address registry, which the pool doesn't use. A withdrawal to a virtual address reverts
/// `VirtualRecipient` with nothing moved, whether the registry knows it (a Bridge liquidation address, with a real
/// master) or not, where `DirectPropAMM` resolves a registered one and pays its master: an intended divergence, as in
/// v2 `Venue`. An ordinary recipient gets its exact credit, so the pool pays a liquidation address through an account.
/// Swaps pay their caller on real TIP-20s, pairs share a real TIP-20's inventory, and `fund` pulls one exactly.
/// @dev Skips without `--network tempo`; the mock cases are in `ManagedDirectPropAMM.t.sol`.
contract ManagedDirectPropAMMTempoTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant PRICE = 105_000_000;
    address internal constant ADDRESS_REGISTRY = 0xfDC0000000000000000000000000000000000000;
    address internal constant TIP20_FACTORY = 0x20Fc000000000000000000000000000000000000;
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    /// @dev tempo `test_util::VIRTUAL_MASTER` / `VIRTUAL_SALT`: a precomputed 32-bit proof-of-work pair.
    address internal constant VIRTUAL_MASTER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 internal constant VIRTUAL_SALT = bytes32(uint256(0xabf52baf));

    address internal guardian = makeAddr("guardian");
    address internal taker = makeAddr("taker");
    address internal treasury = makeAddr("treasury");
    ITIP20 internal base;
    ITIP20 internal quote;
    MockOracle internal oracle;
    ManagedDirectPropAMM internal pool;
    DirectPropAMM internal v1;
    address internal liquidation;

    function setUp() external {
        if (ADDRESS_REGISTRY.code.length == 0) return;
        vm.warp(1_000_000);
        base = _tip20("BUSD", 1);
        quote = _tip20("OUSD", 2);
        oracle = new MockOracle(8, PRICE, block.timestamp);
        vm.prank(VIRTUAL_MASTER);
        bytes4 masterId = IAddressRegistryPrecompile(ADDRESS_REGISTRY).registerVirtualMaster(VIRTUAL_SALT);
        liquidation = VirtualAddress.make(uint32(masterId), 0x010203040506);

        pool = new ManagedDirectPropAMM(address(this), address(0));
        pool.addPair(address(base), address(quote), oracle, 90_000, 50);
        pool.setPairAccess(0, IManagedDirectPropAMM.AccessMode.Listed);
        pool.unpause();
        v1 = new DirectPropAMM(
            base, quote, oracle, IAddressRegistry(ADDRESS_REGISTRY), address(this), guardian, 90_000, 50
        );
        _mint(base, address(pool), 8 * UNIT);
        _mint(quote, address(pool), 8 * UNIT);
        _mint(base, address(v1), 8 * UNIT);
    }

    function _skipped() internal returns (bool) {
        if (ADDRESS_REGISTRY.code.length != 0) return false;
        vm.skip(true, "needs --network tempo");
        return true;
    }

    /// @dev A registered virtual address, which the precompile resolves to its master and the TIP-20 would forward to
    /// it, is refused by the pool's own check: nothing moves, on either token, while the pool trades or paused.
    function test_withdrawToARegisteredVirtualAddressReverts() external {
        if (_skipped()) return;
        assertEq(IAddressRegistry(ADDRESS_REGISTRY).resolveRecipient(liquidation), VIRTUAL_MASTER, "registered");
        ITIP20[2] memory tokens = [base, quote];
        for (uint256 paused; paused < 2; ++paused) {
            if (paused == 1) pool.pause();
            for (uint256 t; t < 2; ++t) {
                vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, liquidation));
                pool.withdraw(address(tokens[t]), liquidation, 3 * UNIT, bytes32("rebalance"));
                assertEq(tokens[t].balanceOf(address(pool)), 8 * UNIT, "nothing left the pool");
                assertEq(tokens[t].balanceOf(VIRTUAL_MASTER), 0, "the master is not paid");
                assertEq(tokens[t].balanceOf(liquidation), 0);
            }
        }
    }

    /// @dev The intended divergence from v1: `DirectPropAMM` resolves the registered virtual address and pays its
    /// master; the managed pool refuses it. The managed pool pays it the supported way, to an account that sends it on,
    /// and the TIP-20 forwards that transfer to the master, so both pools end with the same inventory.
    function test_withdrawToAVirtualAddressDivergesFromV1() external {
        if (_skipped()) return;
        v1.withdraw(address(base), liquidation, 3 * UNIT, bytes32(0));
        assertEq(base.balanceOf(VIRTUAL_MASTER), 3 * UNIT, "v1 pays the master");
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, liquidation));
        pool.withdraw(address(base), liquidation, 3 * UNIT, bytes32(0));
        assertEq(base.balanceOf(VIRTUAL_MASTER), 3 * UNIT, "managed pays no virtual address");

        pool.withdraw(address(base), treasury, 3 * UNIT, bytes32(0));
        assertEq(base.balanceOf(treasury), 3 * UNIT, "the account gets its exact credit");
        vm.prank(treasury);
        base.transferWithMemo(liquidation, 3 * UNIT, bytes32(0));
        assertEq(base.balanceOf(VIRTUAL_MASTER), 6 * UNIT, "the TIP-20 forwards the account's transfer");
        assertEq(base.balanceOf(liquidation), 0, "the virtual address holds nothing");
        assertEq(base.balanceOf(address(pool)), base.balanceOf(address(v1)));
    }

    /// @dev An unregistered virtual address reverts the same way: the layout alone decides, not the registry.
    function test_withdrawToAnUnregisteredVirtualAddressReverts() external {
        if (_skipped()) return;
        address unregistered = VirtualAddress.make(0x0badf00d, 1);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, unregistered));
        pool.withdraw(address(base), unregistered, UNIT, bytes32(0));
        assertEq(base.balanceOf(address(pool)), 8 * UNIT);
    }

    /// @dev Zero and the pool revert `InvalidAddress` on real TIP-20s, with nothing moved.
    function test_withdrawToZeroOrThePoolReverts() external {
        if (_skipped()) return;
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.withdraw(address(base), address(0), UNIT, bytes32(0));
        vm.expectRevert(IManagedDirectPropAMM.InvalidAddress.selector);
        pool.withdraw(address(base), address(pool), UNIT, bytes32(0));
        assertEq(base.balanceOf(address(pool)), 8 * UNIT);
    }

    /// @dev A swap on real TIP-20s pays its caller exactly.
    function test_swapPaysTheCallerOnRealTip20s() external {
        if (_skipped()) return;
        address[] memory one = new address[](1);
        one[0] = taker;
        pool.setMembers(0, 0, one, true);
        _mint(base, taker, 2 * UNIT);
        vm.prank(taker);
        ITIP20Approve(address(base)).approve(address(pool), 2 * UNIT);
        vm.prank(taker);
        uint256 out =
            pool.swapExactInput(0, true, 2 * UNIT, 0, 0, bytes32("c"), bytes32("t"), block.timestamp, PRICE, 0, 0);
        assertEq(out, 2_100_000);
        assertEq(quote.balanceOf(taker), out);
        assertEq(base.balanceOf(address(pool)), 10 * UNIT);
    }

    /// @dev Two pairs on real TIP-20s share the quote token's inventory: a swap on the second pair pays from the same
    /// OUSD balance, exact in and exact out, and once the first pair's swaps drain it the second reverts with the
    /// pool's whole balance as `available`.
    function test_pairsShareRealTip20Inventory() external {
        if (_skipped()) return;
        ITIP20 other = _tip20("XUSD", 3);
        MockOracle otherOracle = new MockOracle(8, 2e8, block.timestamp);
        uint16 second = pool.addPair(address(other), address(quote), otherOracle, 90_000, 50);
        pool.setPairAccess(second, IManagedDirectPropAMM.AccessMode.Listed);
        address[] memory one = new address[](1);
        one[0] = taker;
        pool.setMembers(0, 0, one, true);
        pool.setMembers(second, 0, one, true);
        _mint(base, taker, 10 * UNIT);
        _mint(other, taker, 10 * UNIT);
        vm.startPrank(taker);
        ITIP20Approve(address(base)).approve(address(pool), type(uint256).max);
        ITIP20Approve(address(other)).approve(address(pool), type(uint256).max);
        vm.stopPrank();
        assertEq(pool.tokenPairCount(address(quote)), 2);

        // 1 XUSD at 2.00 pays 2 OUSD from the shared 8.
        vm.prank(taker);
        assertEq(
            pool.swapExactInput(second, true, UNIT, 0, 0, bytes32("c"), bytes32("t"), block.timestamp, 2e8, 0, 0),
            2 * UNIT
        );
        // Exact out on the first pair: 2.1 OUSD costs 2 BUSD.
        vm.prank(taker);
        assertEq(
            pool.swapExactOutput(
                0, true, 2_100_000, type(uint256).max, 0, bytes32("c"), bytes32("t"), block.timestamp, PRICE, 0, 0
            ),
            2 * UNIT
        );
        assertEq(quote.balanceOf(address(pool)), 8 * UNIT - 2 * UNIT - 2_100_000);
        assertEq(quote.balanceOf(taker), 4_100_000);
        // 3.9 OUSD is left: 2 XUSD would need 4.
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedDirectPropAMM.InsufficientInventory.selector, address(quote), 3_900_000, 4 * UNIT
            )
        );
        vm.prank(taker);
        pool.swapExactInput(second, true, 2 * UNIT, 0, 0, bytes32("c"), bytes32("t"), block.timestamp, 2e8, 0, 0);
    }

    /// @dev `fund` pulls a real TIP-20 exactly from the owner, paused or not; `withdraw` pays while trading; a removed
    /// pair's token can't be funded but can still be withdrawn.
    function test_fundAndWithdrawRealTip20s() external {
        if (_skipped()) return;
        _mint(quote, address(this), 5 * UNIT);
        ITIP20Approve(address(quote)).approve(address(pool), type(uint256).max);
        pool.fund(address(quote), 2 * UNIT, bytes32("f"));
        pool.pause();
        pool.fund(address(quote), 3 * UNIT, bytes32("f"));
        pool.unpause();
        assertEq(quote.balanceOf(address(pool)), 13 * UNIT);
        assertEq(quote.balanceOf(address(this)), 0);
        pool.withdraw(address(quote), treasury, 4 * UNIT, bytes32("w"));
        assertEq(quote.balanceOf(treasury), 4 * UNIT);

        pool.removePair(0);
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.UnsupportedToken.selector, address(base)));
        pool.fund(address(base), UNIT, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IManagedDirectPropAMM.VirtualRecipient.selector, liquidation));
        pool.withdraw(address(base), liquidation, 8 * UNIT, bytes32("w"));
        pool.withdraw(address(base), treasury, 8 * UNIT, bytes32("w"));
        assertEq(base.balanceOf(treasury), 8 * UNIT, "a removed pair's inventory leaves, to an account");
        assertEq(base.balanceOf(address(pool)), 0);
    }

    function _tip20(string memory symbol, uint256 salt) internal returns (ITIP20 token) {
        token = ITIP20(
            ITIP20Factory(TIP20_FACTORY).createToken(symbol, symbol, "USD", PATH_USD, address(this), bytes32(salt))
        );
        ITIP20Issuer(address(token)).grantRole(ITIP20Issuer(address(token)).ISSUER_ROLE(), address(this));
    }

    function _mint(ITIP20 token, address to, uint256 amount) internal {
        ITIP20Issuer(address(token)).mint(to, amount);
    }
}

interface ITIP20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

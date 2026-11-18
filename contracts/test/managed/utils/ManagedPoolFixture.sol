// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { MockOracle } from "../../mocks/MockOracle.sol";
import { MockTIP20 } from "../../mocks/MockTIP20.sol";
import { MockVirtualAddressRegistry } from "../../v2/mocks/MockVirtualAddressRegistry.sol";

/// @notice A two-pair `ManagedDirectPropAMM`, owned by the test contract: PRIME/pathUSD (pair 0, 6/6 decimals, PRIME at
/// $1.05) and EURX/pathUSD (pair 1, an 18-decimal base at $1.085). The two pairs share pathUSD inventory. Both pairs
/// are `Listed` with empty lists, the pool is unpaused and funded, and the takers hold and have approved every token.
/// Every token forwards a transfer to a registered TIP-1022 virtual address to its master, as Tempo's TIP-20 does
/// (`registry`); the pool itself holds no registry and pays no virtual address.
abstract contract ManagedPoolFixture is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant EUR_UNIT = 1e18;
    /// @dev 8-decimal oracle prices.
    uint256 internal constant PRIME_PRICE = 105_000_000;
    uint256 internal constant EUR_PRICE = 108_500_000;
    /// @dev 10 PRIME at `PRIME_PRICE`, in pathUSD.
    uint256 internal constant PRIME_OUT = 10_500_000;
    /// @dev 1 EURX at `EUR_PRICE`, in pathUSD.
    uint256 internal constant EUR_OUT = 1_085_000;
    uint256 internal constant MAX_AGE = 90_000;
    uint256 internal constant MAX_DEVIATION_BPS = 50;
    uint256 internal constant MAX_BATCH = 100;
    uint16 internal constant PRIME_PAIR = 0;
    uint16 internal constant EUR_PAIR = 1;
    /// @dev The `sponsorId` that names a pair's home list.
    uint64 internal constant HOME = 0;
    /// @dev Sponsors the suites register where needed: `ALPHA` (admin `alpha`) and `BETA` (admin `beta`).
    uint64 internal constant ALPHA = 7;
    uint64 internal constant BETA = 9;
    bytes32 internal constant CUSTOMER = bytes32("customer");
    bytes32 internal constant TRADE = bytes32("trade");

    address internal unauthorized = makeAddr("unauthorized");
    address internal stranger = makeAddr("stranger");
    /// @dev On the home lists in most tests.
    address internal taker = makeAddr("taker");
    /// @dev On `ALPHA`'s lists in most tests.
    address internal member = makeAddr("member");
    address internal alpha = makeAddr("alpha");
    address internal beta = makeAddr("beta");

    /// @dev The tokens' TIP-1022 resolver, not the pool's: it has none.
    MockVirtualAddressRegistry internal registry;
    MockTIP20 internal prime;
    MockTIP20 internal pathUsd;
    MockTIP20 internal eurx;
    MockOracle internal primeOracle;
    MockOracle internal eurOracle;
    ManagedDirectPropAMM internal pool;

    function setUp() public virtual {
        vm.warp(1_000_000);
        registry = new MockVirtualAddressRegistry();
        prime = new MockTIP20("PRIME", 6);
        pathUsd = new MockTIP20("pathUSD", 6);
        eurx = new MockTIP20("EURX", 18);
        prime.setResolver(registry);
        pathUsd.setResolver(registry);
        eurx.setResolver(registry);
        primeOracle = new MockOracle(8, PRIME_PRICE, block.timestamp);
        eurOracle = new MockOracle(8, EUR_PRICE, block.timestamp);

        pool = new ManagedDirectPropAMM(address(this), address(0));
        pool.addPair(address(prime), address(pathUsd), primeOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.addPair(address(eurx), address(pathUsd), eurOracle, MAX_AGE, MAX_DEVIATION_BPS);
        pool.setPairAccess(PRIME_PAIR, IManagedDirectPropAMM.AccessMode.Listed);
        pool.setPairAccess(EUR_PAIR, IManagedDirectPropAMM.AccessMode.Listed);

        prime.mint(address(pool), 1_000_000 * UNIT);
        pathUsd.mint(address(pool), 2_000_000 * UNIT);
        eurx.mint(address(pool), 1_000_000 * EUR_UNIT);
        address[3] memory takers = [taker, member, stranger];
        for (uint256 i; i < takers.length; ++i) {
            _fundTaker(takers[i]);
        }
        pool.unpause();
    }

    // ---------------------------------------------------------------- helpers

    function _fundTaker(address account) internal {
        prime.mint(account, 1_000_000 * UNIT);
        pathUsd.mint(account, 1_000_000 * UNIT);
        eurx.mint(account, 1_000_000 * EUR_UNIT);
        vm.startPrank(account);
        prime.approve(address(pool), type(uint256).max);
        pathUsd.approve(address(pool), type(uint256).max);
        eurx.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _oracle(uint16 pairIndex) internal view returns (MockOracle) {
        return pairIndex == PRIME_PAIR ? primeOracle : eurOracle;
    }

    /// @dev One base unit of the pair's base token.
    function _baseUnit(uint16 pairIndex) internal pure returns (uint256) {
        return pairIndex == PRIME_PAIR ? UNIT : EUR_UNIT;
    }

    function _listHome(uint16 pairIndex, address account) internal {
        pool.setMembers(pairIndex, HOME, _one(account), true);
    }

    /// @dev Registers `ALPHA` (admin `alpha`) and admits it on both pairs.
    function _addAlpha() internal {
        pool.addSponsor(ALPHA, alpha);
        pool.setPairSponsor(PRIME_PAIR, ALPHA, true);
        pool.setPairSponsor(EUR_PAIR, ALPHA, true);
    }

    function _listAlpha(uint16 pairIndex, address account) internal {
        vm.prank(alpha);
        pool.setMembers(pairIndex, ALPHA, _one(account), true);
    }

    /// @dev Enters `mode`, pausing around it for `Open` when the pool is active.
    function _setAccess(uint16 pairIndex, IManagedDirectPropAMM.AccessMode mode) internal {
        bool wasPaused = pool.paused();
        if (mode == IManagedDirectPropAMM.AccessMode.Open && !wasPaused) pool.pause();
        pool.setPairAccess(pairIndex, mode);
        if (mode == IManagedDirectPropAMM.AccessMode.Open && !wasPaused) pool.unpause();
    }

    /// @dev `from` sells 10 base units on the pair (exact input) at the oracle's current price under `sponsorId`.
    function _sell(uint16 pairIndex, address from, uint64 sponsorId) internal returns (uint256 amountOut) {
        return _sellFor(pairIndex, from, sponsorId, CUSTOMER, 10 * _baseUnit(pairIndex));
    }

    function _sellFor(uint16 pairIndex, address from, uint64 sponsorId, bytes32 customerId, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (uint256 price,) = _oracle(pairIndex).latestPrice();
        vm.prank(from);
        amountOut = pool.swapExactInput(
            pairIndex, true, amountIn, 0, sponsorId, customerId, TRADE, block.timestamp, price, 0, 0
        );
    }

    function _expectSellRevert(bytes memory err, uint16 pairIndex, address from, uint64 sponsorId) internal {
        (uint256 price,) = _oracle(pairIndex).latestPrice();
        uint256 amountIn = 10 * _baseUnit(pairIndex);
        vm.expectRevert(err);
        vm.prank(from);
        pool.swapExactInput(pairIndex, true, amountIn, 0, sponsorId, CUSTOMER, TRADE, block.timestamp, price, 0, 0);
    }

    function _access(uint16 pairIndex, address account, uint64 sponsorId)
        internal
        view
        returns (IManagedDirectPropAMM.TakerAccess)
    {
        return pool.takerAccess(pairIndex, account, sponsorId);
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _accounts(uint256 n) internal pure returns (address[] memory accounts) {
        accounts = new address[](n);
        for (uint256 i; i < n; ++i) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode("account", i)))));
        }
    }
}

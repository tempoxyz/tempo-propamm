// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PoolFactory } from "../../../src/managed/PoolFactory.sol";
import { ManagedDirectPropAMM } from "../../../src/managed/ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM as IM } from "../../../src/managed/interfaces/IManagedDirectPropAMM.sol";
import { ISettler } from "../../../src/managed/interfaces/ISettler.sol";
import { IDirectPropAMM } from "../../../src/interfaces/IDirectPropAMM.sol";
import { DirectPropAMMBufferHelper } from "../../../src/DirectPropAMMBufferHelper.sol";
import { MockOracle } from "../../mocks/MockOracle.sol";

interface LiveVault is IERC20 {
    function manage(address[] calldata, bytes[] calldata, uint256[] calldata) external returns (bytes[] memory);
}

interface LiveTeller {
    function allowBufferHelper(address, address) external;
    function setDepositBufferHelper(address, address) external;
    function setWithdrawBufferHelper(address, address) external;
    function bulkDeposit(address, uint256, uint256, address) external returns (uint256);
    function bulkWithdraw(address, uint256, uint256, address) external returns (uint256);
    function authority() external view returns (address);
}

interface LiveAuthority {
    function setRoleCapability(uint8, address, bytes4, bool) external;
    function setUserRole(address, uint8, bool) external;
}

/// @notice Opt-in integration against Veda-deployed Tempo mainnet contracts, never a mainnet broadcast.
/// @dev Fork-only role grants, transfers from existing holders and a fixed-price oracle isolate settlement from NAV/oracle policy.
contract VedaManagedForkTest is Test {
    uint256 internal constant FORK_BLOCK = 47_293_384;
    address internal constant VAULT = 0xE4a4127E2133E6700924fb3eA1e7489D1c6f1529;
    address internal constant TELLER = 0x06a58cCE5Bc99205E56A9Fe917E2124d3A7cAb21;
    address internal constant ADMIN = 0x3D010a7253E9Acc2b872364C8c3D109CaA60F49C;
    address internal constant QUOTE = 0x20c0000000000000000000006a37DA5C996874BE;
    address internal constant BASE = 0x20C00000000000000000000058d0B8b2CFDb358c;
    bytes32 internal constant CUSTOMER = keccak256("veda-fork");
    ManagedDirectPropAMM internal pool;
    DirectPropAMMBufferHelper internal helper;
    address internal settler;

    function setUp() public {
        string memory rpc = vm.envOr("VEDA_TEMPO_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 4217);
        assertGt(VAULT.code.length, 0);
        assertGt(TELLER.code.length, 0);
        PoolFactory factory = new PoolFactory();
        settler = factory.defaultSettler();
        pool = ManagedDirectPropAMM(factory.createPool(address(this), CUSTOMER));
        pool.addPair(BASE, QUOTE, new MockOracle(6, 1_050_000, block.timestamp), 1 days, 1000);
        address[] memory members = new address[](1);
        members[0] = VAULT;
        pool.setMembers(0, 0, members, true);
        pool.setPairAccess(0, IM.AccessMode.Listed);
        vm.prank(0x2C22026217d2275F1883FEbF161863dC0b0A43B2);
        IERC20(BASE).transfer(address(pool), 1_000e6);
        vm.startPrank(0x0D136e26B4D9e4836fc5cb202baeb49Cb6f5df48);
        IERC20(QUOTE).transfer(address(pool), 1_000e6);
        IERC20(QUOTE).transfer(address(this), 100e6);
        vm.stopPrank();
        pool.unpause();
        helper = new DirectPropAMMBufferHelper(IDirectPropAMM(address(pool)), VAULT, CUSTOMER, 0, 0, 0);
        LiveAuthority authority = LiveAuthority(LiveTeller(TELLER).authority());
        vm.startPrank(ADMIN);
        authority.setRoleCapability(254, TELLER, LiveTeller.allowBufferHelper.selector, true);
        authority.setRoleCapability(254, TELLER, LiveTeller.setDepositBufferHelper.selector, true);
        authority.setRoleCapability(254, TELLER, LiveTeller.setWithdrawBufferHelper.selector, true);
        authority.setRoleCapability(254, TELLER, LiveTeller.bulkDeposit.selector, true);
        authority.setRoleCapability(254, TELLER, LiveTeller.bulkWithdraw.selector, true);
        authority.setUserRole(address(this), 254, true);
        vm.stopPrank();
        LiveTeller(TELLER).allowBufferHelper(QUOTE, address(helper));
        LiveTeller(TELLER).setDepositBufferHelper(QUOTE, address(helper));
        LiveTeller(TELLER).setWithdrawBufferHelper(QUOTE, address(helper));
        IERC20(QUOTE).approve(VAULT, type(uint256).max);
    }

    function test_liveTellerDepositAndRedeem() public {
        uint256 baseBefore = IERC20(BASE).balanceOf(VAULT);
        uint256 quoteBefore = IERC20(QUOTE).balanceOf(VAULT);
        uint256 shares = LiveTeller(TELLER).bulkDeposit(QUOTE, 10e6, 1, address(this));
        assertGt(shares, 0);
        assertEq(IERC20(VAULT).balanceOf(address(this)), shares);
        assertGt(IERC20(BASE).balanceOf(VAULT), baseBefore);
        assertEq(IERC20(QUOTE).balanceOf(VAULT), quoteBefore);
        assertEq(IERC20(QUOTE).allowance(VAULT, address(pool)), 0);
        uint256 before = IERC20(QUOTE).balanceOf(address(this));
        uint256 out = LiveTeller(TELLER).bulkWithdraw(QUOTE, shares, 1, address(this));
        assertEq(IERC20(QUOTE).balanceOf(address(this)) - before, out);
        assertGt(out, 9_990_000);
        assertLe(out, 10e6);
        assertEq(IERC20(VAULT).balanceOf(address(this)), 0);
        assertEq(IERC20(BASE).allowance(VAULT, address(pool)), 0);
        assertGe(IERC20(BASE).balanceOf(VAULT), baseBefore);
    }

    function test_pausedDepositRollsBackSharesAndTokens() public {
        pool.pause();
        uint256 supply = IERC20(VAULT).totalSupply();
        uint256 balance = IERC20(QUOTE).balanceOf(address(this));
        vm.expectRevert(IM.Paused.selector);
        LiveTeller(TELLER).bulkDeposit(QUOTE, 10e6, 1, address(this));
        assertEq(IERC20(VAULT).totalSupply(), supply);
        assertEq(IERC20(QUOTE).balanceOf(address(this)), balance);
        assertEq(IERC20(QUOTE).allowance(VAULT, address(pool)), 0);
    }

    function test_idleQuoteAvoidsSwapWhenPoolPaused() public {
        uint256 shares = LiveTeller(TELLER).bulkDeposit(QUOTE, 10e6, 1, address(this));
        IERC20(QUOTE).transfer(VAULT, 10e6);
        uint256 baseBefore = IERC20(BASE).balanceOf(VAULT);
        pool.pause();
        (address[] memory targets,,) = helper.getWithdrawManageCall(QUOTE, 10e6);
        assertEq(targets.length, 0);
        assertGt(LiveTeller(TELLER).bulkWithdraw(QUOTE, shares, 1, address(this)), 9_990_000);
        assertEq(IERC20(BASE).balanceOf(VAULT), baseBefore);
    }

    function test_partialIdleQuoteSellsOnlyShortfall() public {
        uint256 shares = LiveTeller(TELLER).bulkDeposit(QUOTE, 10e6, 1, address(this));
        IERC20(QUOTE).transfer(VAULT, 4e6);
        uint256 idle = IERC20(QUOTE).balanceOf(VAULT);
        uint256 poolQuote = IERC20(QUOTE).balanceOf(address(pool));
        uint256 out = LiveTeller(TELLER).bulkWithdraw(QUOTE, shares, 1, address(this));
        assertGt(out, idle);
        assertEq(poolQuote - IERC20(QUOTE).balanceOf(address(pool)), out - idle);
        assertEq(IERC20(QUOTE).balanceOf(VAULT), 0);
        assertEq(IERC20(BASE).allowance(VAULT, address(pool)), 0);
    }

    function test_pausedRedemptionRollsBackSharesAndTokens() public {
        uint256 shares = LiveTeller(TELLER).bulkDeposit(QUOTE, 10e6, 1, address(this));
        uint256 supply = IERC20(VAULT).totalSupply();
        uint256 balance = IERC20(QUOTE).balanceOf(address(this));
        uint256 baseBalance = IERC20(BASE).balanceOf(VAULT);
        pool.pause();
        vm.expectRevert(IM.Paused.selector);
        LiveTeller(TELLER).bulkWithdraw(QUOTE, shares, 1, address(this));
        assertEq(IERC20(VAULT).totalSupply(), supply);
        assertEq(IERC20(VAULT).balanceOf(address(this)), shares);
        assertEq(IERC20(QUOTE).balanceOf(address(this)), balance);
        assertEq(IERC20(BASE).balanceOf(VAULT), baseBalance);
        assertEq(IERC20(BASE).allowance(VAULT, address(pool)), 0);
    }

    function test_unlistedVaultCannotDeposit() public {
        address[] memory members = new address[](1);
        members[0] = VAULT;
        pool.setMembers(0, 0, members, false);
        uint256 balance = IERC20(QUOTE).balanceOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(IM.TakerNotAllowed.selector, VAULT));
        LiveTeller(TELLER).bulkDeposit(QUOTE, 10e6, 1, address(this));
        assertEq(IERC20(QUOTE).balanceOf(address(this)), balance);
        assertEq(IERC20(VAULT).balanceOf(address(this)), 0);
    }

    function test_realVaultCanUseFactorySettler() public {
        IERC20(QUOTE).transfer(VAULT, 10e6);
        IM.SwapParams memory params = IM.SwapParams(
            0, false, true, 10e6, 9e6, 0, CUSTOMER, bytes32("trade"), block.timestamp, 1_050_000, 0, block.timestamp
        );
        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);
        targets[0] = QUOTE;
        targets[1] = settler;
        targets[2] = QUOTE;
        data[0] = abi.encodeCall(IERC20.approve, (settler, 10e6));
        data[1] = abi.encodeCall(ISettler.swap, (address(pool), params));
        data[2] = abi.encodeCall(IERC20.approve, (settler, 0));
        uint256 before = IERC20(BASE).balanceOf(VAULT);
        vm.prank(ADMIN);
        LiveVault(VAULT).manage(targets, data, values);
        assertGt(IERC20(BASE).balanceOf(VAULT) - before, 9e6);
        assertEq(IERC20(QUOTE).balanceOf(settler), 0);
        assertEq(IERC20(BASE).balanceOf(settler), 0);
        assertEq(IERC20(QUOTE).allowance(VAULT, settler), 0);
    }
}

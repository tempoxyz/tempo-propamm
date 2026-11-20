// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeployManagedBufferHelpers } from "../../script/managed/DeployManagedBufferHelpers.s.sol";
import { DirectPropAMMBufferHelper } from "../../src/DirectPropAMMBufferHelper.sol";
import { ManagedPoolFixture } from "./utils/ManagedPoolFixture.sol";

contract DeployManagedBufferHelpersTest is ManagedPoolFixture {
    bytes32 internal constant ID_A = keccak256("vault-a");
    bytes32 internal constant ID_B = keccak256("vault-b");

    DeployManagedBufferHelpers internal script;
    address internal vaultA = makeAddr("vaultA");
    address internal vaultB = makeAddr("vaultB");

    function setUp() public override {
        super.setUp();
        vm.chainId(42431);
        script = new DeployManagedBufferHelpers();
    }

    function test_deploysOneHelperPerEntry() external {
        address[] memory deployed = script.deploy(
            address(pool), _vaults(), _two(PRIME_PAIR, EUR_PAIR), _two(HOME, ALPHA), _ids(), _two(50, 25)
        );

        assertEq(deployed.length, 2);
        DirectPropAMMBufferHelper a = DirectPropAMMBufferHelper(deployed[0]);
        DirectPropAMMBufferHelper b = DirectPropAMMBufferHelper(deployed[1]);
        assertTrue(a.managed());
        assertEq(address(a.pool()), address(pool));
        assertEq(a.vault(), vaultA);
        assertEq(a.pairIndex(), PRIME_PAIR);
        assertEq(a.sponsorId(), HOME);
        assertEq(a.baseToken(), address(prime));
        assertEq(a.quoteToken(), address(pathUsd));
        assertEq(a.customerId(), ID_A);
        assertEq(a.slippageBps(), 50);
        assertEq(b.vault(), vaultB);
        assertEq(b.pairIndex(), EUR_PAIR);
        assertEq(b.sponsorId(), ALPHA);
        assertEq(b.baseToken(), address(eurx));
        assertEq(b.customerId(), ID_B);
        assertEq(b.slippageBps(), 25);
    }

    function test_rejectsOtherChain() external {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployManagedBufferHelpers.UnexpectedChain.selector, 1));
        script.deploy(address(pool), _vaults(), _two(PRIME_PAIR, EUR_PAIR), _two(HOME, ALPHA), _ids(), _two(50, 25));
    }

    function test_rejectsListsOfDifferentLengths() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployManagedBufferHelpers.InvalidConfig.selector, "HELPER_* lists need one entry per helper"
            )
        );
        script.deploy(address(pool), _vaults(), _two(PRIME_PAIR, EUR_PAIR), new uint256[](1), _ids(), _two(50, 25));
    }

    function test_rejectsUnknownPair() external {
        vm.expectRevert(DirectPropAMMBufferHelper.InvalidPair.selector);
        script.deploy(address(pool), _vaults(), _two(PRIME_PAIR, 2), _two(HOME, ALPHA), _ids(), _two(50, 25));
    }

    function _vaults() internal view returns (address[] memory vaults) {
        vaults = new address[](2);
        (vaults[0], vaults[1]) = (vaultA, vaultB);
    }

    function _ids() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        (ids[0], ids[1]) = (ID_A, ID_B);
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        (values[0], values[1]) = (a, b);
    }
}

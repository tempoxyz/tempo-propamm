// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ManagedDirectPropAMM } from "./ManagedDirectPropAMM.sol";
import { IManagedDirectPropAMM } from "./interfaces/IManagedDirectPropAMM.sol";
import { Settler } from "./Settler.sol";
import { IPoolFactory } from "./interfaces/IPoolFactory.sol";

/// @notice Permissionless deployment and provenance for one immutable Managed implementation and its settler.
/// @dev No admin or upgrade path. Creation binds creator, owner and salt; initialization is atomic.
contract PoolFactory is IPoolFactory {
    address public immutable override implementation;
    address public immutable override defaultSettler;
    uint256 private constant POOL_CODE_LENGTH = 77;

    constructor() {
        implementation = address(new ManagedDirectPropAMM(address(0), address(this)));
        defaultSettler = address(new Settler(IManagedDirectPropAMM(implementation)));
    }

    /// @notice Deploy a paused, empty pool. The creator gains no authority unless explicitly named as owner.
    function createPool(address owner, bytes32 salt) external override returns (address pool) {
        bytes32 deploymentSalt = _salt(msg.sender, owner, salt);
        pool = Clones.predictDeterministicAddressWithImmutableArgs(
            implementation, abi.encode(deploymentSalt), deploymentSalt, address(this)
        );
        if (pool.code.length != 0) revert PoolAlreadyExists(pool);
        pool = Clones.cloneDeterministicWithImmutableArgs(implementation, abi.encode(deploymentSalt), deploymentSalt);
        ManagedDirectPropAMM(pool).initialize(owner, defaultSettler);
        emit PoolCreated(pool, msg.sender, owner, salt);
    }

    function predictPool(address creator, address owner, bytes32 salt) external view override returns (address) {
        bytes32 s = _salt(creator, owner, salt);
        return Clones.predictDeterministicAddressWithImmutableArgs(implementation, abi.encode(s), s, address(this));
    }

    /// @notice Same address-only provenance proof as v2. No per-pool storage or calls to the candidate.
    function isPool(address pool) external view override returns (bool) {
        if (pool.code.length != POOL_CODE_LENGTH) return false;
        bytes memory args = Clones.fetchCloneArgs(pool);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 s = bytes32(args);
        return s != bytes32(0)
            && pool == Clones.predictDeterministicAddressWithImmutableArgs(implementation, args, s, address(this));
    }

    function _salt(address creator, address owner, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, owner, salt));
    }
}

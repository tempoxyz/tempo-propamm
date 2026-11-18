// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Permissionless deployment and provenance of immutable Managed pool clones. No access or quality guarantee.
interface IPoolFactory {
    error PoolAlreadyExists(address pool);

    event PoolCreated(address indexed pool, address indexed creator, address indexed owner, bytes32 salt);

    /// @notice Create a paused, empty clone and initialize it atomically. The caller gains no implicit role.
    /// @dev The CREATE2 salt binds caller, owner and salt. The implementation is immutable; owners may replace their pool settler.
    function createPool(address owner, bytes32 salt) external returns (address pool);

    function predictPool(address creator, address owner, bytes32 salt) external view returns (address);

    /// @notice Whether the pool sits at this factory's CREATE2 address for its embedded salt, as in v2.
    function isPool(address pool) external view returns (bool);

    function implementation() external view returns (address);

    /// @notice Initial settler assigned to every pool this factory creates.
    function defaultSettler() external view returns (address);
}

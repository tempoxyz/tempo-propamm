// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Creates venues as minimal clones of one immutable implementation. Creation is permissionless; discovery
/// and routing policy belong to clients.
interface IVenueFactory {
    event VenueCreated(address indexed venue, address indexed owner, bytes32 salt);

    error ZeroAddress();
    /// @notice The implementation doesn't name this factory as its own, or is already initialized.
    error InvalidImplementation();

    /// @notice Clones the implementation with CREATE2 (salt = `keccak256(abi.encode(owner, salt))`), carrying that
    /// salt in the clone's code as its OpenZeppelin `Clones` immutable argument, and initializes it with `owner` and
    /// `defaultSettler()` in the same call. The venue starts with no sponsor registered and no one listed.
    function createVenue(address owner, bytes32 salt) external returns (address venue);

    function predictVenue(address owner, bytes32 salt) external view returns (address);

    /// @notice Whether `venue` is a venue this factory created: it sits at the CREATE2 address this factory deploys a
    /// venue to for the salt its code carries (`Clones.fetchCloneArgs` of its 77-byte code). Only this factory deploys
    /// there, and it initializes every venue in the same call, so its code and storage are the factory's. Calls
    /// nothing, and never reverts: an account without a venue's code length, or claiming salt 0, is false.
    function isVenue(address venue) external view returns (bool);

    function implementation() external view returns (address);

    function defaultSettler() external view returns (address);
}

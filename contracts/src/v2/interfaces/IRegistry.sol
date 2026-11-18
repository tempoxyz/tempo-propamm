// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenueFactory } from "./IVenueFactory.sol";

/// @notice Optional venue-only discovery for one v2 factory. Membership proves origin, not trading approval.
interface IRegistry {
    error InvalidFactory(address factory);
    error UnknownVenue(address venue);
    error PageTooLarge(uint256 supplied, uint256 maximum);

    /// @notice A newly registered venue and its stable, zero-based enumeration index.
    event Registered(address indexed venue, uint256 indexed index);

    /// @notice The fixed factory trusted to prove a venue's origin.
    function factory() external view returns (IVenueFactory);

    /// @notice The maximum number of addresses one page can return.
    function MAX_PAGE_SIZE() external view returns (uint256);

    /// @notice Permissionlessly register a factory-created venue; return false without emitting on duplicates.
    function register(address venue) external returns (bool added);

    /// @notice Create and register through the original factory, or register its existing (owner, salt) venue.
    /// @dev Does not reset an existing venue's ownership, Settler or configuration.
    function createAndRegister(address owner, bytes32 salt) external returns (address venue);

    function isRegistered(address venue) external view returns (bool);
    function venueCount() external view returns (uint256);

    /// @notice Read one zero-based index; an index outside the directory reverts.
    function venueAt(uint256 index) external view returns (address);

    /// @notice Read in append-only order. A zero limit or offset at/past the end returns an empty page.
    /// @dev A limit above MAX_PAGE_SIZE reverts, even for an empty page.
    function venues(uint256 offset, uint256 limit) external view returns (address[] memory page);
}

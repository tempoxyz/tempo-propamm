// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenueFactory } from "./interfaces/IVenueFactory.sol";
import { IRegistry } from "./interfaces/IRegistry.sol";

/// @notice Append-only directory of venues from one existing v2 factory, not a list of approved markets.
/// @dev An optional sidecar: no changes to the factory, venues or Settler. Anyone can backfill
/// factory-created venues. Consumers must check live pairs, access, settlement and liquidity themselves.
/// The deployer chooses the trusted factory; code presence is not proof that it is the canonical factory.
contract Registry is IRegistry {
    uint256 public constant override MAX_PAGE_SIZE = 100;
    IVenueFactory public immutable override factory;

    address[] private _venues;
    // One-based membership marker: zero means never registered, not index zero.
    mapping(address venue => uint256 position) private _positions;

    constructor(IVenueFactory factory_) {
        if (address(factory_).code.length == 0) revert InvalidFactory(address(factory_));
        factory = factory_;
    }

    /// @notice Register an existing factory venue. Repeated submissions are harmless and emit nothing.
    /// @return added True only for the first registration. No owner permission or venue call is needed.
    function register(address venue) external override returns (bool added) {
        return _register(venue);
    }

    /// @notice Create through the original factory and register atomically, or register an existing (owner, salt).
    /// @dev Uses the original factory's address prediction, ownership and default Settler. A third party creating
    /// the same venue first cannot block this call. Direct factory creates still need a separate register call.
    function createAndRegister(address owner, bytes32 salt) external override returns (address venue) {
        venue = factory.predictVenue(owner, salt);
        if (factory.isVenue(venue)) {
            // The immutable factory just proved this address; do not pay for the same proof twice.
            if (_positions[venue] == 0) _append(venue);
        } else {
            venue = factory.createVenue(owner, salt);
            // Still validate the returned address: constructor code presence is not factory authentication.
            _register(venue);
        }
    }

    function isRegistered(address venue) external view override returns (bool) {
        return _positions[venue] != 0;
    }

    function venueCount() external view override returns (uint256) {
        return _venues.length;
    }

    /// @notice Read one zero-based index; an index outside the directory reverts.
    function venueAt(uint256 index) external view override returns (address) {
        return _venues[index];
    }

    /// @notice Read at most 100 venues, in registration order, starting at offset (zero-based).
    /// @dev Zero limit or an offset at/past the end returns an empty page. Entries are never removed or reordered.
    function venues(uint256 offset, uint256 limit) external view override returns (address[] memory page) {
        if (limit > MAX_PAGE_SIZE) revert PageTooLarge(limit, MAX_PAGE_SIZE);
        uint256 length = _venues.length;
        if (offset >= length) return new address[](0);
        uint256 count = length - offset;
        if (count > limit) count = limit;
        page = new address[](count);
        // count <= length - offset proves every copied index is in bounds. Addresses occupy one slot each.
        // Allocate in Solidity above; touch only scratch space and the allocated array's element region.
        assembly ("memory-safe") {
            mstore(0, _venues.slot)
            let source := add(keccak256(0, 0x20), offset)
            let target := add(page, 0x20)
            let end := add(target, mul(count, 0x20))
            for { } lt(target, end) {
                target := add(target, 0x20)
                source := add(source, 1)
            } {
                mstore(target, and(sload(source), 0xffffffffffffffffffffffffffffffffffffffff))
            }
        }
    }

    function _register(address venue) private returns (bool) {
        if (_positions[venue] != 0) return false;
        // The canonical factory proves the CREATE2 address and embedded salt without calling candidate code.
        if (!factory.isVenue(venue)) revert UnknownVenue(venue);
        _append(venue);
        return true;
    }

    /// @dev Only for a proven, not-yet-registered address. No external calls between the checks and this append.
    function _append(address venue) private {
        uint256 index = _venues.length;
        _venues.push(venue);
        _positions[venue] = index + 1;
        emit Registered(venue, index);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenueFactory } from "../../../src/v2/interfaces/IVenueFactory.sol";
import { IRegistry } from "../../../src/v2/interfaces/IRegistry.sol";

// Pinned PR #147 baseline: 021156fecacd3e51f6074eec233d8349074c04ee.
// Exact historical contracts/src/v2/VenueDirectory.sol source except this comment, names and relative imports.
// Keep frozen: gas comparisons must not silently move with the optimized implementation.
// The NatSpec below is historical: its curated Registry reference describes the pinned source, not current discovery.

/// @notice Append-only directory of venues from one existing v2 factory, not a list of approved markets.
/// @dev An optional sidecar: no changes to the factory, venues, Settler or curated Registry. Anyone can backfill
/// factory-created venues. Consumers must check live pairs, access, settlement and liquidity themselves.
/// The deployer chooses the trusted factory; code presence is not proof that it is the canonical factory.
contract RegistryBaseline is IRegistry {
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
        if (!factory.isVenue(venue)) venue = factory.createVenue(owner, salt);
        _register(venue);
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
        for (uint256 i; i < count; ++i) {
            page[i] = _venues[offset + i];
        }
    }

    function _register(address venue) private returns (bool) {
        if (_positions[venue] != 0) return false;
        // The canonical factory proves the CREATE2 address and embedded salt without calling candidate code.
        if (!factory.isVenue(venue)) revert UnknownVenue(venue);
        uint256 index = _venues.length;
        _venues.push(venue);
        _positions[venue] = index + 1;
        emit Registered(venue, index);
        return true;
    }
}

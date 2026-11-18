// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";

import { IVenue } from "./interfaces/IVenue.sol";
import { IVenueFactory } from "./interfaces/IVenueFactory.sol";

/// @notice Creates venues as minimal clones of one immutable `Venue` implementation, deployed before this factory
/// against its address. Creation is permissionless; discovery and routing policy belong to clients.
/// @dev The implementation is its own transaction, so this factory's deployment carries none of its code, and the
/// settler is built against the implementation, so the factory needs no admin. Each venue is the clone OpenZeppelin's
/// `Clones.cloneDeterministicWithImmutableArgs` deploys with its own CREATE2 salt as its argument (`abi.encode(salt)`),
/// so its 77-byte runtime is the 45-byte EIP-1167 proxy followed by the salt, and `Clones` alone deploys a venue,
/// predicts its address and reads its salt back. Its address alone proves this factory created it, and the factory
/// stores nothing per venue: only this factory deploys at its CREATE2 addresses, and it initializes each venue in the
/// same call. A venue accepts `initialize` only from this factory's deployed code, so no constructor at this address,
/// whatever runtime it returned, can have left an initialized venue behind.
contract VenueFactory is IVenueFactory {
    /// @dev A venue's runtime: the 45-byte proxy and its 32-byte salt.
    uint256 private constant VENUE_CODE_LENGTH = 77;

    address private immutable IMPLEMENTATION;
    address private immutable DEFAULT_SETTLER;

    /// @param implementation_ The `Venue` implementation every venue clones. It must name this factory as its own
    /// (`factory()`), so only this factory can initialize its clones, and be uninitialized (`owner() == 0`).
    /// @param defaultSettler_ The settler every new venue starts with. Each owner can repoint their own venue.
    constructor(IVenue implementation_, address defaultSettler_) {
        if (address(implementation_) == address(0) || defaultSettler_ == address(0)) revert ZeroAddress();
        if (implementation_.factory() != address(this) || implementation_.owner() != address(0)) {
            revert InvalidImplementation();
        }
        IMPLEMENTATION = address(implementation_);
        DEFAULT_SETTLER = defaultSettler_;
    }

    /// @inheritdoc IVenueFactory
    /// @dev An existing `(owner, salt)` venue reverts `FailedDeployment` before CREATE2, the error the collision
    /// itself would raise, because a CREATE2 collision consumes all the gas it is given. Anyone may create the venue
    /// first; it is still `owner`'s. `initialize` emits nothing, so `VenueCreated` goes first.
    function createVenue(address owner, bytes32 salt) external returns (address venue) {
        if (owner == address(0)) revert ZeroAddress();
        bytes32 s = _salt(owner, salt);
        bytes memory args = abi.encode(s);
        address predicted = Clones.predictDeterministicAddressWithImmutableArgs(IMPLEMENTATION, args, s, address(this));
        if (predicted.code.length != 0) revert Errors.FailedDeployment();
        venue = Clones.cloneDeterministicWithImmutableArgs(IMPLEMENTATION, args, s);
        emit VenueCreated(venue, owner, salt);
        IVenue(venue).initialize(owner, DEFAULT_SETTLER);
    }

    /// @inheritdoc IVenueFactory
    /// @dev The length check comes first, so this never reverts: `Clones.fetchCloneArgs` panics on code shorter than
    /// the proxy. The Settler makes the same check.
    function isVenue(address venue) external view returns (bool) {
        if (venue.code.length != VENUE_CODE_LENGTH) return false;
        bytes memory args = Clones.fetchCloneArgs(venue);
        // `args` is exactly 32 bytes: the code is 77 bytes long.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 s = bytes32(args);
        return s != bytes32(0)
            && venue == Clones.predictDeterministicAddressWithImmutableArgs(IMPLEMENTATION, args, s, address(this));
    }

    /// @inheritdoc IVenueFactory
    function predictVenue(address owner, bytes32 salt) external view returns (address) {
        bytes32 s = _salt(owner, salt);
        return Clones.predictDeterministicAddressWithImmutableArgs(IMPLEMENTATION, abi.encode(s), s, address(this));
    }

    /// @inheritdoc IVenueFactory
    function implementation() external view returns (address) {
        return IMPLEMENTATION;
    }

    /// @inheritdoc IVenueFactory
    function defaultSettler() external view returns (address) {
        return DEFAULT_SETTLER;
    }

    function _salt(address owner, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { SettlerMockVenue } from "./SettlerMockVenue.sol";

/// @dev Stands in for `VenueFactory`: deploys one `SettlerMockVenue` implementation, which names this factory, and
/// creates venues the way the real factory does, as EIP-1167 clones that carry their CREATE2 salt as their
/// OpenZeppelin `Clones` immutable argument, so the Settler accepts them.
contract SettlerMockFactory {
    SettlerMockVenue internal immutable IMPLEMENTATION;

    uint256 internal _created;

    constructor() {
        IMPLEMENTATION = new SettlerMockVenue(address(this));
    }

    function implementation() external view returns (SettlerMockVenue) {
        return IMPLEMENTATION;
    }

    function createVenue(address settler, uint256 rateBps) external returns (SettlerMockVenue venue) {
        bytes32 salt = keccak256(abi.encode(++_created));
        venue = SettlerMockVenue(
            Clones.cloneDeterministicWithImmutableArgs(address(IMPLEMENTATION), abi.encode(salt), salt)
        );
        venue.initialize(settler, rateBps);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

import { Settler } from "../../../src/v2/Settler.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { VenueFactory } from "../../../src/v2/VenueFactory.sol";
import { TIP20FactoryMock } from "./TIP20FactoryMock.sol";

/// @dev Deploys the v2 core from the calling contract in `DeployV2`'s order: the `Venue` implementation against the
/// factory's predicted address, the `Settler` against the implementation, then the factory, which must land at the
/// prediction.
library CoreDeploy {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The implementation, a `Settler` and a factory whose venues start with that settler.
    function core() internal returns (Settler settler, VenueFactory factory) {
        TIP20FactoryMock.install(VM);
        address predicted = VM.computeCreateAddress(address(this), VM.getNonce(address(this)) + 2);
        Venue implementation = new Venue(predicted);
        settler = new Settler(implementation);
        factory = new VenueFactory(implementation, address(settler));
        require(address(factory) == predicted, "CoreDeploy: factory address");
    }

    /// @dev The implementation and a factory whose venues start with `defaultSettler`, for suites that stand in their
    /// own settler.
    function factoryWith(address defaultSettler) internal returns (VenueFactory factory) {
        TIP20FactoryMock.install(VM);
        address predicted = VM.computeCreateAddress(address(this), VM.getNonce(address(this)) + 1);
        Venue implementation = new Venue(predicted);
        factory = new VenueFactory(implementation, defaultSettler);
        require(address(factory) == predicted, "CoreDeploy: factory address");
    }
}

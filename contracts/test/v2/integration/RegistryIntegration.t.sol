// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IRegistry } from "../../../src/v2/interfaces/IRegistry.sol";
import { ISettler } from "../../../src/v2/interfaces/ISettler.sol";
import { IVenue } from "../../../src/v2/interfaces/IVenue.sol";
import { Venue } from "../../../src/v2/Venue.sol";
import { VenueFactory } from "../../../src/v2/VenueFactory.sol";
import { CoreDeploy } from "../utils/CoreDeploy.sol";
import { IntegrationFixture } from "./utils/IntegrationFixture.sol";

contract RegistryIntegrationTest is IntegrationFixture {
    function test_multipleVenuesForSamePairRemainDiscoverable() public {
        vm.prank(stranger);
        assertTrue(discovery.register(address(venueB)));
        assertEq(discovery.venueCount(), 2);
        assertEq(discovery.venueAt(0), address(venueA));
        assertEq(discovery.venueAt(1), address(venueB));
        (, uint256 expected,) = _expect(venueB, pairB, true, true, 100e6);
        assertEq(_swapExactIn(taker, address(eur), address(usd), _request(venueB, pairB, 100e6), expected), expected);
    }

    function test_removedPairIndexIsNeverReused() public {
        vm.startPrank(makerA);
        venueA.removePair(pairA);
        uint16 fresh = venueA.addPair(address(eur), address(usd), UNIT);
        vm.stopPrank();
        _setAccess(venueA, fresh, IVenue.AccessMode.Open);
        assertEq(fresh, pairA + 1);
        // Discovery is venue-only: removing a pair neither unregisters its venue nor reuses its index.
        assertEq(venueA.pair(pairA).base, address(0));
        assertTrue(discovery.isRegistered(address(venueA)));
        assertFalse(discovery.register(address(venueA)));
        _setShape(venueA, fresh, 0, _shapeA());
        _post(venueA, fresh, _fields(MID_A));
        assertEq(discovery.venueCount(), 1);
        assertEq(discovery.venueAt(0), address(venueA));
        assertGt(_swapExactIn(taker, address(eur), address(usd), _request(venueA, fresh, 100e6), 0), 0);
    }

    /// @dev A venue another factory created, from an implementation built the same way, is no venue of this directory's
    /// factory: the directory won't register it and the Settler won't fill it, since it sits at another factory's address.
    function test_foreignFactoryVenueIsNeitherRegisteredNorFilled() public {
        VenueFactory otherFactory = CoreDeploy.factoryWith(address(settler));
        vm.prank(makerA);
        Venue foreign = Venue(otherFactory.createVenue(makerA, "A"));
        assertTrue(otherFactory.isVenue(address(foreign)));
        assertFalse(factory.isVenue(address(foreign)));
        vm.prank(tempoOps);
        vm.expectRevert(abi.encodeWithSelector(IRegistry.UnknownVenue.selector, address(foreign)));
        discovery.register(address(foreign));
        vm.expectRevert(abi.encodeWithSelector(ISettler.UnknownVenue.selector, address(foreign)));
        _swapExactIn(taker, address(eur), address(usd), _request(foreign, 0, 100e6), 0);
    }

    /// @dev An account without a venue's 77 bytes of code, or with a venue's code where its salt doesn't put it, or
    /// with salt 0 at the factory's address for salt 0, is refused with `UnknownVenue` by the directory and the Settler,
    /// never with a panic: `factory.isVenue` and the Settler's check read no salt from any other code length.
    function test_nonVenueCodeIsRefusedWithoutPanic() public {
        bytes memory code = address(venueA).code;
        address[7] memory accounts;
        uint256[6] memory lengths = [uint256(0), 44, 45, 76, 77, 78];
        for (uint256 i; i < lengths.length; ++i) {
            accounts[i] = makeAddr(string.concat("code length ", vm.toString(lengths[i])));
            bytes memory runtime = new bytes(lengths[i]);
            for (uint256 j; j < runtime.length; ++j) {
                runtime[j] = j < code.length ? code[j] : bytes1(0xaa);
            }
            vm.etch(accounts[i], runtime);
        }
        address implementation = factory.implementation();
        accounts[6] = Clones.predictDeterministicAddressWithImmutableArgs(
            implementation, abi.encode(bytes32(0)), bytes32(0), address(factory)
        );
        vm.etch(
            accounts[6],
            abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3", bytes32(0))
        );
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            assertFalse(factory.isVenue(account));
            vm.prank(tempoOps);
            vm.expectRevert(abi.encodeWithSelector(IRegistry.UnknownVenue.selector, account));
            discovery.register(account);
            vm.expectRevert(abi.encodeWithSelector(ISettler.UnknownVenue.selector, account));
            _swapExactIn(taker, address(eur), address(usd), _request(Venue(account), 0, 100e6), 0);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { ITIP20Factory } from "../../src/interfaces/ITIP20Factory.sol";
import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { Venue } from "../../src/v2/Venue.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";

interface ITIP20FactoryCreate {
    function createToken(
        string memory name,
        string memory symbol,
        string memory currency,
        address quoteToken,
        address admin,
        bytes32 salt
    ) external returns (address);
}

/// @notice `Venue.addPair` against Tempo's live precompiles (`forge test --network tempo`): the canonical factory
/// admits a factory-created TIP-20 and rejects an uninitialized address in the reserved TIP-20 namespace.
/// @dev The VenueAccess filename keeps this suite in CI's existing Tempo access-test glob.
/// Skips without `--network tempo`; generic-EVM token-admission cases are in `Venue.t.sol`.
contract VenueAccessTIP20TempoTest is Test {
    uint64 internal constant UNIT = 1e6;
    address internal constant TIP20_FACTORY = 0x20Fc000000000000000000000000000000000000;
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    address internal constant UNINITIALIZED_TIP20 = 0x20c00000000000000000000000000000deAdbeeF;

    address internal owner = makeAddr("owner");
    address internal settler = makeAddr("settler");
    VenueFactory internal factory;
    Venue internal venue;
    address internal token;

    function setUp() external {
        if (TIP20_FACTORY.code.length == 0) return;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Venue implementation = new Venue(predicted);
        factory = new VenueFactory(implementation, settler);
        venue = Venue(factory.createVenue(owner, bytes32("tip20 admission")));
        token = ITIP20FactoryCreate(TIP20_FACTORY)
            .createToken("Venue test token", "VTIP", "USD", PATH_USD, address(this), bytes32("venue tip20"));
    }

    function _skipUnlessTempo() internal returns (bool) {
        if (TIP20_FACTORY.code.length != 0) return false;
        vm.skip(true, "needs --network tempo");
        return true;
    }

    function test_addPairAcceptsAnInitializedTip20() external {
        if (_skipUnlessTempo()) return;
        assertTrue(ITIP20Factory(TIP20_FACTORY).isTIP20(token));
        assertTrue(ITIP20Factory(TIP20_FACTORY).isTIP20(PATH_USD));
        vm.prank(owner);
        assertEq(venue.addPair(token, PATH_USD, UNIT), 0);
    }

    function test_addPairRejectsAnUninitializedReservedPrefix() external {
        if (_skipUnlessTempo()) return;
        assertFalse(ITIP20Factory(TIP20_FACTORY).isTIP20(UNINITIALIZED_TIP20));
        vm.expectRevert(IVenue.InvalidPairTokens.selector);
        vm.prank(owner);
        venue.addPair(UNINITIALIZED_TIP20, token, UNIT);
    }
}

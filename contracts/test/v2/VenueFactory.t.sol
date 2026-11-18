// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";
import { Test, Vm } from "forge-std/Test.sol";

import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { IVenueFactory } from "../../src/v2/interfaces/IVenueFactory.sol";
import { Settler } from "../../src/v2/Settler.sol";
import { Venue } from "../../src/v2/Venue.sol";
import { VenueFactory } from "../../src/v2/VenueFactory.sol";
import { Forgery } from "./utils/ForgedCode.sol";

contract VenueFactoryTest is Test {
    Venue internal impl;
    Settler internal settler;
    VenueFactory internal factory;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        // `DeployV2`'s order: the implementation against the address the factory will get, the Settler against the
        // implementation, then the factory.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        impl = new Venue(predicted);
        settler = new Settler(impl);
        factory = new VenueFactory(impl, address(settler));
        assertEq(address(factory), predicted);
    }

    function test_deployOrder_implementationAndSettlerAgainstThePredictedFactory() public view {
        assertEq(impl.factory(), address(factory));
        assertEq(settler.factory(), address(factory));
        assertEq(settler.implementation(), address(impl));
        assertEq(factory.defaultSettler(), address(settler));
    }

    function test_constructor() public view {
        assertEq(factory.implementation(), address(impl));
        assertEq(impl.owner(), address(0));
        assertEq(impl.settler(), address(0));
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(IVenueFactory.ZeroAddress.selector);
        new VenueFactory(IVenue(address(0)), address(settler));
        vm.expectRevert(IVenueFactory.ZeroAddress.selector);
        new VenueFactory(impl, address(0));
    }

    /// @dev Only an implementation that names this factory, and that nobody initialized, is accepted: a wrong address
    /// prediction fails closed at the factory's own deployment.
    function test_constructor_rejectsAnImplementationOfAnotherFactory() public {
        // `impl` names the factory deployed in `setUp`, not this one.
        vm.expectRevert(IVenueFactory.InvalidImplementation.selector);
        new VenueFactory(impl, address(settler));

        Venue other = new Venue(makeAddr("otherFactory"));
        vm.expectRevert(IVenueFactory.InvalidImplementation.selector);
        new VenueFactory(other, address(settler));

        // An implementation already initialized by the account the factory would be deployed at. `initialize` takes
        // only a caller with code, so the account gets some for the call and loses it before the factory lands there.
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Venue used = new Venue(next);
        vm.etch(next, hex"00");
        vm.prank(next);
        used.initialize(owner, address(settler));
        vm.etch(next, "");
        vm.expectRevert(IVenueFactory.InvalidImplementation.selector);
        new VenueFactory(used, address(settler));

        // An address that isn't a venue at all can't answer `factory()`.
        vm.expectRevert();
        new VenueFactory(IVenue(makeAddr("noCode")), address(settler));
    }

    /// @dev `createVenue` writes the clone's owner and settler and nothing else: no sponsor, no list, and nothing stored
    /// in the factory. `VenueCreated` is its only event.
    function test_createVenue_matchesPredictionAndInitializes() public {
        bytes32 salt = bytes32("desk-1");
        address predicted = factory.predictVenue(owner, salt);
        assertFalse(factory.isVenue(predicted));
        assertEq(predicted.code.length, 0);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IVenueFactory.VenueCreated(predicted, owner, salt);
        vm.recordLogs();
        address venue = factory.createVenue(owner, salt);
        assertEq(vm.getRecordedLogs().length, 1, "VenueCreated only");

        assertEq(venue, predicted);
        bytes32 createSalt = keccak256(abi.encode(owner, salt));
        assertEq(
            venue,
            Clones.predictDeterministicAddressWithImmutableArgs(
                address(impl), abi.encode(createSalt), createSalt, address(factory)
            )
        );
        assertTrue(factory.isVenue(venue));
        // An EIP-1167 minimal proxy of the implementation that carries its CREATE2 salt, which the Settler reads.
        assertEq(
            venue.code,
            abi.encodePacked(hex"363d3d373d3d3d363d73", address(impl), hex"5af43d82803e903d91602b57fd5bf3", createSalt)
        );
        assertEq(Clones.fetchCloneArgs(venue), abi.encode(createSalt));
        assertEq(IVenue(venue).owner(), owner);
        assertEq(IVenue(venue).settler(), address(settler));
        assertEq(IVenue(venue).factory(), address(factory));
        assertEq(IVenue(venue).pairCount(), 0);
        (address admin,,) = IVenue(venue).sponsor(1);
        assertEq(admin, address(0), "no sponsor registered");
    }

    /// @dev Each venue's lists are its own: a sponsor id registered on one venue means nothing on another.
    function test_eachVenueHasItsOwnLists() public {
        IVenue a = IVenue(factory.createVenue(owner, "a"));
        IVenue b = IVenue(factory.createVenue(owner, "b"));
        vm.prank(owner);
        a.addSponsor(7, stranger);
        (address adminA,,) = a.sponsor(7);
        (address adminB,,) = b.sponsor(7);
        assertEq(adminA, stranger);
        assertEq(adminB, address(0));
    }

    function test_createVenue_isPermissionlessButOwnedByTheNamedOwner() public {
        vm.prank(stranger);
        address venue = factory.createVenue(owner, bytes32(0));
        assertEq(IVenue(venue).owner(), owner);
        assertEq(venue, factory.predictVenue(owner, bytes32(0)));
    }

    function test_createVenue_saltIsBoundToTheOwner() public {
        bytes32 salt = bytes32("same");
        assertTrue(factory.predictVenue(owner, salt) != factory.predictVenue(stranger, salt));
        address a = factory.createVenue(owner, salt);
        address b = factory.createVenue(stranger, salt);
        assertTrue(a != b);
        assertEq(IVenue(b).owner(), stranger);
        // Many venues per owner are allowed with different salts.
        address c = factory.createVenue(owner, bytes32("other"));
        assertTrue(c != a);
        assertTrue(factory.isVenue(c));
    }

    function test_createVenue_sameOwnerAndSaltTwiceRevertsCheaply() public {
        // A front-runner creates the owner's venue first. It is still the owner's, and the owner's own call then
        // reverts before CREATE2, instead of burning the gas a collision consumes.
        vm.prank(stranger);
        address venue = factory.createVenue(owner, bytes32("x"));
        assertEq(IVenue(venue).owner(), owner);

        bytes memory data = abi.encodeCall(IVenueFactory.createVenue, (owner, bytes32("x")));
        uint256 start = gasleft();
        (bool ok, bytes memory err) = address(factory).call{ gas: 10_000_000 }(data);
        uint256 used = start - gasleft();
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(Errors.FailedDeployment.selector));
        assertLt(used, 100_000);
        assertEq(IVenue(venue).owner(), owner);
    }

    function test_createVenue_rejectsZeroOwner() public {
        vm.expectRevert(IVenueFactory.ZeroAddress.selector);
        factory.createVenue(address(0), bytes32(0));
    }

    function test_clone_initializesOnlyOnceAndOnlyFromTheFactory() public {
        address venue = factory.createVenue(owner, bytes32(0));
        vm.expectRevert(IVenue.NotFactory.selector);
        vm.prank(stranger);
        IVenue(venue).initialize(stranger, stranger);
        vm.expectRevert(IVenue.AlreadyInitialized.selector);
        vm.prank(address(factory));
        IVenue(venue).initialize(stranger, stranger);
        assertEq(IVenue(venue).owner(), owner);
    }

    /// @dev A factory's runtime code can't show what its constructor did, so `verify`'s code and getter checks can't
    /// either. A constructor that deploys a clone at the venue address the real factory would give `owner`,
    /// initializes it with its own settler and then returns the real factory's exact runtime would leave a venue that a
    /// rogue settler fills without paying in. `initialize` refuses a factory without code, so that constructor
    /// reverts, and a clone it plants without initializing stays without an owner or settler: the factory's runtime
    /// refuses to create over it, so nothing can ever initialize it.
    function test_initialize_refusesTheFactorysConstructor() public {
        bytes32 salt = bytes32("victim");
        address rogue = makeAddr("rogueSettler");
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Venue implementation = new Venue(predicted);
        // The real factory's runtime at that address, for the planting constructor to return.
        uint256 snapshot = vm.snapshotState();
        bytes memory runtime = address(new VenueFactory(implementation, address(settler))).code;
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        vm.expectRevert(IVenue.NotFactory.selector);
        new PlantingFactory(implementation, owner, salt, rogue, runtime, true);
        vm.revertToState(snapshot);

        IVenueFactory planted =
            IVenueFactory(address(new PlantingFactory(implementation, owner, salt, rogue, runtime, false)));
        assertEq(address(planted), predicted);
        assertEq(address(planted).code, runtime, "the real factory's exact runtime");
        assertEq(planted.defaultSettler(), address(settler));
        IVenue venue = IVenue(planted.predictVenue(owner, salt));
        assertTrue(planted.isVenue(address(venue)), "at a real venue address");
        assertEq(venue.owner(), address(0));
        assertEq(venue.settler(), address(0));

        vm.expectRevert(Errors.FailedDeployment.selector);
        planted.createVenue(owner, salt);
        vm.prank(rogue);
        vm.expectRevert(IVenue.NotSettler.selector);
        venue.fill(0, address(1), address(2), 1, true, rogue, 0, bytes32(0));
        vm.prank(owner);
        vm.expectRevert(IVenue.NotOwner.selector);
        venue.setSettler(rogue);
        // The same owner's other salts create and initialize as usual.
        IVenue created = IVenue(planted.createVenue(owner, bytes32("other")));
        assertEq(created.owner(), owner);
        assertEq(created.settler(), address(settler));
    }

    /// @dev Only the factory could initialize the implementation, and it only initializes the clones it creates, so
    /// the implementation keeps no owner and no settler. It isn't at a venue address, so it is no venue either.
    function test_implementation_staysUninitialized() public {
        vm.expectRevert(IVenue.NotFactory.selector);
        vm.prank(stranger);
        impl.initialize(owner, address(settler));
        vm.expectRevert(IVenue.NotFactory.selector);
        vm.prank(owner);
        impl.initialize(owner, address(settler));

        assertEq(impl.owner(), address(0));
        assertEq(impl.settler(), address(0));
        assertFalse(factory.isVenue(address(impl)));
        vm.expectRevert(IVenue.NotOwner.selector);
        vm.prank(owner);
        impl.setSettler(owner);
    }

    /// @dev Only the factory's own clones are venues. A clone of the implementation that anyone else deployed isn't,
    /// whatever salt it carries, and can never be initialized. Nor is a contract whose constructor wrote a venue's
    /// owner, settler, pending owner and updater slots and then returned a real venue's exact code: `isVenue` asks
    /// nothing of the account, so no storage can pass it.
    function test_isVenue_onlyForCreatedClones() public {
        assertFalse(factory.isVenue(address(0)));
        assertFalse(factory.isVenue(address(factory)));
        assertFalse(factory.isVenue(address(impl)));
        assertFalse(factory.isVenue(address(settler)));
        assertFalse(factory.isVenue(factory.predictVenue(owner, bytes32(0))));
        // No code claims salt 0, and the venue address for salt 0 has none.
        assertFalse(
            factory.isVenue(
                Clones.predictDeterministicAddressWithImmutableArgs(
                    address(impl), abi.encode(bytes32(0)), bytes32(0), address(factory)
                )
            )
        );

        address venue = factory.createVenue(owner, bytes32(0));
        assertTrue(factory.isVenue(venue));
        bytes32 createSalt = bytes32(Clones.fetchCloneArgs(venue));

        vm.startPrank(stranger);
        address plain = Clones.clone(address(impl));
        address sameArgs = Clones.cloneWithImmutableArgs(address(impl), abi.encode(createSalt));
        address sameSalt = Clones.cloneDeterministicWithImmutableArgs(address(impl), abi.encode(createSalt), createSalt);
        vm.stopPrank();
        assertEq(sameArgs.code, venue.code, "a real venue's code");
        assertEq(sameSalt.code, venue.code, "a real venue's code");
        address[3] memory foreign = [plain, sameArgs, sameSalt];
        for (uint256 i; i < foreign.length; ++i) {
            assertFalse(factory.isVenue(foreign[i]));
            vm.prank(stranger);
            vm.expectRevert(IVenue.NotFactory.selector);
            IVenue(foreign[i]).initialize(stranger, stranger);
            assertFalse(factory.isVenue(foreign[i]));
        }

        bytes32[] memory slots = new bytes32[](4);
        bytes32[] memory values = new bytes32[](4);
        (slots[0], values[0]) = (bytes32(uint256(0)), bytes32(uint256(uint160(owner))));
        (slots[1], values[1]) = (bytes32(uint256(1)), bytes32(uint256(uint160(address(settler)))));
        (slots[2], values[2]) = (bytes32(uint256(2)), bytes32(uint256(uint160(stranger))));
        (slots[3], values[3]) = (keccak256(abi.encode(stranger, uint256(3))), bytes32(uint256(1)));
        IVenue forged = IVenue(Forgery.deploy(venue.code, slots, values));
        assertEq(forged.owner(), owner);
        assertEq(forged.settler(), address(settler));
        assertEq(forged.pendingOwner(), stranger);
        assertTrue(forged.isUpdater(stranger));
        assertFalse(factory.isVenue(address(forged)));
    }

    /// @dev `isVenue` reads a salt only from a venue's 77 bytes of code and is false, without reverting, for every
    /// other length: no code, either side of the 45-byte proxy (`Clones.fetchCloneArgs` panics below it) and either
    /// side of a venue. Each code starts with a real venue's, so only its length tells it apart, and the 77-byte one is
    /// that venue's exact code, a clone of the right implementation, at an address its salt doesn't name.
    function test_isVenue_falseWithoutRevertForEveryOtherCodeLength() public {
        address venue = factory.createVenue(owner, "lengths");
        uint256[6] memory lengths = [uint256(0), 44, 45, 76, 77, 78];
        for (uint256 i; i < lengths.length; ++i) {
            address account = makeAddr(string.concat("code length ", vm.toString(lengths[i])));
            vm.etch(account, _resized(venue.code, lengths[i]));
            assertEq(account.code.length, lengths[i]);
            assertFalse(factory.isVenue(account));
        }
        assertTrue(factory.isVenue(venue));
    }

    /// @dev Salt 0 is never a venue's, even with a clone of the implementation that carries salt 0 at the factory's
    /// CREATE2 address for salt 0, where only the salt check rejects it.
    function test_isVenue_rejectsSaltZeroAtItsOwnAddress() public {
        address own = Clones.predictDeterministicAddressWithImmutableArgs(
            address(impl), abi.encode(bytes32(0)), bytes32(0), address(factory)
        );
        vm.etch(
            own,
            abi.encodePacked(hex"363d3d373d3d3d363d73", address(impl), hex"5af43d82803e903d91602b57fd5bf3", bytes32(0))
        );
        assertEq(Clones.fetchCloneArgs(own), abi.encode(bytes32(0)));
        assertFalse(factory.isVenue(own));
    }

    /// @dev A venue the factory created sits where `predictVenue` says, is a venue, and carries its salt; no other
    /// account is a venue, whether it has no code, that venue's exact code or any other.
    function testFuzz_isVenueOnlyAtTheCreatedVenue(address venueOwner, bytes32 salt, address other, bytes memory code)
        public
    {
        vm.assume(venueOwner != address(0));
        address venue = factory.createVenue(venueOwner, salt);
        assertEq(venue, factory.predictVenue(venueOwner, salt));
        assertEq(Clones.fetchCloneArgs(venue), abi.encode(keccak256(abi.encode(venueOwner, salt))));
        assertTrue(factory.isVenue(venue));

        assumeNotForgeAddress(other);
        assumeNotPrecompile(other);
        vm.assume(other.code.length == 0 && other != venue);
        assertFalse(factory.isVenue(other));
        vm.etch(other, venue.code);
        assertFalse(factory.isVenue(other));
        // Code starting `0xef` is either invalid or, at 23 bytes, an EIP-7702 delegation, which `vm.etch` refuses.
        vm.assume(code.length == 0 || code[0] != 0xef);
        vm.etch(other, code);
        assertFalse(factory.isVenue(other));
    }

    function test_venueConstructor_rejectsAZeroFactory() public {
        vm.expectRevert(IVenue.ZeroAddress.selector);
        new Venue(address(0));
    }

    /// @dev `initialize` sets the owner and the settler, emits nothing and calls nothing.
    function test_initialize_rejectsZeroOwnerOrSettler() public {
        // An implementation that names this test as its factory.
        Venue own = new Venue(address(this));
        IVenue clone = IVenue(Clones.clone(address(own)));
        vm.expectRevert(IVenue.ZeroAddress.selector);
        clone.initialize(address(0), address(settler));
        vm.expectRevert(IVenue.ZeroAddress.selector);
        clone.initialize(owner, address(0));

        vm.recordLogs();
        clone.initialize(owner, address(settler));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "initialize emits nothing");
        assertEq(clone.owner(), owner);
        assertEq(clone.settler(), address(settler));
        assertEq(clone.factory(), address(this));
        vm.expectRevert(IVenue.AlreadyInitialized.selector);
        clone.initialize(stranger, stranger);
    }

    /// @dev `code` cut or padded (with `0xaa`) to `length` bytes.
    function _resized(bytes memory code, uint256 length) internal pure returns (bytes memory resized) {
        resized = new bytes(length);
        for (uint256 i; i < length; ++i) {
            resized[i] = i < code.length ? code[i] : bytes1(0xaa);
        }
    }
}

/// @dev A factory constructor that deploys a clone at the venue address the real factory gives `victim` and `salt`,
/// optionally initializes it with `rogueSettler`, and then returns `runtime`: the real factory's code.
contract PlantingFactory {
    constructor(
        IVenue implementation,
        address victim,
        bytes32 salt,
        address rogueSettler,
        bytes memory runtime,
        bool initialize
    ) {
        bytes32 s = keccak256(abi.encode(victim, salt));
        address venue = Clones.cloneDeterministicWithImmutableArgs(address(implementation), abi.encode(s), s);
        if (initialize) IVenue(venue).initialize(victim, rogueSettler);
        assembly ("memory-safe") {
            return(add(runtime, 0x20), mload(runtime))
        }
    }
}

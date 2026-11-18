// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { ITIP20 } from "../../src/interfaces/ITIP20.sol";
import { IVenue } from "../../src/v2/interfaces/IVenue.sol";
import { IVenueFactory } from "../../src/v2/interfaces/IVenueFactory.sol";
import { HotWord } from "../../src/v2/libraries/HotWord.sol";
import { ShapeWord } from "../../src/v2/libraries/ShapeWord.sol";
import { TIP20Factory } from "../../src/v2/libraries/TIP20Factory.sol";

/// @notice Moderato only: creates a demo venue for `OWNER`, adds its pairs with their mid bands, registers sponsors and
/// admits them on every `listed` pair, lists `HOME_ALLOWED` on the home list of every `listed` pair, defines one shape
/// and posts one hot word on one of the pairs, and opens each pair in its access mode last. For maker trials; it moves
/// no tokens and installs no hook. Each sponsor lists its own users afterwards.
/// @dev Every transaction is sent by `OWNER`, since `addPair` and the access calls are owner-only.
/// Forge only sends transactions with `--broadcast`. Inputs (see `script/config/v2-demo-venue.env.example`):
/// - `VENUE_FACTORY`, `OWNER`; optional `VENUE_SALT` (default 0) and `UPDATER` (default none).
/// - `PAIR_BASES`, `PAIR_QUOTES`, `PAIR_SIZE_UNITS`, `PAIR_ACCESS`: comma-separated lists, one entry per pair,
///   added in order as pair indexes 0, 1, ... `PAIR_ACCESS` is `closed`, `listed` or `open` per pair. A pair starts
///   `Closed` and is set to its mode after everything else; `open` needs a halted venue, so the script then halts,
///   opens and unhalts.
/// - Optional `HOME_ALLOWED`: accounts for the venue's home list (sponsor id 0), at most `MAX_BATCH`, listed on every
///   `listed` pair in `setMembers` calls of at most `HOME_ALLOWED_CHUNK`.
/// - Optional `SPONSOR_IDS` with `SPONSOR_ADMINS`, one entry per id in the same order: the sponsors to register
///   (`addSponsor`), each under the id it carries on every venue and with the key that will list its users. Each is
///   admitted on every `listed` pair (`setPairSponsor`).
/// - Optional `PAIR_MID_MINS`, `PAIR_MID_MAXS` (18 dp): per-pair mid bands, set right after each pair is added and so
///   before `UPDATER` exists. Both or neither, one entry per pair; `0` in both is no band for that pair.
/// - `QUOTED_PAIR` (default 0): the pair that gets the shape and the hot word.
/// - `SHAPE_ID` (default 0); `SHAPE_BID` and `SHAPE_ASK`: compact ladders `size:spread,size:spread,...`, level 1
///   first, with `size` in the pair's size units and `spread` in 0.1 bp. An empty string leaves that side empty.
/// - `MID` (quote per 1 base, 18 dp, e.g. `1.085e18`); optional `BID_WIDEN`, `ASK_WIDEN` (0.1 bp, default 0),
///   `WIDTH_SCALE`, `DEPTH_SCALE` (1/1000, default 1000) and `VALID_FOR` (seconds from now, default 3600).
contract SetupDemoVenue is Script {
    error UnexpectedChain(uint256 chainId);
    error InvalidConfig(string field);
    error InvalidShapeSide(string field, string reason);
    error VenueExists(address venue);
    error UnexpectedVenueState(string field);

    uint256 internal constant TEMPO_MODERATO_CHAIN_ID = 42431;
    /// @dev `addPair` stores `seq = 1`, so the first post uses 2.
    uint32 internal constant FIRST_SEQ = 2;
    /// @dev `Venue.MAX_BATCH`.
    uint256 internal constant MAX_BATCH = 100;
    /// @dev Accounts per `setMembers` the script sends. Each new member is a fresh storage slot, so a full `MAX_BATCH`
    /// call measures about 25.6M gas on Tempo, and Forge's 130% gas limit (33.2M) tops the 30M transaction cap; 50
    /// measure about 12.8M (16.6M at the limit). `test/fork/VenueAccessGas.t.sol` pins both figures.
    uint256 internal constant HOME_ALLOWED_CHUNK = 50;

    struct PairInput {
        address base;
        address quote;
        uint64 sizeUnit;
        IVenue.AccessMode access;
        /// @dev The pair's mid band; `(0, 0)` is none.
        uint96 minMid;
        uint96 maxMid;
    }

    struct Config {
        IVenueFactory factory;
        address owner;
        bytes32 salt;
        address updater;
        PairInput[] pairs;
        address[] homeAllowed;
        uint64[] sponsorIds;
        /// @dev One per `sponsorIds` entry: the key that lists that sponsor's users.
        address[] sponsorAdmins;
        uint16 quotedPair;
        uint8 shapeId;
        string shapeBid;
        string shapeAsk;
        uint96 mid;
        uint16 bidWiden;
        uint16 askWiden;
        uint16 widthScale;
        uint16 depthScale;
        uint40 validFor;
    }

    struct Setup {
        IVenue venue;
        uint256[4] shape;
        bytes32 hotWord;
    }

    function run() external returns (Setup memory setup) {
        if (block.chainid != TEMPO_MODERATO_CHAIN_ID) revert UnexpectedChain(block.chainid);
        Config memory config = _readConfig();
        setup.shape = _preflight(config);
        setup.hotWord = _hotWord(config);

        IVenue predicted = IVenue(config.factory.predictVenue(config.owner, config.salt));
        vm.startBroadcast(config.owner);
        setup.venue = IVenue(config.factory.createVenue(config.owner, config.salt));
        if (setup.venue != predicted) revert UnexpectedVenueState("venue address");
        _addPairs(setup.venue, config.pairs);
        _addSponsors(setup.venue, config);
        _allowHome(setup.venue, config);
        if (config.updater != address(0)) setup.venue.setUpdater(config.updater, true);
        setup.venue.setShape(config.quotedPair, config.shapeId, setup.shape);
        setup.venue.post(abi.encodePacked(config.quotedPair, setup.hotWord));
        // Each pair opens last, once its band and first word are in place.
        _openPairs(setup.venue, config.pairs);
        vm.stopBroadcast();

        _checkSetup(config, setup);
        _log(config, setup);
    }

    /// @notice Encodes one side of a shape from its compact form `size:spread,size:spread,...` (level 1 first). An
    /// empty string is an empty side. Reverts on malformed input, a zero or oversized size, an oversized spread, more
    /// than 10 levels, or spreads that decrease.
    function parseSide(string memory spec, string memory field) public pure returns (uint256 w0, uint256 w1) {
        if (bytes(spec).length == 0) return (0, 0);
        string[] memory levels = vm.split(spec, ",");
        if (levels.length > ShapeWord.MAX_LEVELS) revert InvalidShapeSide(field, "more than 10 levels");
        uint32[] memory sizes = new uint32[](levels.length);
        uint16[] memory spreads = new uint16[](levels.length);
        // Any malformed level rejects the whole side; the only calls are pure cheatcodes.
        // forge-lint: disable-start(require-revert-in-loop, calls-loop)
        for (uint256 i = 0; i < levels.length; ++i) {
            string[] memory parts = vm.split(vm.trim(levels[i]), ":");
            if (parts.length != 2) revert InvalidShapeSide(field, "level is not size:spread");
            uint256 size = vm.parseUint(vm.trim(parts[0]));
            uint256 spread = vm.parseUint(vm.trim(parts[1]));
            if (size == 0 || size > type(uint32).max) revert InvalidShapeSide(field, "size must be 1..2^32-1");
            if (spread > type(uint16).max) revert InvalidShapeSide(field, "spread must be 0..65535");
            // Both bounded just above.
            // forge-lint: disable-next-line(unsafe-typecast)
            sizes[i] = uint32(size);
            // forge-lint: disable-next-line(unsafe-typecast)
            spreads[i] = uint16(spread);
        }
        // forge-lint: disable-end(require-revert-in-loop, calls-loop)
        (w0, w1) = ShapeWord.packSide(sizes, spreads);
        if (ShapeWord.checkSide(w0, w1) == ShapeWord.REASON_SPREAD_DECREASES) {
            revert InvalidShapeSide(field, "spreads must not decrease");
        }
    }

    /// @notice Parses one `PAIR_ACCESS` entry: `closed`, `listed` or `open`, surrounding spaces ignored. Anything else
    /// reverts, so a typo never opens a pair.
    function parseAccess(string memory entry) public pure returns (IVenue.AccessMode) {
        // Called per pair while reading the lists; the only call is a pure cheatcode, and one bad entry rejects them
        // all.
        // forge-lint: disable-next-line(calls-loop)
        bytes32 h = keccak256(bytes(vm.trim(entry)));
        if (h == keccak256("closed")) return IVenue.AccessMode.Closed;
        if (h == keccak256("listed")) return IVenue.AccessMode.Listed;
        if (h == keccak256("open")) return IVenue.AccessMode.Open;
        // forge-lint: disable-next-line(require-revert-in-loop)
        revert InvalidConfig("PAIR_ACCESS must be closed, listed or open");
    }

    /// @dev Test harnesses override this to avoid process-global environment races between parallel tests.
    function _readConfig() internal view virtual returns (Config memory c) {
        c.factory = IVenueFactory(vm.envAddress("VENUE_FACTORY"));
        c.owner = vm.envAddress("OWNER");
        c.salt = bytes(vm.envOr("VENUE_SALT", string(""))).length == 0 ? bytes32(0) : vm.envBytes32("VENUE_SALT");
        c.updater = vm.envOr("UPDATER", address(0));

        address[] memory bases = vm.envAddress("PAIR_BASES", ",");
        address[] memory quotes = vm.envAddress("PAIR_QUOTES", ",");
        uint256[] memory sizeUnits = vm.envUint("PAIR_SIZE_UNITS", ",");
        string[] memory access = vm.envString("PAIR_ACCESS", ",");
        uint256 count = bases.length;
        if (quotes.length != count || sizeUnits.length != count || access.length != count) {
            revert InvalidConfig("PAIR_* lists must have equal lengths");
        }
        uint256[] memory minMids = _optionalUintList("PAIR_MID_MINS");
        uint256[] memory maxMids = _optionalUintList("PAIR_MID_MAXS");
        bool banded = minMids.length != 0 || maxMids.length != 0;
        if (banded && (minMids.length != count || maxMids.length != count)) {
            revert InvalidConfig("PAIR_MID_* lists must be unset or have one entry per pair");
        }
        c.pairs = new PairInput[](count);
        for (uint256 i = 0; i < count; ++i) {
            c.pairs[i] = PairInput({
                base: bases[i],
                quote: quotes[i],
                sizeUnit: _uint64(sizeUnits[i], "PAIR_SIZE_UNITS"),
                access: parseAccess(access[i]),
                minMid: banded ? _uint96(minMids[i], "PAIR_MID_MINS") : 0,
                maxMid: banded ? _uint96(maxMids[i], "PAIR_MID_MAXS") : 0
            });
        }

        c.homeAllowed = vm.envOr("HOME_ALLOWED", ",", new address[](0));
        uint256[] memory ids = vm.envOr("SPONSOR_IDS", ",", new uint256[](0));
        c.sponsorIds = new uint64[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            c.sponsorIds[i] = _uint64(ids[i], "SPONSOR_IDS");
        }
        c.sponsorAdmins = vm.envOr("SPONSOR_ADMINS", ",", new address[](0));

        c.quotedPair = _uint16(_optionalUint("QUOTED_PAIR", 0), "QUOTED_PAIR");
        uint256 shapeId = _optionalUint("SHAPE_ID", 0);
        if (shapeId > type(uint8).max) revert InvalidConfig("SHAPE_ID");
        // Bounded just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.shapeId = uint8(shapeId);
        c.shapeBid = vm.envString("SHAPE_BID");
        c.shapeAsk = vm.envString("SHAPE_ASK");

        uint256 mid = vm.envUint("MID");
        if (mid > type(uint96).max) revert InvalidConfig("MID");
        // Bounded just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.mid = uint96(mid);
        c.bidWiden = _uint16(_optionalUint("BID_WIDEN", 0), "BID_WIDEN");
        c.askWiden = _uint16(_optionalUint("ASK_WIDEN", 0), "ASK_WIDEN");
        c.widthScale = _uint16(_optionalUint("WIDTH_SCALE", 1000), "WIDTH_SCALE");
        c.depthScale = _uint16(_optionalUint("DEPTH_SCALE", 1000), "DEPTH_SCALE");
        uint256 validFor = _optionalUint("VALID_FOR", 3600);
        if (validFor > type(uint40).max) revert InvalidConfig("VALID_FOR");
        // Bounded just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.validFor = uint40(validFor);
    }

    /// @dev Default only absent or explicitly empty inputs; never hide a nonempty value that fails to parse.
    function _optionalUint(string memory field, uint256 defaultValue) internal view returns (uint256) {
        if (bytes(vm.envOr(field, string(""))).length == 0) return defaultValue;
        return vm.envUint(field);
    }

    /// @dev Only an absent or explicitly empty list means no bands. The numeric `envOr` overload also defaults on
    /// malformed input, which could silently remove both bands before enabling the updater.
    function _optionalUintList(string memory field) internal view returns (uint256[] memory) {
        if (bytes(vm.envOr(field, string(""))).length == 0) return new uint256[](0);
        return vm.envUint(field, ",");
    }

    /// @dev TIP-1022 virtual addresses have bytes 4 to 13 all 0xFD, registered or not.
    function _isVirtual(address account) internal pure returns (bool) {
        return ((uint160(account) >> 48) & type(uint80).max) == 0xFDFDFDFDFDFDFDFDFDFD;
    }

    /// @dev Checks every input before the first transaction, and returns the shape words.
    function _preflight(Config memory config) internal view returns (uint256[4] memory words) {
        IVenueFactory factory = config.factory;
        if (address(factory).code.length == 0 || factory.implementation().code.length == 0) {
            revert InvalidConfig("VENUE_FACTORY");
        }
        if (config.owner == address(0)) revert InvalidConfig("OWNER");
        address predicted = factory.predictVenue(config.owner, config.salt);
        if (predicted.code.length != 0) revert VenueExists(predicted);

        uint256 count = config.pairs.length;
        if (count == 0) revert InvalidConfig("PAIR_BASES");
        // A read-only check of operator input before anything is sent: any bad pair stops the whole run.
        // forge-lint: disable-start(require-revert-in-loop, calls-loop)
        for (uint256 i = 0; i < count; ++i) {
            PairInput memory p = config.pairs[i];
            if (p.base == address(0) || p.quote == address(0) || p.base == p.quote) {
                revert InvalidConfig("PAIR tokens");
            }
            // TIP-20 precompiles carry a one-byte code placeholder. The factory also rejects a reserved-prefix address
            // until a token was initialized there, so preflight keeps a bad pair from creating an unusable venue.
            if (
                p.base.code.length == 0 || p.quote.code.length == 0 || !TIP20Factory.isTIP20(p.base)
                    || !TIP20Factory.isTIP20(p.quote)
            ) revert InvalidConfig("PAIR tokens");
            if (ITIP20(p.base).decimals() != ITIP20(p.quote).decimals()) revert InvalidConfig("PAIR decimals");
            if (p.sizeUnit == 0) revert InvalidConfig("PAIR_SIZE_UNITS");
            // `setMidBand`'s rule: `(0, 0)` or `0 < minMid <= maxMid`.
            if (p.maxMid == 0 ? p.minMid != 0 : p.minMid == 0 || p.minMid > p.maxMid) {
                revert InvalidConfig("PAIR_MID_MINS and PAIR_MID_MAXS");
            }
        }
        // `setMembers`'s rules plus callable takers: a virtual address never calls; list its master instead.
        if (config.homeAllowed.length > MAX_BATCH) revert InvalidConfig("HOME_ALLOWED");
        for (uint256 i = 0; i < config.homeAllowed.length; ++i) {
            address account = config.homeAllowed[i];
            if (account == address(0) || account == predicted || _isVirtual(account)) {
                revert InvalidConfig("HOME_ALLOWED");
            }
        }
        // Zero means no updater; a virtual address could never post.
        if (_isVirtual(config.updater)) revert InvalidConfig("UPDATER");
        // `addSponsor`'s rules: a nonzero id (0 is the home list) registered once, with an admin that can call: not zero,
        // the venue or a TIP-1022 virtual address (bytes 4 to 13 all 0xFD). The venue is new, so none is registered yet,
        // and the id is bound to its admin in the same call.
        uint64[] memory ids = config.sponsorIds;
        if (config.sponsorAdmins.length != ids.length) {
            revert InvalidConfig("SPONSOR_ADMINS needs one entry per SPONSOR_IDS id");
        }
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == 0) revert InvalidConfig("SPONSOR_IDS has 0, the home list");
            for (uint256 j = 0; j < i; ++j) {
                if (ids[j] == ids[i]) revert InvalidConfig("SPONSOR_IDS has a duplicate");
            }
            address admin = config.sponsorAdmins[i];
            if (admin == address(0) || admin == predicted || _isVirtual(admin)) revert InvalidConfig("SPONSOR_ADMINS");
        }
        // forge-lint: disable-end(require-revert-in-loop, calls-loop)
        if (config.quotedPair >= count) revert InvalidConfig("QUOTED_PAIR");

        (words[0], words[1]) = parseSide(config.shapeBid, "SHAPE_BID");
        (words[2], words[3]) = parseSide(config.shapeAsk, "SHAPE_ASK");
        if (words[0] == 0 && words[2] == 0) revert InvalidConfig("SHAPE_BID and SHAPE_ASK are both empty");
        if (config.mid == 0) revert InvalidConfig("MID");
        // The owner's own post isn't band-checked, so check here that the first word respects the band.
        PairInput memory quoted = config.pairs[config.quotedPair];
        if (quoted.maxMid != 0 && (config.mid < quoted.minMid || config.mid > quoted.maxMid)) {
            revert InvalidConfig("MID is outside QUOTED_PAIR's mid band");
        }
        // An overflow bound on the hot word's field, not a time-sensitive decision.
        // forge-lint: disable-next-line(block-timestamp)
        if (config.validFor == 0 || block.timestamp + config.validFor > type(uint40).max) {
            revert InvalidConfig("VALID_FOR");
        }
    }

    function _checkSetup(Config memory config, Setup memory setup) internal view {
        IVenue venue = setup.venue;
        if (!config.factory.isVenue(address(venue))) revert UnexpectedVenueState("factory.isVenue");
        if (venue.owner() != config.owner) revert UnexpectedVenueState("owner");
        if (venue.settler() != config.factory.defaultSettler()) revert UnexpectedVenueState("settler");
        if (config.updater != address(0) && !venue.isUpdater(config.updater)) revert UnexpectedVenueState("updater");
        if (venue.halted()) revert UnexpectedVenueState("halted");
        if (venue.pairCount() != config.pairs.length) revert UnexpectedVenueState("pairCount");
        // Read-only post-checks of the venue this run created.
        // forge-lint: disable-start(require-revert-in-loop, calls-loop)
        for (uint256 i = 0; i < config.pairs.length; ++i) {
            PairInput memory p = config.pairs[i];
            // Pair indexes are below `pairCount`, a uint16.
            // forge-lint: disable-next-line(unsafe-typecast)
            IVenue.Pair memory stored = venue.pair(uint16(i));
            if (
                stored.base != p.base || stored.quote != p.quote || stored.sizeUnit != p.sizeUnit
                    || stored.access != p.access
            ) revert UnexpectedVenueState("pair");
            // forge-lint: disable-next-line(unsafe-typecast)
            (uint96 minMid, uint96 maxMid) = venue.midBand(uint16(i));
            if (minMid != p.minMid || maxMid != p.maxMid) revert UnexpectedVenueState("midBand");
            // forge-lint: disable-next-line(unsafe-typecast)
            _checkPairAccess(venue, config, uint16(i), p.access == IVenue.AccessMode.Listed);
        }
        // Each sponsor is registered to its admin, on, and on its first list.
        for (uint256 i = 0; i < config.sponsorIds.length; ++i) {
            (address admin, bool enabled, uint32 generation) = venue.sponsor(config.sponsorIds[i]);
            if (admin != config.sponsorAdmins[i] || !enabled || generation != 1) {
                revert UnexpectedVenueState("SPONSOR_IDS");
            }
        }
        // forge-lint: disable-end(require-revert-in-loop, calls-loop)
        uint256[4] memory shape = venue.shape(config.quotedPair, config.shapeId);
        for (uint256 i = 0; i < 4; ++i) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (shape[i] != setup.shape[i]) revert UnexpectedVenueState("shape");
        }
        // `post` skips a stale seq silently, so check that the word landed.
        if (venue.hotWord(config.quotedPair) != setup.hotWord) revert UnexpectedVenueState("hotWord");
    }

    /// @dev A `listed` pair admits every sponsor and lists every `HOME_ALLOWED` account on its home list; any other pair
    /// admits no sponsor and lists no one.
    function _checkPairAccess(IVenue venue, Config memory config, uint16 pairIndex, bool listed) internal view {
        // Read-only post-checks of the venue this run created.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        for (uint256 i = 0; i < config.sponsorIds.length; ++i) {
            if (venue.pairSponsor(pairIndex, config.sponsorIds[i]) != listed) {
                revert UnexpectedVenueState("pairSponsor");
            }
        }
        for (uint256 i = 0; i < config.homeAllowed.length; ++i) {
            if (venue.isMember(pairIndex, 0, config.homeAllowed[i]) != listed) {
                revert UnexpectedVenueState("HOME_ALLOWED");
            }
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    function _log(Config memory config, Setup memory setup) internal view {
        console2.log("Venue", address(setup.venue));
        console2.log("Owner", config.owner);
        console2.log("Settler", setup.venue.settler());
        console2.log("Home list accounts listed on each listed pair", config.homeAllowed.length);
        for (uint256 i = 0; i < config.sponsorIds.length; ++i) {
            console2.log("Sponsor id / admin", uint256(config.sponsorIds[i]), config.sponsorAdmins[i]);
        }
        if (config.updater != address(0)) console2.log("Updater", config.updater);
        for (uint256 i = 0; i < config.pairs.length; ++i) {
            PairInput memory p = config.pairs[i];
            console2.log("Pair index", i);
            console2.log("  base / quote", p.base, p.quote);
            console2.log(
                "  size unit / access mode (1 closed, 2 listed, 3 open)", uint256(p.sizeUnit), uint256(p.access)
            );
            if (p.maxMid != 0) console2.log("  mid band", uint256(p.minMid), uint256(p.maxMid));
            else console2.log("  mid band: none");
        }
        console2.log("Quoted pair / shape id", uint256(config.quotedPair), uint256(config.shapeId));
        console2.log("Shape bid words");
        console2.logBytes32(bytes32(setup.shape[0]));
        console2.logBytes32(bytes32(setup.shape[1]));
        console2.log("Shape ask words");
        console2.logBytes32(bytes32(setup.shape[2]));
        console2.logBytes32(bytes32(setup.shape[3]));
        console2.log("Hot word (valid until)", uint256(HotWord.validUntil(setup.hotWord)));
        console2.logBytes32(setup.hotWord);
        console2.log("Not done here: fund the venue with pair tokens, register the venue in Registry,");
        console2.log("and list takers on the home list (setMembers, id 0) or a sponsor's list (by its own admin).");
    }

    /// @dev The first hot word for `QUOTED_PAIR`, valid for `VALID_FOR` seconds from now.
    function _hotWord(Config memory config) internal view returns (bytes32) {
        return HotWord.pack(
            HotWord.Fields({
                mid: config.mid,
                bidWiden: config.bidWiden,
                askWiden: config.askWiden,
                widthScale: config.widthScale,
                depthScale: config.depthScale,
                shapeId: config.shapeId,
                // `_preflight` checked that this fits.
                // forge-lint: disable-next-line(unsafe-typecast)
                validUntil: uint40(block.timestamp + config.validFor),
                seq: FIRST_SEQ,
                flags: 0
            })
        );
    }

    /// @dev Adds every pair in order, each with its mid band right after it: the band goes on before the updater
    /// exists, so the hot key never quotes an unbanded pair. One or two transactions per pair.
    function _addPairs(IVenue venue, PairInput[] memory pairs) internal {
        for (uint256 i = 0; i < pairs.length; ++i) {
            PairInput memory p = pairs[i];
            // Calls to the venue this run just created.
            // forge-lint: disable-next-line(calls-loop)
            uint16 pairIndex = venue.addPair(p.base, p.quote, p.sizeUnit);
            // forge-lint: disable-next-line(calls-loop)
            if (p.maxMid != 0) venue.setMidBand(pairIndex, p.minMid, p.maxMid);
        }
    }

    /// @dev One `addSponsor` per sponsor, then one `setPairSponsor` per sponsor and `listed` pair.
    function _addSponsors(IVenue venue, Config memory config) internal {
        for (uint256 i = 0; i < config.sponsorIds.length; ++i) {
            // Calls to the venue this run just created.
            // forge-lint: disable-next-line(calls-loop)
            venue.addSponsor(config.sponsorIds[i], config.sponsorAdmins[i]);
            for (uint256 p = 0; p < config.pairs.length; ++p) {
                if (config.pairs[p].access != IVenue.AccessMode.Listed) continue;
                // Pair indexes are below `pairCount`, a uint16.
                // forge-lint: disable-next-line(unsafe-typecast, calls-loop)
                venue.setPairSponsor(uint16(p), config.sponsorIds[i], true);
            }
        }
    }

    /// @dev Sets each pair that isn't `Closed` to its mode, one transaction each. `Open` needs a halted venue, so with
    /// any `Open` pair the access calls are bracketed by a halt and an unhalt.
    function _openPairs(IVenue venue, PairInput[] memory pairs) internal {
        bool anyOpen = _anyOpen(pairs);
        if (anyOpen) venue.setHalted(true);
        for (uint256 i = 0; i < pairs.length; ++i) {
            IVenue.AccessMode access = pairs[i].access;
            // Pair indexes are below `pairCount`, a uint16, and the calls go to the venue this run just created.
            // forge-lint: disable-next-line(unsafe-typecast, calls-loop)
            if (access != IVenue.AccessMode.Closed) venue.setPairAccess(uint16(i), access);
        }
        if (anyOpen) venue.setHalted(false);
    }

    /// @dev Lists `HOME_ALLOWED` on the home list of every `listed` pair, in `setMembers` calls of at most
    /// `HOME_ALLOWED_CHUNK` accounts each. Sends nothing for an empty list.
    function _allowHome(IVenue venue, Config memory config) internal {
        address[] memory accounts = config.homeAllowed;
        uint256 length = accounts.length;
        for (uint256 p = 0; p < config.pairs.length; ++p) {
            if (config.pairs[p].access != IVenue.AccessMode.Listed) continue;
            for (uint256 start = 0; start < length; start += HOME_ALLOWED_CHUNK) {
                uint256 end = start + HOME_ALLOWED_CHUNK < length ? start + HOME_ALLOWED_CHUNK : length;
                // At most `MAX_BATCH / HOME_ALLOWED_CHUNK` calls per pair, to the venue this run just created; pair
                // indexes are below `pairCount`, a uint16.
                // forge-lint: disable-next-line(calls-loop, unsafe-typecast)
                venue.setMembers(uint16(p), 0, _slice(accounts, start, end), true);
            }
        }
    }

    /// @dev `accounts[start:end]` as a new array.
    function _slice(address[] memory accounts, uint256 start, uint256 end)
        internal
        pure
        returns (address[] memory chunk)
    {
        // A memory allocation, not an external call: the lint counts `new` as one when a loop calls this.
        // forge-lint: disable-next-line(calls-loop)
        chunk = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            chunk[i - start] = accounts[i];
        }
    }

    function _anyOpen(PairInput[] memory pairs) internal pure returns (bool) {
        for (uint256 i = 0; i < pairs.length; ++i) {
            if (pairs[i].access == IVenue.AccessMode.Open) return true;
        }
        return false;
    }

    function _uint16(uint256 value, string memory field) internal pure returns (uint16) {
        if (value > type(uint16).max) revert InvalidConfig(field);
        // Bounded just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }

    function _uint96(uint256 value, string memory field) internal pure returns (uint96) {
        // Called per pair while reading the lists; one bad entry rejects them all.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (value > type(uint96).max) revert InvalidConfig(field);
        // Bounded just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(value);
    }

    function _uint64(uint256 value, string memory field) internal pure returns (uint64) {
        // Called per pair while reading the lists; one bad entry rejects them all.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (value > type(uint64).max) revert InvalidConfig(field);
        // Bounded just above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }
}

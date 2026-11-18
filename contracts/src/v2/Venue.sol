// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ITIP20 } from "../interfaces/ITIP20.sol";
import { IVenue } from "./interfaces/IVenue.sol";
import { IVenueHook, VenueHookFlags } from "./interfaces/IVenueHook.sol";
import { HotWord } from "./libraries/HotWord.sol";
import { LadderMath } from "./libraries/LadderMath.sol";
import { ShapeWord } from "./libraries/ShapeWord.sol";
import { TIP20Factory } from "./libraries/TIP20Factory.sol";

/// @notice One maker's venue: that maker's inventory, curves and pair hooks for all of their pairs. Deployed as a
/// minimal clone by `VenueFactory`, so every clone shares the implementation's immutables, and each clone's code
/// carries its CREATE2 salt, which proves the factory deployed it (`IVenueFactory.isVenue`). The implementation is
/// deployed on its own, against the factory's address, and only that factory can initialize a clone.
/// @dev Trust assumptions:
/// - `fill` does not re-verify that the input arrived. The settler is the owner-chosen trusted caller and moves the
///   input into the venue before calling `fill`; a settler that doesn't can drain the venue at its own curve.
/// - A pair's hook is trusted code chosen by the owner. It runs on every fill of its pair and can block that pair,
///   but the balance checks around each callback stop it from taking anything beyond what `hookTake` allows.
/// - An updater prices all of the venue's inventory, including what a pair's hook can pull. A pair's mid band is the
///   owner's bound on that: asks never sit below mid and bids never above it, so with a band an updater can't make
///   the venue sell base below `minMid` or buy it above `maxMid`.
/// - The settler passes its own caller as the taker, so the taker is the account that pays and is paid. `fill` pays
///   the taker as given and requires its exact credit, so a taker whose token forwards or parks the payment reverts
///   every such fill.
///
/// Access is held in the venue's own storage, `[pairIndex][sponsorId][account] -> listed`, and calls nothing. Each fill
/// names the sponsor its taker trades under (`sponsorId`): 0 for the venue's home list, which only the current owner
/// edits and every pair admits, or a sponsor the owner registered (`addSponsor`), switched on (`setSponsorEnabled`) and
/// admitted on the pair (`setPairSponsor`), whose admin alone lists its users there (`setMembers`). On a `Listed` pair
/// the taker must be on that list. `Open` admits everyone and `Closed` no one, reading no list. A denied taker
/// (`setDenied`) never fills, whatever any list says and on `Open` pairs too; only `Closed` is checked first. Denials
/// are venue-wide; lists and admissions are per pair.
///
/// One venue-wide transient lock guards every state-changing function except `initialize`, which makes no external
/// call, and `hookTake`, which only works inside the lock. `quote` and the views never take it, so a hook may call them
/// mid-fill.
///
/// Fills take depth off the ladder like orders off a book: each pair stores, per side, the base its fills have taken
/// since the maker last refilled that side, and each fill walks the ladder from there and adds what it took. Only the
/// maker gives depth back, with a refill bit on a `post` (`HotWord.FLAG_REFILL_BIDS`, `FLAG_REFILL_ASKS`). Opposite
/// trades take from the other side and never give any back.
contract Venue is IVenue, ReentrancyGuardTransient {
    /// @inheritdoc IVenue
    uint256 public constant HOOK_VIEW_GAS = 1_500_000;
    /// @inheritdoc IVenue
    uint256 public constant MAX_BATCH = 100;
    /// @inheritdoc IVenue
    uint64 public constant NO_PRIORITY_FEE_CAP = type(uint64).max;
    /// @inheritdoc IVenue
    uint64 public constant DEFAULT_TAKER_PRIORITY_FEE_CAP = 10 gwei;

    /// @dev One `post` entry: `[uint16 pairIndex][bytes32 hotWord]`.
    uint256 private constant POST_ENTRY_BYTES = 34;
    /// @dev Shape word offset of a side: bids are words 0 and 1, asks words 2 and 3.
    uint256 private constant ASK_WORDS = 2;

    /// @dev The home list's sponsor id and its constant `generation`: an owner's listing stores 1.
    uint64 private constant HOME = 0;
    uint32 private constant HOME_GENERATION = 1;
    /// @dev A pair's admission of a sponsor: 0 if never admitted, `ADMITTED`, or `REMOVED`, which keeps the slot
    /// nonzero so a later admission rewrites it rather than paying for a new slot (about 250,000 gas on Tempo).
    uint8 private constant ADMITTED = 1;
    uint8 private constant REMOVED = 2;
    /// @dev A `Consumption` slot with nothing consumed: both sides 0 and `live` (bit 240) set.
    uint256 private constant FRESH_CONSUMPTION = 1 << 240;
    /// @dev The TIP-1022 virtual-address layout: bytes 4 to 13 of the address all `0xFD`.
    uint80 private constant VIRTUAL_MAGIC = 0xFDFDFDFDFDFDFDFDFDFD;

    /// @dev The only account that can initialize a clone. The implementation's executable code depends only on this
    /// and the source, so `DeployV2` can compare it with a fresh build.
    address private immutable FACTORY;

    /// @dev Two slots: `{ base, access }` and `{ quote, sizeUnit, hookFlags }`. `fill` reads both anyway (the token
    /// binding and the ladder), so the access mode costs it no extra slot. `access` is never `None` while the pair
    /// exists.
    struct PairConfig {
        address base;
        AccessMode access;
        address quote;
        uint64 sizeUnit;
        uint8 hookFlags;
    }

    /// @notice A registered sponsor. One slot: a fill under it reads only this, the pair's admission and the member.
    /// @dev `admin` is never zero once registered, so a zero admin means an unregistered id. A member's slot stores the
    /// `generation` it was listed in, and admits only while that is still the sponsor's: `resetSponsor` raises it,
    /// voiding every earlier listing at once, and a later listing of the same account is a nonzero-to-nonzero write
    /// rather than a 250,000-gas slot creation.
    struct Sponsor {
        address admin;
        bool enabled;
        uint32 generation;
    }

    /// @dev The base each side's ladder has given up since the maker last refilled it: `bids` from takers selling base,
    /// `asks` from takers buying it. One slot per pair, which `addPair` creates and only `removePair` deletes: `live`
    /// is always set, so a fill or a refill rewrites it, nonzero to nonzero, rather than paying for a new slot (about
    /// 250,000 gas on Tempo). A side's total stays below 2^107 (`LadderMath`), so a uint120 holds it.
    struct Consumption {
        uint120 bids;
        uint120 asks;
        bool live;
    }

    /// @dev An owner-set bound on the mids an updater may post. `maxMid == 0` means no band.
    struct MidBand {
        uint96 minMid;
        uint96 maxMid;
    }

    /// @dev The shared pricing path's result. `consumed` is the walked side's offset before the fill.
    struct Pricing {
        bool baseIn;
        AccessMode access;
        uint8 hookFlags;
        bytes32 hot;
        uint256 amountIn;
        uint256 amountOut;
        uint256 consumed;
        uint256 baseFilled;
    }

    address public owner;
    uint16 public pairCount;
    /// @dev How many live pairs have a mid band. It shares the owner's slot, which `post` reads anyway, so `post`
    /// reads per-pair bands only while at least one exists and a venue without bands pays nothing for them.
    uint16 private _bandedPairs;
    // The settler's slot holds every venue-wide word a fill reads: `fill` reads `settler` in its first check, so
    // `halted`, the deny count and the priority-fee cap come warm and a fill reads one venue-wide slot on every access
    // path. `fill` never reads the owner's slot. `test_accessWordLayout` (test/v2/VenueAccess.t.sol) and
    // `test_capPacksIntoTheSettlerSlot` (test/v2/TakerPriorityFee.t.sol) pin the layout.
    address public settler;
    bool public halted;
    /// @dev `deniedCount`, a uint24 so the slot holds it: each denial is its own fresh slot, so 2^24 of them are out
    /// of reach, and the checked increment would revert the batch rather than wrap.
    uint24 private _deniedCount;
    /// @dev `maxTakerPriorityFee`, bit-inverted, so the zero a new clone starts with reads as `NO_PRIORITY_FEE_CAP`
    /// without `initialize` writing it. It fills the rest of the settler's slot.
    uint64 private _invertedFeeCap;
    address public pendingOwner;
    mapping(address account => bool allowed) public isUpdater;
    mapping(uint16 pairIndex => PairConfig) private _pairs;
    mapping(uint16 pairIndex => address hook) private _hooks;
    mapping(uint16 pairIndex => bytes32 word) private _hot;
    /// @dev Keyed `pairIndex << 10 | shapeId << 2 | word`. Zero words are never stored.
    mapping(uint256 key => uint256 word) private _shapeWords;
    mapping(uint16 pairIndex => MidBand) private _midBands;
    /// @inheritdoc IVenue
    mapping(address account => bool isDenied) public denied;
    mapping(uint64 sponsorId => Sponsor) private _sponsors;
    /// @inheritdoc IVenue
    mapping(uint64 sponsorId => address pendingAdmin) public pendingSponsorAdmin;
    /// @dev The owner's per-pair admissions of registered sponsors (`ADMITTED` or `REMOVED`; 0 if never admitted). The
    /// home list is never stored: every pair admits it.
    mapping(uint16 pairIndex => mapping(uint64 sponsorId => uint8 admission)) private _admitted;
    /// @dev `[pairIndex][sponsorId][account]`: the sponsor's `generation` the account was listed in, or 0 for none.
    mapping(uint16 pairIndex => mapping(uint64 sponsorId => mapping(address account => uint32 generation))) private
        _members;
    /// @dev Each pair's consumed depth (`Consumption`), which every fill reads and writes and only a refill lowers.
    mapping(uint16 pairIndex => Consumption) private _consumption;

    /// @dev The `hookTake` window, open only during an `afterFill` with TAKE_INPUT.
    address private transient _takeHook;
    address private transient _takeToken;
    uint256 private transient _takeRemaining;
    bytes32 private transient _takeRef;

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier onlyOwnerOrUpdater() {
        _onlyOwnerOrUpdater();
        _;
    }

    /// @param factory_ The factory that will clone this implementation: the only account that can initialize a clone.
    /// It is deployed after the implementation, so this is its predicted address, and its constructor checks it.
    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IVenue
    /// @dev Makes no external call, so it takes no lock. The factory only calls it on the clone it has just created,
    /// so the implementation itself never gets an owner or a settler. Emits nothing: the factory's `VenueCreated`
    /// records the owner, and the settler is the factory's default.
    ///
    /// The factory must already have code. A contract's constructor runs at its address before it has any, and can
    /// still return the factory's exact runtime, which no code or getter check of the factory can tell apart. Without
    /// this, such a constructor could deploy a clone at a real venue address and initialize it with a settler of its
    /// choosing. Its clone instead stays uninitialized for good: the factory's runtime never initializes a clone it
    /// didn't just create (`createVenue` refuses an occupied address), and nothing else can.
    function initialize(address owner_, address settler_) external {
        if (msg.sender != FACTORY || FACTORY.code.length == 0) revert NotFactory();
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0) || settler_ == address(0)) revert ZeroAddress();
        // The factory's `VenueCreated`, emitted just before this call in the same `createVenue`, records the owner, and
        // the settler is the factory's immutable `defaultSettler`.
        // forge-lint: disable-next-line(missing-events-access-control)
        owner = owner_;
        // forge-lint: disable-next-line(missing-events-access-control)
        settler = settler_;
    }

    /// @inheritdoc IVenue
    function addPair(address baseToken, address quoteToken, uint64 sizeUnit)
        external
        nonReentrant
        onlyOwner
        returns (uint16 pairIndex)
    {
        if (
            baseToken == address(0) || quoteToken == address(0) || baseToken == quoteToken || baseToken.code.length == 0
                || quoteToken.code.length == 0 || !TIP20Factory.isTIP20(baseToken) || !TIP20Factory.isTIP20(quoteToken)
        ) revert InvalidPairTokens();
        uint8 baseDecimals = ITIP20(baseToken).decimals();
        uint8 quoteDecimals = ITIP20(quoteToken).decimals();
        if (baseDecimals != quoteDecimals) revert DecimalsMismatch(baseDecimals, quoteDecimals);
        if (sizeUnit == 0) revert InvalidSizeUnit();

        pairIndex = pairCount;
        if (pairIndex == type(uint16).max) revert PairLimitReached();
        pairCount = pairIndex + 1;
        _pairs[pairIndex] = PairConfig({
            base: baseToken, access: AccessMode.Closed, quote: quoteToken, sizeUnit: sizeUnit, hookFlags: 0
        });
        _hot[pairIndex] = HotWord.INITIAL;
        // A full ladder on both sides, in a slot that stays nonzero for the pair's life.
        _freshConsumption(pairIndex);
        // A new pair is always `Closed`, so `PairAdded` records its mode too. The lint reads `_freshConsumption`'s
        // assembly store as a possible external call; the only calls here are the factory
        // `isTIP20` staticcalls and token `decimals()` views above, under `nonReentrant`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PairAdded(pairIndex, baseToken, quoteToken, sizeUnit);
    }

    /// @inheritdoc IVenue
    /// @dev Clearing the band and the consumed depth emits no `MidBandSet` or `Refilled`: `PairRemoved` covers them, as
    /// it covers the hook.
    function removePair(uint16 pairIndex) external nonReentrant onlyOwner {
        _existingPair(pairIndex);
        delete _pairs[pairIndex];
        delete _hot[pairIndex];
        delete _hooks[pairIndex];
        delete _consumption[pairIndex];
        uint16 banded = _bandedPairs;
        if (banded != 0 && _midBands[pairIndex].maxMid != 0) {
            delete _midBands[pairIndex];
            _bandedPairs = banded - 1;
        }
        emit PairRemoved(pairIndex);
    }

    /// @inheritdoc IVenue
    function setPairAccess(uint16 pairIndex, AccessMode mode) external nonReentrant onlyOwner {
        PairConfig storage config = _existingPair(pairIndex);
        AccessMode oldMode = config.access;
        if (mode != oldMode) {
            if (mode == AccessMode.None) revert InvalidAccessMode();
            if (mode == AccessMode.Open && !halted) revert NotHalted();
            config.access = mode;
        }
        emit PairAccessUpdated(pairIndex, oldMode, mode);
    }

    /// @inheritdoc IVenue
    function closePair(uint16 pairIndex) external nonReentrant onlyOwnerOrUpdater {
        PairConfig storage config = _existingPair(pairIndex);
        AccessMode oldMode = config.access;
        config.access = AccessMode.Closed;
        emit PairAccessUpdated(pairIndex, oldMode, AccessMode.Closed);
    }

    /// @inheritdoc IVenue
    function addSponsor(uint64 sponsorId, address admin) external nonReentrant onlyOwner {
        if (sponsorId == HOME || _sponsors[sponsorId].admin != address(0)) revert SponsorExists(sponsorId);
        _requireAccount(admin);
        _sponsors[sponsorId] = Sponsor({ admin: admin, enabled: true, generation: 1 });
        emit SponsorAdded(sponsorId, admin);
    }

    /// @inheritdoc IVenue
    function setSponsorEnabled(uint64 sponsorId, bool enabled) external nonReentrant {
        _narrowingAuthority(enabled);
        Sponsor storage record = _registered(sponsorId);
        // `SponsorEnabledSet` below records every call.
        // forge-lint: disable-next-line(missing-events-access-control)
        if (record.enabled != enabled) record.enabled = enabled;
        emit SponsorEnabledSet(sponsorId, enabled, msg.sender);
    }

    /// @inheritdoc IVenue
    function setPairSponsor(uint16 pairIndex, uint64 sponsorId, bool admitted) external nonReentrant {
        _narrowingAuthority(admitted);
        _registered(sponsorId);
        if (admitted) _existingPair(pairIndex);
        mapping(uint64 => uint8) storage pairAdmissions = _admitted[pairIndex];
        uint8 current = pairAdmissions[sponsorId];
        // A removal keeps the slot nonzero, so readmitting rewrites it; removing a sponsor never admitted writes
        // nothing.
        uint8 next = admitted ? ADMITTED : current == 0 ? 0 : REMOVED;
        // `PairSponsorSet` below records every call.
        // forge-lint: disable-next-line(missing-events-access-control)
        if (next != current) pairAdmissions[sponsorId] = next;
        emit PairSponsorSet(pairIndex, sponsorId, admitted, msg.sender);
    }

    /// @inheritdoc IVenue
    function setMembers(uint16 pairIndex, uint64 sponsorId, address[] calldata accounts, bool allowed)
        external
        nonReentrant
    {
        uint32 generation;
        if (sponsorId == HOME) {
            _onlyOwner();
            generation = HOME_GENERATION;
        } else {
            Sponsor memory record = _sponsors[sponsorId];
            if (msg.sender != record.admin) revert NotSponsorAdmin(sponsorId);
            if (allowed) {
                if (!record.enabled) revert SponsorDisabled(sponsorId);
                if (_admitted[pairIndex][sponsorId] != ADMITTED) revert SponsorNotAdmitted(pairIndex, sponsorId);
            }
            generation = record.generation;
        }
        // A listing needs a live pair; a sponsor's admission can outlive its pair, so this is checked on its own.
        if (allowed) _existingPair(pairIndex);
        uint256 length = accounts.length;
        if (length > MAX_BATCH) revert BatchTooLarge(length, MAX_BATCH);
        mapping(address => uint32) storage list = _members[pairIndex][sponsorId];
        uint32 next = allowed ? generation : 0;
        for (uint256 i = 0; i < length; ++i) {
            address account = accounts[i];
            // The batch is atomic by design: one bad entry reverts every change in it.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (account == address(0) || account == address(this)) revert InvalidAddress();
            // A delisting clears any stored generation, a stale one from before a reset included. Each account is its
            // own slot and `MAX_BATCH` bounds the loop.
            // forge-lint: disable-next-line(costly-loop)
            if (list[account] != next) list[account] = next;
            emit MemberUpdated(pairIndex, sponsorId, account, allowed);
        }
    }

    /// @inheritdoc IVenue
    function transferSponsorAdmin(uint64 sponsorId, address newAdmin) external nonReentrant {
        address admin = _sponsors[sponsorId].admin;
        // An unregistered id has no admin, and `msg.sender` is never zero.
        if (msg.sender != admin) revert NotSponsorAdmin(sponsorId);
        _requireAccount(newAdmin);
        pendingSponsorAdmin[sponsorId] = newAdmin;
        emit SponsorAdminTransferStarted(sponsorId, admin, newAdmin);
    }

    /// @inheritdoc IVenue
    function cancelSponsorAdminTransfer(uint64 sponsorId) external nonReentrant {
        address admin = _sponsors[sponsorId].admin;
        if (msg.sender != admin) revert NotSponsorAdmin(sponsorId);
        delete pendingSponsorAdmin[sponsorId];
        emit SponsorAdminTransferStarted(sponsorId, admin, address(0));
    }

    /// @inheritdoc IVenue
    function acceptSponsorAdmin(uint64 sponsorId) external nonReentrant {
        // A pending admin is never zero while it can be accepted, and `msg.sender` is never zero.
        if (msg.sender != pendingSponsorAdmin[sponsorId]) revert NotPendingSponsorAdmin(sponsorId);
        Sponsor storage record = _sponsors[sponsorId];
        emit SponsorAdminTransferred(sponsorId, record.admin, msg.sender);
        record.admin = msg.sender;
        // `SponsorAdminTransferred` above records the handover, and with it the cleared pending admin.
        // forge-lint: disable-next-line(missing-events-access-control)
        delete pendingSponsorAdmin[sponsorId];
    }

    /// @inheritdoc IVenue
    function resetSponsor(uint64 sponsorId, address newAdmin) external nonReentrant onlyOwner {
        Sponsor storage record = _registered(sponsorId);
        _requireAccount(newAdmin);
        address previous = record.admin;
        // Checked: 2^32 resets of one id are out of reach, and the increment would revert rather than wrap onto a
        // generation an old listing still stores.
        uint32 generation = record.generation + 1;
        record.admin = newAdmin;
        record.generation = generation;
        delete pendingSponsorAdmin[sponsorId];
        emit SponsorReset(sponsorId, previous, newAdmin, generation);
    }

    /// @inheritdoc IVenue
    function setDenied(address[] calldata accounts, bool deny) external nonReentrant {
        if (msg.sender != owner) {
            if (!isUpdater[msg.sender]) revert NotOwnerOrUpdater();
            if (!deny) revert NotOwner();
        }
        uint256 length = accounts.length;
        if (length > MAX_BATCH) revert BatchTooLarge(length, MAX_BATCH);
        uint24 oldCount = _deniedCount;
        uint24 count = oldCount;
        for (uint256 i = 0; i < length; ++i) {
            address account = accounts[i];
            // The batch is atomic by design: one bad entry reverts every change in it.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (account == address(0) || account == address(this)) revert InvalidAddress();
            if (denied[account] != deny) {
                // Each account is its own slot and `MAX_BATCH` bounds the loop; the count, the one shared slot, is
                // written once after it.
                // forge-lint: disable-next-line(costly-loop)
                denied[account] = deny;
                // Checked arithmetic, though neither can wrap: a lift only reaches a counted account, and 2^24 denials
                // (a fresh slot each) are out of reach.
                if (deny) ++count;
                else --count;
                emit DenyUpdated(account, deny, msg.sender);
            }
        }
        // The count sums the state transitions that the per-entry `DenyUpdated` events above record.
        // forge-lint: disable-next-line(missing-events-access-control)
        if (count != oldCount) _deniedCount = count;
    }

    /// @inheritdoc IVenue
    /// @dev Every rejection, a hook without code included, reverts `InvalidHookFlags`. A reverting
    /// `supportedFlags()` bubbles its revert.
    function setPairHook(uint16 pairIndex, address hook, uint8 flags) external nonReentrant onlyOwner {
        PairConfig storage config = _existingPair(pairIndex);
        bool incoherent = flags & ~VenueHookFlags.ALL != 0
            || (flags & VenueHookFlags.TAKE_INPUT != 0 && flags & VenueHookFlags.AFTER_FILL == 0);
        if (incoherent) revert InvalidHookFlags(flags);
        if (hook == address(0)) {
            if (flags != 0) revert InvalidHookFlags(flags);
        } else if (flags == 0 || hook.code.length == 0 || flags & ~IVenueHook(hook).supportedFlags() != 0) {
            revert InvalidHookFlags(flags);
        }
        config.hookFlags = flags;
        _hooks[pairIndex] = hook;
        emit PairHookSet(pairIndex, hook, flags);
    }

    /// @inheritdoc IVenue
    function setUpdater(address updater, bool allowed) external nonReentrant onlyOwner {
        if (isUpdater[updater] == allowed) return;
        isUpdater[updater] = allowed;
        emit UpdaterSet(updater, allowed);
    }

    /// @inheritdoc IVenue
    function setSettler(address settler_) external nonReentrant onlyOwner {
        if (settler_ == address(0)) revert ZeroAddress();
        settler = settler_;
        emit SettlerSet(settler_);
    }

    /// @inheritdoc IVenue
    function setHalted(bool halted_) external nonReentrant {
        if (halted_) _onlyOwnerOrUpdater();
        else _onlyOwner();
        if (halted == halted_) return;
        halted = halted_;
        emit HaltedSet(halted_);
    }

    /// @inheritdoc IVenue
    /// @dev Pays `to` as given and checks its exact credit: on Tempo a receiver's TIP-1028 receive policy doesn't
    /// revert a blocked transfer, it parks the funds in the ReceivePolicyGuard under a claim receipt. With the default
    /// originator recovery only the venue could claim it, and a venue has no call that could; with receiver or
    /// third-party recovery someone else could. The exact-credit check reverts every block, whatever the recovery mode,
    /// so nothing is ever parked, and likewise every transfer the token forwards to another account.
    function withdraw(address token, address to, uint256 amount, bytes32 memo) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 recipientBefore = ITIP20(token).balanceOf(to);
        _send(token, to, amount, memo);
        _requireCredit(token, to, recipientBefore, amount);
        emit Withdrawn(token, to, amount, memo);
    }

    /// @inheritdoc IVenue
    function transferOwnership(address newOwner) external nonReentrant onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(msg.sender, newOwner);
    }

    /// @inheritdoc IVenue
    function cancelOwnershipTransfer() external nonReentrant onlyOwner {
        delete pendingOwner;
        emit OwnershipTransferStarted(msg.sender, address(0));
    }

    /// @inheritdoc IVenue
    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        delete pendingOwner;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Quoting
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IVenue
    /// @dev `post` only raises `seq`, for the owner too. The owner can recover an exhausted sequence with
    /// `resetHotWord` while halted, without removing the pair. Only an updater's entries are band-checked, and only
    /// those `post` would accept, so a stale entry is skipped whatever its mid, and refills nothing whatever its flags. Per-pair bands are
    /// read only while some pair has one. The consumption slot is never read for an entry without a refill bit, and
    /// written only for one with.
    function post(bytes calldata packed) external nonReentrant {
        bool checkBands = _postAuthority();
        uint256 length = packed.length;
        if (length == 0 || length % POST_ENTRY_BYTES != 0) revert MalformedPost(length);
        for (uint256 offset; offset < length; offset += POST_ENTRY_BYTES) {
            uint16 pairIndex;
            bytes32 word;
            assembly ("memory-safe") {
                let entry := add(packed.offset, offset)
                pairIndex := shr(240, calldataload(entry))
                word := calldataload(add(entry, 2))
            }
            // A live pair's hot word is never zero (`seq >= 1`), so a zero word means unknown or removed.
            bytes32 stored = _hot[pairIndex];
            if (stored == bytes32(0)) revert UnknownPair(pairIndex);
            if (!HotWord.isWellFormed(word)) revert InvalidHotWord(pairIndex);
            if (HotWord.seq(word) <= HotWord.seq(stored)) continue;
            if (checkBands) _checkMidBand(pairIndex, HotWord.mid(word));
            // The refill bits act once, on this entry: the stored (and emitted) word never carries them, so a bot that
            // copies the stored word forward and bumps `seq` can't refill by accident.
            uint16 refill = HotWord.flags(word) & HotWord.FLAGS_REFILL;
            if (refill != 0) word = HotWord.withoutRefill(word);
            _hot[pairIndex] = word;
            emit Posted(pairIndex, word);
            if (refill != 0) _refill(pairIndex, refill);
        }
    }

    /// @inheritdoc IVenue
    function resetHotWord(uint16 pairIndex) external nonReentrant onlyOwner {
        _existingPair(pairIndex);
        if (!halted) revert NotHalted();
        uint32 previousSeq = HotWord.seq(_hot[pairIndex]);
        _hot[pairIndex] = HotWord.INITIAL;
        emit HotWordReset(pairIndex, previousSeq);
    }

    /// @inheritdoc IVenue
    /// @dev Emits `ShapeSet` even when no word changed, so the events alone describe every curve.
    function setShape(uint16 pairIndex, uint8 shapeId, uint256[4] calldata words)
        external
        nonReentrant
        onlyOwnerOrUpdater
    {
        if (pairIndex >= pairCount) revert UnknownPair(pairIndex);
        uint256[4] memory next = words;
        if (_pairs[pairIndex].base == address(0) && (next[0] | next[1] | next[2] | next[3]) != 0) {
            revert UnknownPair(pairIndex);
        }
        uint8 reason = ShapeWord.check(next);
        if (reason != 0) revert InvalidShape(reason);

        uint256 key = _shapeKey(pairIndex, shapeId);
        for (uint256 i; i < 4; ++i) {
            if (_shapeWords[key | i] != next[i]) _shapeWords[key | i] = next[i];
        }
        emit ShapeSet(pairIndex, shapeId, next);
    }

    /// @inheritdoc IVenue
    function setMaxTakerPriorityFee(uint64 cap) external nonReentrant onlyOwnerOrUpdater {
        _setMaxTakerPriorityFee(cap);
    }

    /// @inheritdoc IVenue
    function enableTakerPriorityFeeCap() external nonReentrant onlyOwnerOrUpdater {
        _setMaxTakerPriorityFee(DEFAULT_TAKER_PRIORITY_FEE_CAP);
    }

    /// @inheritdoc IVenue
    function setMidBand(uint16 pairIndex, uint96 minMid, uint96 maxMid) external nonReentrant onlyOwner {
        _existingPair(pairIndex);
        bool set = maxMid != 0;
        if (set ? minMid == 0 || minMid > maxMid : minMid != 0) revert InvalidMidBand();
        MidBand storage band = _midBands[pairIndex];
        if (set != (band.maxMid != 0)) {
            if (set) ++_bandedPairs;
            else --_bandedPairs;
        }
        band.minMid = minMid;
        band.maxMid = maxMid;
        emit MidBandSet(pairIndex, minMid, maxMid);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IVenue
    /// @dev Order: price from the side's consumed depth, check access (the transaction's priority fee against the
    /// venue's cap, then the taker), add the fill's base to the side's consumption, `beforeFill`, pay the taker with
    /// exact deltas on the venue and the taker, `afterFill`, emit. The amounts and the new consumption are final before
    /// any hook runs, so a hook that calls `quote` or `consumed` sees the depth after this fill.
    function fill(
        uint16 pairIndex,
        address tokenIn,
        address tokenOut,
        uint128 amount,
        bool exactIn,
        address taker,
        uint64 sponsorId,
        bytes32 ref
    ) external nonReentrant returns (uint128 amountIn, uint128 amountOut) {
        if (msg.sender != settler) revert NotSettler();
        if (halted) revert VenueHalted();
        // The cap shares the slot just read for `settler` and `halted`, so this reads nothing more.
        uint64 invertedCap = _invertedFeeCap;

        Pricing memory pricing = _price(pairIndex, tokenIn, tokenOut, amount, exactIn);
        TakerAccess outcome = _takerAccess(pairIndex, pricing.access, taker, sponsorId, invertedCap);
        if (outcome != TakerAccess.Allowed) _refuse(outcome, pairIndex, taker, sponsorId);

        // A filled side's offset plus its fill stays within the side's depth, below 2^107 (`LadderMath`).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint120 consumedAfter = uint120(pricing.consumed + pricing.baseFilled);
        Consumption storage consumption = _consumption[pairIndex];
        if (pricing.baseIn) consumption.bids = consumedAfter;
        else consumption.asks = consumedAfter;

        // `_price` bounds both amounts to uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        amountIn = uint128(pricing.amountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = uint128(pricing.amountOut);
        IVenueHook.FillContext memory context = IVenueHook.FillContext({
            pairIndex: pairIndex,
            taker: taker,
            sponsorId: sponsorId,
            ref: ref,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            exactIn: exactIn,
            makerMid: HotWord.mid(pricing.hot),
            seq: HotWord.seq(pricing.hot)
        });
        _settle(context, pricing.hookFlags);

        emit Fill(pairIndex, taker, ref, sponsorId, pricing.baseIn, amountIn, amountOut, context.makerMid, context.seq);
    }

    /// @inheritdoc IVenue
    /// @dev Doesn't take the lock: it only works inside `fill`, which holds it. Checks the hook's credit as well as the
    /// venue's debit, so a take the token parks elsewhere (a TIP-1028 block on the hook) reverts instead of stranding.
    function hookTake(address token, uint256 amount) external {
        // `msg.sender` is never zero, so a closed window (`_takeHook == 0`) rejects everyone.
        if (msg.sender != _takeHook || token != _takeToken) revert HookTakeNotAllowed();
        uint256 remaining = _takeRemaining;
        if (amount > remaining) revert HookTakeExceedsBudget(amount, remaining);
        _takeRemaining = remaining - amount;
        uint256 hookBefore = ITIP20(token).balanceOf(msg.sender);
        _send(token, msg.sender, amount, _takeRef);
        _requireCredit(token, msg.sender, hookBefore, amount);
    }

    /// @inheritdoc IVenue
    function quote(uint16 pairIndex, address tokenIn, address tokenOut, uint128 amount, bool exactIn)
        external
        view
        returns (uint128 amountIn, uint128 amountOut)
    {
        if (halted) revert VenueHalted();
        uint64 invertedCap = _invertedFeeCap;
        Pricing memory pricing = _price(pairIndex, tokenIn, tokenOut, amount, exactIn);
        // Where `fill`'s access check starts, so the two refuse an over-cap swap alike.
        if (_priorityFeeTooHigh(invertedCap)) _refusePriorityFee();
        uint256 balance = ITIP20(tokenOut).balanceOf(address(this));
        if (balance < pricing.amountOut) {
            uint256 extra = _hookLiquidity(pairIndex, pricing.hookFlags, tokenOut);
            uint256 available = extra > type(uint256).max - balance ? type(uint256).max : balance + extra;
            if (available < pricing.amountOut) revert InsufficientInventory(tokenOut, available, pricing.amountOut);
        }
        // `_price` bounds both amounts to uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        amountIn = uint128(pricing.amountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = uint128(pricing.amountOut);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IVenue
    function factory() external view returns (address) {
        return FACTORY;
    }

    /// @inheritdoc IVenue
    function pair(uint16 pairIndex) external view returns (Pair memory) {
        PairConfig storage config = _pairs[pairIndex];
        return Pair({
            base: config.base,
            quote: config.quote,
            sizeUnit: config.sizeUnit,
            access: config.access,
            hook: _hooks[pairIndex],
            hookFlags: config.hookFlags
        });
    }

    /// @inheritdoc IVenue
    function hotWord(uint16 pairIndex) external view returns (bytes32) {
        return _hot[pairIndex];
    }

    /// @inheritdoc IVenue
    function consumed(uint16 pairIndex) external view returns (uint128 bids, uint128 asks) {
        Consumption memory consumption = _consumption[pairIndex];
        return (consumption.bids, consumption.asks);
    }

    /// @inheritdoc IVenue
    function shape(uint16 pairIndex, uint8 shapeId) external view returns (uint256[4] memory words) {
        uint256 key = _shapeKey(pairIndex, shapeId);
        for (uint256 i; i < 4; ++i) {
            words[i] = _shapeWords[key | i];
        }
    }

    /// @inheritdoc IVenue
    function midBand(uint16 pairIndex) external view returns (uint96 minMid, uint96 maxMid) {
        MidBand storage band = _midBands[pairIndex];
        return (band.minMid, band.maxMid);
    }

    /// @inheritdoc IVenue
    function deniedCount() external view returns (uint32) {
        return _deniedCount;
    }

    /// @inheritdoc IVenue
    function maxTakerPriorityFee() external view returns (uint64) {
        return ~_invertedFeeCap;
    }

    /// @inheritdoc IVenue
    function sponsor(uint64 sponsorId) external view returns (address admin, bool enabled, uint32 generation) {
        Sponsor memory record = _sponsors[sponsorId];
        return (record.admin, record.enabled, record.generation);
    }

    /// @inheritdoc IVenue
    function pairSponsor(uint16 pairIndex, uint64 sponsorId) external view returns (bool) {
        if (_pairs[pairIndex].base == address(0)) return false;
        if (sponsorId == HOME) return true;
        return _admitted[pairIndex][sponsorId] == ADMITTED;
    }

    /// @inheritdoc IVenue
    function isMember(uint16 pairIndex, uint64 sponsorId, address account) external view returns (bool) {
        if (_pairs[pairIndex].base == address(0)) return false;
        uint32 stored = _members[pairIndex][sponsorId][account];
        return stored != 0 && stored == (sponsorId == HOME ? HOME_GENERATION : _sponsors[sponsorId].generation);
    }

    /// @inheritdoc IVenue
    /// @dev A removed or unknown pair reads `None` and is false without reading any list.
    function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (bool) {
        return
            _takerAccess(pairIndex, _pairs[pairIndex].access, taker, sponsorId, _invertedFeeCap) == TakerAccess.Allowed;
    }

    /// @inheritdoc IVenue
    /// @dev A removed or unknown pair reads `None` and is `UnknownPair` without reading any list.
    function takerAccess(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (TakerAccess) {
        return _takerAccess(pairIndex, _pairs[pairIndex].access, taker, sponsorId, _invertedFeeCap);
    }

    /// @inheritdoc IVenue
    /// @dev Never reverts, for any pair: a removed or unknown pair has no hook flags and reads 0.
    function hookLiquidity(uint16 pairIndex, address token) external view returns (uint256) {
        return _hookLiquidity(pairIndex, _pairs[pairIndex].hookFlags, token);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The pricing path `fill` and `quote` share: token binding, amount, hot word, active shape, the side's
    /// consumed depth, ladder.
    function _price(uint16 pairIndex, address tokenIn, address tokenOut, uint128 amount, bool exactIn)
        private
        view
        returns (Pricing memory pricing)
    {
        PairConfig storage config = _pairs[pairIndex];
        address baseToken = config.base;
        if (baseToken == address(0)) revert UnknownPair(pairIndex);
        address quoteToken = config.quote;
        bool baseIn = tokenIn == baseToken;
        if (baseIn ? tokenOut != quoteToken : (tokenIn != quoteToken || tokenOut != baseToken)) {
            revert TokenMismatch(tokenIn, tokenOut);
        }
        if (amount == 0) revert ZeroAmount();

        bytes32 hot = _hot[pairIndex];
        uint40 validUntil = HotWord.validUntil(hot);
        if (block.timestamp > validUntil) revert QuoteExpired(validUntil);
        if (HotWord.depthScale(hot) == 0 || HotWord.sideOff(hot, baseIn)) revert SideDisabled(baseIn);

        uint256 key = _shapeKey(pairIndex, HotWord.shapeId(hot)) | (baseIn ? 0 : ASK_WORDS);
        uint256 w0 = _shapeWords[key];
        uint256 w1 = ShapeWord.continues(w0) ? _shapeWords[key | 1] : 0;

        Consumption storage consumption = _consumption[pairIndex];
        uint256 offset = baseIn ? consumption.bids : consumption.asks;

        pricing.baseIn = baseIn;
        pricing.access = config.access;
        pricing.hookFlags = config.hookFlags;
        pricing.hot = hot;
        pricing.consumed = offset;

        (pricing.amountIn, pricing.amountOut, pricing.baseFilled) =
            LadderMath.fill(LadderMath.curve(hot, config.sizeUnit, baseIn), w0, w1, exactIn, amount, offset);
        if (pricing.amountIn > type(uint128).max || pricing.amountOut > type(uint128).max) revert AmountOverflow();
    }

    /// @dev The transaction's priority fee per gas: its gas price less the base fee, or 0 for a gas price below the
    /// base fee, which only a call simulated without fees can have.
    function _priorityFee() private view returns (uint256) {
        // Can't wrap: the gas price is above the base fee.
        unchecked {
            return tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
        }
    }

    /// @dev Whether the venue has a cap (`invertedCap`, as stored) and the transaction's priority fee is above it. A
    /// venue without one reads no fee. `fill` and `quote` read the cap with `halted`, from the one slot, and pass it
    /// on, so the check reads no storage of its own.
    function _priorityFeeTooHigh(uint64 invertedCap) private view returns (bool) {
        return invertedCap != 0 && _priorityFee() > ~invertedCap;
    }

    /// @dev Stores `cap` bit-inverted and emits the change, for `setMaxTakerPriorityFee` and
    /// `enableTakerPriorityFeeCap`.
    function _setMaxTakerPriorityFee(uint64 cap) private {
        uint64 previous = ~_invertedFeeCap;
        _invertedFeeCap = ~cap;
        emit MaxTakerPriorityFeeSet(previous, cap, msg.sender);
    }

    /// @dev `fill`'s and `quote`'s revert for `TakerAccess.PriorityFeeTooHigh`.
    function _refusePriorityFee() private view {
        revert TakerPriorityFeeTooHigh(_priorityFee(), ~_invertedFeeCap);
    }

    /// @dev Pays the fill, running the pair's hooks around the payment. A pair without hooks costs one flag check.
    function _settle(IVenueHook.FillContext memory context, uint8 flags) private {
        if (flags == 0) {
            _pay(context, _balance(context.tokenOut));
            return;
        }
        address hook = _hooks[context.pairIndex];

        uint256 outBalance;
        if (flags & VenueHookFlags.BEFORE_FILL != 0) {
            uint256 inBefore = _balance(context.tokenIn);
            uint256 outBefore = _balance(context.tokenOut);
            if (IVenueHook(hook).beforeFill(context) != IVenueHook.beforeFill.selector) {
                revert HookCallbackFailed(hook, IVenueHook.beforeFill.selector);
            }
            _requireKept(context.tokenIn, inBefore, _balance(context.tokenIn));
            outBalance = _balance(context.tokenOut);
            _requireKept(context.tokenOut, outBefore, outBalance);
        } else {
            outBalance = _balance(context.tokenOut);
        }
        _pay(context, outBalance);

        // `_pay` proved the venue's `tokenOut` fell by exactly `amountOut`.
        if (flags & VenueHookFlags.AFTER_FILL != 0) _afterFill(context, hook, flags, outBalance - context.amountOut);
    }

    /// @dev Pays the taker and checks the exact deltas of the venue and the taker, so a fee or a TIP-1028
    /// receive-policy park reverts the fill.
    function _pay(IVenueHook.FillContext memory context, uint256 outBalance) private {
        if (outBalance < context.amountOut) {
            revert InsufficientInventory(context.tokenOut, outBalance, context.amountOut);
        }
        uint256 takerBefore = ITIP20(context.tokenOut).balanceOf(context.taker);
        ITIP20(context.tokenOut).transferWithMemo(context.taker, context.amountOut, context.ref);
        _requireDebit(context.tokenOut, outBalance, context.amountOut);
        _requireCredit(context.tokenOut, context.taker, takerBefore, context.amountOut);
    }

    /// @dev Calls `afterFill`, with the `hookTake` window open for TAKE_INPUT, then checks the venue kept its
    /// `tokenIn` balance less what was taken and all of its `tokenOut` balance.
    function _afterFill(IVenueHook.FillContext memory context, address hook, uint8 flags, uint256 outBefore) private {
        uint256 inBefore = _balance(context.tokenIn);
        bool takeInput = flags & VenueHookFlags.TAKE_INPUT != 0;
        if (takeInput) {
            _takeHook = hook;
            _takeToken = context.tokenIn;
            _takeRemaining = context.amountIn;
            _takeRef = context.ref;
        }
        if (IVenueHook(hook).afterFill(context) != IVenueHook.afterFill.selector) {
            revert HookCallbackFailed(hook, IVenueHook.afterFill.selector);
        }
        uint256 taken;
        if (takeInput) {
            taken = context.amountIn - _takeRemaining;
            _takeHook = address(0);
            _takeToken = address(0);
            _takeRemaining = 0;
            _takeRef = bytes32(0);
        }
        _requireKept(context.tokenIn, inBefore > taken ? inBefore - taken : 0, _balance(context.tokenIn));
        _requireKept(context.tokenOut, outBefore, _balance(context.tokenOut));
    }

    /// @dev The hook's `availableLiquidity(token)` behind a gas-capped staticcall. 0 without BEFORE_FILL, on failure
    /// and on return data shorter than one word. Only 32 bytes are ever copied, so a huge return can't cost memory.
    function _hookLiquidity(uint16 pairIndex, uint8 flags, address token) private view returns (uint256 liquidity) {
        if (flags & VenueHookFlags.BEFORE_FILL == 0) return 0;
        address hook = _hooks[pairIndex];
        bytes memory data = abi.encodeCall(IVenueHook.availableLiquidity, (token));
        assembly ("memory-safe") {
            if staticcall(HOOK_VIEW_GAS, hook, add(data, 0x20), mload(data), 0x00, 0x20) {
                if gt(returndatasize(), 0x1f) { liquidity := mload(0x00) }
            }
        }
    }

    /// @dev Clears the consumed depth of the sides `refill` names (`HotWord.FLAGS_REFILL` bits), keeping the slot
    /// nonzero, and emits `Refilled`. Both sides at once is one write that reads nothing.
    function _refill(uint16 pairIndex, uint16 refill) private {
        bool bids = refill & HotWord.FLAG_REFILL_BIDS != 0;
        bool asks = refill & HotWord.FLAG_REFILL_ASKS != 0;
        if (bids && asks) {
            _freshConsumption(pairIndex);
        } else {
            Consumption storage consumption = _consumption[pairIndex];
            if (bids) consumption.bids = 0;
            else consumption.asks = 0;
        }
        // `post` makes no external call: the lint reads `_freshConsumption`'s assembly store as one.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Refilled(pairIndex, bids, asks);
    }

    /// @dev Writes the pair's whole consumption slot in one store, as `FRESH_CONSUMPTION`: a struct assignment would
    /// read and rewrite the slot once per field.
    function _freshConsumption(uint16 pairIndex) private {
        Consumption storage consumption = _consumption[pairIndex];
        assembly ("memory-safe") {
            sstore(consumption.slot, FRESH_CONSUMPTION)
        }
    }

    /// @dev Reverts when the pair has a band and `mid` is outside it.
    function _checkMidBand(uint16 pairIndex, uint96 mid) private view {
        MidBand storage band = _midBands[pairIndex];
        uint96 maxMid = band.maxMid;
        if (maxMid != 0 && (mid < band.minMid || mid > maxMid)) revert MidOutOfBand(pairIndex, mid);
    }

    /// @dev The fill's access check on its taker, the one `fill`, `takerAllowed` and `takerAccess` all run, so they
    /// can't disagree. In this order: `None` (an unknown or removed pair) refuses with no further read; then the
    /// transaction's priority fee against the venue's cap (`invertedCap`, as stored, which the caller read from the
    /// settler's slot: `fill` with `halted`), whoever the taker; then `Closed` refuses; then the deny list, read only
    /// while `deniedCount` is nonzero; then `Open` admits whatever `sponsorId`, reading no list; and `Listed` reads the
    /// list the fill names: the home list (0) with one read, and any other id its sponsor slot, which must be
    /// registered and enabled, the pair's admission, then the member, which must carry the sponsor's current
    /// generation. Returns `Allowed` or the first refusal, never `None`; `fill` reverts every value but `Allowed` with
    /// `_refuse`.
    function _takerAccess(uint16 pairIndex, AccessMode mode, address taker, uint64 sponsorId, uint64 invertedCap)
        private
        view
        returns (TakerAccess)
    {
        if (mode == AccessMode.None) return TakerAccess.UnknownPair;
        if (_priorityFeeTooHigh(invertedCap)) return TakerAccess.PriorityFeeTooHigh;
        if (mode == AccessMode.Closed) return TakerAccess.Closed;
        if (_deniedCount != 0 && denied[taker]) return TakerAccess.Denied;
        if (mode == AccessMode.Open) return TakerAccess.Allowed;
        uint32 generation = HOME_GENERATION;
        if (sponsorId != HOME) {
            Sponsor memory record = _sponsors[sponsorId];
            if (record.admin == address(0)) return TakerAccess.UnknownSponsor;
            if (!record.enabled) return TakerAccess.SponsorDisabled;
            if (_admitted[pairIndex][sponsorId] != ADMITTED) return TakerAccess.SponsorNotAdmitted;
            generation = record.generation;
        }
        // A registered sponsor's generation, like the home list's, is never 0, so an unlisted account never matches.
        return _members[pairIndex][sponsorId][taker] == generation ? TakerAccess.Allowed : TakerAccess.NotListed;
    }

    /// @dev Reverts with `fill`'s error for an access refusal (`IVenue.TakerAccess` lists them). `fill` never passes
    /// `UnknownPair`: its pricing has already reverted `UnknownPair` for a pair that isn't live.
    function _refuse(TakerAccess outcome, uint16 pairIndex, address taker, uint64 sponsorId) private view {
        // Defensive: unreachable from `fill` (see above), kept so the mapping covers every `TakerAccess` value.
        if (outcome == TakerAccess.UnknownPair) revert UnknownPair(pairIndex);
        if (outcome == TakerAccess.PriorityFeeTooHigh) _refusePriorityFee();
        if (outcome == TakerAccess.Denied) revert TakerDenied(taker);
        if (outcome == TakerAccess.UnknownSponsor) revert UnknownSponsor(sponsorId);
        if (outcome == TakerAccess.SponsorDisabled) revert SponsorDisabled(sponsorId);
        if (outcome == TakerAccess.SponsorNotAdmitted) revert SponsorNotAdmitted(pairIndex, sponsorId);
        // `Closed` and `NotListed`, and `None`, which `_takerAccess` never returns.
        revert TakerNotAllowed(taker);
    }

    /// @dev A registered sponsor's slot; reverts `UnknownSponsor` for any other id, the home list's 0 included.
    function _registered(uint64 sponsorId) private view returns (Sponsor storage record) {
        record = _sponsors[sponsorId];
        if (record.admin == address(0)) revert UnknownSponsor(sponsorId);
    }

    /// @dev For the switches that narrow access one way and widen it the other: the owner may do either, an updater
    /// only the narrowing one (`widen == false`).
    function _narrowingAuthority(bool widen) private view {
        if (msg.sender == owner) return;
        if (!isUpdater[msg.sender]) revert NotOwnerOrUpdater();
        if (widen) revert NotOwner();
    }

    /// @dev A sponsor admin: not `address(0)`, which marks an unregistered id, nor an account that can never call: the
    /// venue, or a TIP-1022 virtual address.
    function _requireAccount(address account) private view {
        if (account == address(0) || account == address(this) || _isVirtual(account)) revert InvalidAddress();
    }

    /// @dev Whether `account` has the TIP-1022 virtual-address layout, which never sends a call. The layout alone
    /// identifies one: the venue asks no address registry.
    function _isVirtual(address account) private pure returns (bool) {
        return ((uint160(account) >> 48) & type(uint80).max) == VIRTUAL_MAGIC;
    }

    function _existingPair(uint16 pairIndex) private view returns (PairConfig storage config) {
        config = _pairs[pairIndex];
        if (config.base == address(0)) revert UnknownPair(pairIndex);
    }

    /// @dev Transfers out and requires the venue's balance to fall by exactly `amount`.
    function _send(address token, address to, uint256 amount, bytes32 memo) private {
        uint256 before = _balance(token);
        ITIP20(token).transferWithMemo(to, amount, memo);
        _requireDebit(token, before, amount);
    }

    function _requireDebit(address token, uint256 before, uint256 amount) private view {
        uint256 afterTransfer = _balance(token);
        uint256 actual = before > afterTransfer ? before - afterTransfer : 0;
        if (actual != amount) revert BalanceDeltaMismatch(token, address(this), amount, actual);
    }

    /// @dev Requires `account`'s balance to have risen by exactly `amount` since `before`.
    function _requireCredit(address token, address account, uint256 before, uint256 amount) private view {
        uint256 afterTransfer = ITIP20(token).balanceOf(account);
        uint256 received = afterTransfer > before ? afterTransfer - before : 0;
        if (received != amount) revert BalanceDeltaMismatch(token, account, amount, received);
    }

    function _requireKept(address token, uint256 floor, uint256 actual) private pure {
        if (actual < floor) revert HookReducedBalance(token, floor, actual);
    }

    function _balance(address token) private view returns (uint256) {
        return ITIP20(token).balanceOf(address(this));
    }

    function _shapeKey(uint16 pairIndex, uint8 shapeId) private pure returns (uint256) {
        return (uint256(pairIndex) << 10) | (uint256(shapeId) << 2);
    }

    function _onlyOwner() private view {
        if (msg.sender != owner) revert NotOwner();
    }

    /// @dev `onlyOwnerOrUpdater` for `post`, which also returns whether the caller's entries are band-checked: only an
    /// updater's, and only while some pair has a band. The counter shares the owner's slot, so this reads it once.
    function _postAuthority() private view returns (bool checkBands) {
        address owner_ = owner;
        uint16 banded = _bandedPairs;
        if (msg.sender == owner_) return false;
        if (!isUpdater[msg.sender]) revert NotOwnerOrUpdater();
        return banded != 0;
    }

    function _onlyOwnerOrUpdater() private view {
        if (msg.sender != owner && !isUpdater[msg.sender]) revert NotOwnerOrUpdater();
    }
}

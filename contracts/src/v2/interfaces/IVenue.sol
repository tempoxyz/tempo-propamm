// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice One maker's venue: that maker's inventory, curves and pair hooks for all of their pairs. Deployed as a
/// minimal clone by `VenueFactory`. Custody never leaves the owner key's control.
/// @dev Roles:
/// - owner: everything, including custody (`withdraw`), hooks, settler, access (the home list, which sponsors the venue
///   registers, enables and admits on each pair, denials and each pair's mode) and mid bands. The owner never edits a
///   sponsor's member lists.
/// - updater (hot key): the quoting calls `post`, `setShape`, `setMaxTakerPriorityFee` (any cap, as the owner can)
///   and `enableTakerPriorityFeeCap` (the default cap), and the narrowing-only switches `closePair`,
///   `setHalted(true)`, a denial (`setDenied(accounts, true)`), switching a sponsor off (`setSponsorEnabled(id,
///   false)`) and removing a sponsor from a pair (`setPairSponsor(pair, id, false)`). The updater can't withdraw, but
///   it prices all of the venue's inventory, including what a pair's hook can pull from its vault. A pair's mid band
///   (`setMidBand`) is the owner's bound on that.
/// - sponsor admin: the member lists of its own sponsor id (`setMembers`), and handing them to a new key in two steps
///   (`transferSponsorAdmin`, `acceptSponsorAdmin`).
/// - settler: `fill`.
/// - the pair's hook: `hookTake`, only inside that pair's `afterFill` with TAKE_INPUT.
///
/// Access (see `AccessMode`): per pair, per sponsor, per user, `[pairIndex][sponsorId][account] -> listed`, held in the
/// venue's own storage. A sponsor (a business that brings its own users: a fintech, broker or wallet app) is registered
/// by the owner under a sponsor id the owner chooses (`addSponsor`), so the same business can carry the same id on
/// every venue. The owner admits it pair by pair (`setPairSponsor`) and can switch it off venue-wide
/// (`setSponsorEnabled`); its admin alone lists its users, pair by pair (`setMembers`). Sponsor id 0 is the venue's own
/// home list, which only the current owner edits and which every pair admits. A venue-wide deny list sits above every
/// list. A taker only swaps for itself: `fill` pays the taker, and each fill names the sponsor it trades under
/// (`sponsorId`), so every `Fill` carries the sponsor the order came through.
///
/// Fills take depth off the ladder like orders off a book. Each pair stores, per side, the base its fills have taken
/// since the maker last refilled that side (`consumed`): the bids lose what takers sell, the asks what they buy. Each
/// fill walks the posted ladder from that offset, so a later fill starts deeper and pays a worse level, and adds what
/// it took. An opposite trade takes from the other side and gives none back. Only the maker gives depth back: a `post`
/// entry with `HotWord.FLAG_REFILL_BIDS` or `FLAG_REFILL_ASKS` clears that side's consumption. A post without them
/// changes the price, spreads or shape and keeps the consumption, which then comes off the top of the new ladder.
/// Splitting an order into several swaps therefore never beats one swap of the total. Inventory and hook liquidity
/// still bound the output the venue can pay.
///
/// Stale quotes: the owner or an updater can cap the priority fee per gas a taker's transaction may pay
/// (`setMaxTakerPriorityFee`, or `enableTakerPriorityFeeCap` for `DEFAULT_TAKER_PRIORITY_FEE_CAP`, 10 gwei: about
/// 0.1 cent of priority fee on a 100,000-gas swap). A new venue has no cap. A take that outbids a `post` sent above
/// the cap, to fill at the old quote, reverts `TakerPriorityFeeTooHigh`, so a builder that orders by priority fee puts
/// the post ahead of every take pending with it. It orders nothing else: a take that reaches a streaming builder, such
/// as Tempo's, before the post still fills first at the old quote. The cap is part of the fill's access check
/// (`TakerAccess.PriorityFeeTooHigh`).
///
/// Zero and one (AGENTS.md, "Zero and one conventions"): storage starts zeroed, a missing record reads as zeros, and a
/// failed or ignored call can decode as zero, so zero never grants anything.
/// - Enums and result codes: 0 is `None`, never stored for a live record and never returned as an answer. Real values
///   start at 1: `AccessMode.Closed`, `TakerAccess.Allowed`.
/// - Ids: 0 is the venue's own default, the home list (`sponsorId` 0). Registered sponsor ids are nonzero.
/// - Markers, version counters and stored sentinels are nonzero once written (`seq`, `generation`, the consumption
///   slot), so a write never creates a slot.
/// - Bit flags: 0 is no flags, each flag a power of two (`HotWord` flags, hook flags). Reason codes: 0 is no error
///   (`InvalidShape` reasons start at 1).
/// - Indexes use 0 as a real value, the first entry: `pairIndex` and `shapeId` from 0. They never grant access.
/// - Restrictions read 0 when absent, which grants nothing on its own: no denial, not halted, no mid band, and no
///   priority-fee cap. The cap is stored bit-inverted, so the zero a new venue starts with reads as
///   `NO_PRIORITY_FEE_CAP`.
interface IVenue {
    /// @notice Who may trade a pair. `Listed`: takers that the sponsor the fill names has listed on the pair, the home
    /// list (`sponsorId` 0) or a registered sponsor that is enabled and admitted on the pair. `Open`: everyone,
    /// whatever `sponsorId`; only the owner enters it, and only while the venue is halted. `Closed`: nobody; the owner
    /// or an updater enters it at any time (`closePair`), and only the owner leaves it. In `Listed` and `Open` the deny
    /// list rejects its accounts first.
    /// @dev `None` is never stored for a live pair: `addPair` stores `Closed`, and only a removed or unknown pair reads
    /// `None`.
    enum AccessMode {
        None,
        Closed,
        Listed,
        Open
    }

    /// @notice What the pair's access check says about a taker under a sponsor id (`takerAccess`): `Allowed`, or the
    /// refusal `fill` reaches first, in the order it checks them. With the error `fill` reverts for each:
    /// - `None` (0): never returned. It is what a zeroed slot or a failed call's zero return decodes to, so it is not
    ///   `Allowed`; treat it as a refusal.
    /// - `UnknownPair`: no live pair at the index, unknown or removed (`AccessMode.None`). `fill` reverts `UnknownPair`
    ///   while pricing, before its access check.
    /// - `PriorityFeeTooHigh`: the transaction's priority fee per gas, `tx.gasprice - block.basefee` (0 when the gas
    ///   price is below the base fee), is above `maxTakerPriorityFee` (`TakerPriorityFeeTooHigh`), whoever the taker.
    /// - `Closed`: the pair is `Closed` (`TakerNotAllowed`).
    /// - `Denied`: the taker is on the deny list (`TakerDenied`), on `Listed` and `Open` pairs alike.
    /// - `UnknownSponsor`: on a `Listed` pair, `sponsorId` is neither 0 nor a registered sponsor (`UnknownSponsor`).
    /// - `SponsorDisabled`: the sponsor is switched off (`SponsorDisabled`).
    /// - `SponsorNotAdmitted`: the sponsor isn't admitted on the pair (`SponsorNotAdmitted`).
    /// - `NotListed`: the list the fill names, the home list for 0 or else the sponsor's current list, doesn't hold the
    ///   taker on the pair (`TakerNotAllowed`).
    /// @dev `Open` admits every taker it doesn't deny, whatever `sponsorId`, so the sponsor refusals and `NotListed`
    /// only come from `Listed` pairs. Values: `None` 0, `Allowed` 1, then the refusals 2 to 9 in the order above.
    /// The order is the pair, the transaction, then the taker. `fill` prices the swap first, so a pair that isn't live
    /// is `UnknownPair` whatever the fee. The fee comes before every check on the taker because `quote` checks it too
    /// and has no taker: a `Settler` exact-out swap runs `quote` before `fill`, so an over-cap swap reverts
    /// `TakerPriorityFeeTooHigh` from either, exact in or exact out, before any access refusal.
    /// `PriorityFeeTooHigh` depends on the transaction the view runs in: an `eth_call` reads its own `tx.gasprice`, and
    /// one without fee fields has a gas price of 0, so it sees no priority fee and never returns it. Simulate with
    /// the fees the swap will send.
    enum TakerAccess {
        None,
        Allowed,
        UnknownPair,
        PriorityFeeTooHigh,
        Closed,
        Denied,
        UnknownSponsor,
        SponsorDisabled,
        SponsorNotAdmitted,
        NotListed
    }

    /// @notice A pair's configuration. A removed pair reads as all zero (`access == None`), and its index is never
    /// reused.
    struct Pair {
        address base;
        address quote;
        uint64 sizeUnit;
        AccessMode access;
        address hook;
        uint8 hookFlags;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A pair was added, `Closed`: its mode changes only with `PairAccessUpdated`.
    event PairAdded(uint16 indexed pairIndex, address indexed base, address indexed quote, uint64 sizeUnit);
    event PairRemoved(uint16 indexed pairIndex);
    /// @notice The pair's access mode was set (`setPairAccess` or `closePair`). Emitted on every call, even when the
    /// mode doesn't change. A pair's first mode is `Closed`, which `PairAdded` records.
    event PairAccessUpdated(uint16 indexed pairIndex, AccessMode indexed oldMode, AccessMode indexed newMode);
    /// @notice The owner registered `sponsorId` with `admin` as the key that lists its users. It starts enabled and
    /// admitted on no pair.
    event SponsorAdded(uint64 indexed sponsorId, address indexed admin);
    /// @notice The sponsor was switched on or off for the whole venue. Emitted on every call, even when nothing
    /// changes.
    event SponsorEnabledSet(uint64 indexed sponsorId, bool enabled, address indexed by);
    /// @notice The sponsor was admitted on the pair or removed from it. Emitted on every call, even when nothing
    /// changes.
    event PairSponsorSet(uint16 indexed pairIndex, uint64 indexed sponsorId, bool admitted, address indexed by);
    /// @notice `account` was listed (`allowed`) or delisted on the pair under `sponsorId` (0: the home list). Emitted
    /// for every entry of `setMembers`, no-ops included, so the events alone rebuild every list.
    event MemberUpdated(uint16 indexed pairIndex, uint64 indexed sponsorId, address indexed account, bool allowed);
    event SponsorAdminTransferStarted(uint64 indexed sponsorId, address indexed admin, address indexed pendingAdmin);
    event SponsorAdminTransferred(uint64 indexed sponsorId, address indexed previousAdmin, address indexed newAdmin);
    /// @notice The owner gave `sponsorId` a new admin and an empty list (`generation` counts the lists the id has had):
    /// every listing made before it no longer admits anyone.
    event SponsorReset(
        uint64 indexed sponsorId, address indexed previousAdmin, address indexed newAdmin, uint32 generation
    );
    /// @notice An account's denial changed. No-op entries emit nothing.
    event DenyUpdated(address indexed account, bool denied, address indexed by);
    event PairHookSet(uint16 indexed pairIndex, address indexed hook, uint8 flags);
    /// @notice The pair's mid band was set, or cleared (`minMid = maxMid = 0`).
    event MidBandSet(uint16 indexed pairIndex, uint96 minMid, uint96 maxMid);
    /// @notice An updater's permission changed. A no-op call emits nothing.
    event UpdaterSet(address indexed updater, bool allowed);
    event SettlerSet(address indexed settler);
    /// @notice The venue halt state changed. A no-op call emits nothing.
    event HaltedSet(bool halted);
    /// @notice The taker priority-fee cap was set (`NO_PRIORITY_FEE_CAP`: none). Emitted on every call, even when it
    /// doesn't change. A new venue has no cap, which no event records.
    event MaxTakerPriorityFeeSet(uint64 previousCap, uint64 cap, address indexed by);
    /// @notice The owner started an ownership transfer, or cancelled one when `pendingOwner` is `address(0)`.
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Withdrawn(address indexed token, address indexed to, uint256 amount, bytes32 memo);

    /// @notice Every accepted hot-word update, with the word as stored: the refill bits cleared, and a `Refilled` right
    /// after it when the entry carried one. `Posted`, `HotWordReset` and `ShapeSet` rebuild any curve at any block,
    /// and with `Fill` and `Refilled` its consumed depth.
    event Posted(uint16 indexed pairIndex, bytes32 hotWord);
    /// @notice The owner reset a halted venue's pair to the initial, unfillable hot word (seq 1). Consumption,
    /// configuration and access are unchanged. Discard queued posts and reseed the pair's sequencer before resuming.
    event HotWordReset(uint16 indexed pairIndex, uint32 previousSeq);
    /// @notice An accepted `post` entry refilled the pair's bids, its asks, or both: their consumed depth is 0 again.
    /// Emitted right after that entry's `Posted`, whose word no longer carries the refill bits. A side's consumption is
    /// the base of its `Fill`s (`amountIn` when `baseIn`, else `amountOut`) since its last refill or `PairAdded`.
    event Refilled(uint16 indexed pairIndex, bool bids, bool asks);
    /// @notice A shape was defined, redefined or deleted (all-zero words).
    event ShapeSet(uint16 indexed pairIndex, uint8 shapeId, uint256[4] words);
    /// @notice One executed fill. The output went to `taker`. `sponsorId` is the sponsor the taker traded under (0: the
    /// venue's home list), checked in `Listed` mode; in `Open` mode it is the caller's unchecked claim.
    event Fill(
        uint16 indexed pairIndex,
        address indexed taker,
        bytes32 indexed ref,
        uint64 sponsorId,
        bool baseIn,
        uint128 amountIn,
        uint128 amountOut,
        uint96 makerMid,
        uint32 seq
    );

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    error NotFactory();
    error AlreadyInitialized();
    error NotOwner();
    error NotPendingOwner();
    error NotOwnerOrUpdater();
    error NotSettler();
    error ZeroAddress();
    error VenueHalted();
    error PairLimitReached();
    error UnknownPair(uint16 pairIndex);
    error InvalidPairTokens();
    error DecimalsMismatch(uint8 baseDecimals, uint8 quoteDecimals);
    error InvalidSizeUnit();
    /// @notice No sponsor is registered under this id. Id 0, the home list, is never a registered sponsor.
    error UnknownSponsor(uint64 sponsorId);
    /// @notice `addSponsor` with an id already registered, or 0, which the home list holds.
    error SponsorExists(uint64 sponsorId);
    error SponsorDisabled(uint64 sponsorId);
    error SponsorNotAdmitted(uint16 pairIndex, uint64 sponsorId);
    error NotSponsorAdmin(uint64 sponsorId);
    error NotPendingSponsorAdmin(uint64 sponsorId);
    error InvalidAccessMode();
    error NotHalted();
    error InvalidAddress();
    error BatchTooLarge(uint256 supplied, uint256 maximum);
    error MalformedPost(uint256 length);
    error InvalidHotWord(uint16 pairIndex);
    error InvalidMidBand();
    error MidOutOfBand(uint16 pairIndex, uint96 mid);
    error InvalidShape(uint8 reason);
    error TokenMismatch(address tokenIn, address tokenOut);
    error QuoteExpired(uint40 validUntil);
    error SideDisabled(bool baseIn);
    error ZeroAmount();
    /// @notice The side's ladder left after its consumed depth can't cover the fill, or the side is consumed to its
    /// depth. `LadderMath` raises it; it is declared here, with the same selector, so a caller holding only `IVenue`
    /// can decode it.
    error InsufficientDepth();
    /// @notice The fill rounds to 0 on either side. `LadderMath` raises it; declared here with the same selector.
    error ZeroFill();
    error AmountOverflow();
    error TakerNotAllowed(address taker);
    error TakerDenied(address taker);
    /// @notice The transaction's priority fee per gas, `tx.gasprice - block.basefee`, is above the venue's cap.
    error TakerPriorityFeeTooHigh(uint256 priorityFee, uint64 cap);
    error InsufficientInventory(address token, uint256 available, uint256 required);
    error BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual);
    error InvalidHookFlags(uint8 flags);
    error HookCallbackFailed(address hook, bytes4 selector);
    error HookReducedBalance(address token, uint256 before, uint256 afterCall);
    error HookTakeNotAllowed();
    error HookTakeExceedsBudget(uint256 requested, uint256 remaining);

    // ---------------------------------------------------------------------------------------------------------------
    // Lifecycle (owner unless noted)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called once by the factory in the same transaction that creates the clone: sets the owner and the
    /// settler. Only the factory's deployed code can call it, never its constructor (`NotFactory`), and only once
    /// (`AlreadyInitialized`).
    /// @dev Registers no sponsor and lists no one. Emits nothing; the factory's `VenueCreated` records the creation.
    /// The Settler doesn't rely on this guard: it fills only at the factory's addresses (`IVenueFactory.isVenue`). The
    /// guard keeps the implementation, and any clone of it the factory didn't deploy, from being initialized through
    /// `initialize`.
    function initialize(address owner, address settler) external;

    /// @notice Adds a pair, `Closed`: nobody can trade it until the owner opens it with `setPairAccess`. `sizeUnit`
    /// scales the shape sizes (base-token units per size step). Both tokens must be initialized Tempo TIP-20s accepted
    /// by the canonical TIP-20 factory; the venue pays every output with `transferWithMemo`.
    /// @dev Allocates four storage slots (TIP-1000: about 250k gas per new slot): two config slots, the hot word and
    /// the consumption slot, which starts with nothing consumed and stays nonzero for the pair's life, so no fill or
    /// refill ever creates a slot. The hot word starts with `seq = 1` and `validUntil = 0`, so the pair can't fill
    /// until the first `post`. Emits `PairAdded`, which also records the pair's first mode, `Closed`.
    function addPair(address base, address quote, uint64 sizeUnit) external returns (uint16 pairIndex);

    /// @notice Clears the pair's configuration, hot word, hook, mid band and consumed depth. The index is never reused.
    /// Shapes are left in storage; delete them first with all-zero `setShape` calls to earn their storage credits.
    function removePair(uint16 pairIndex) external;

    /// @notice Owner only: sets who may trade the pair, `Listed` (the members its sponsors and the home list have
    /// listed on it), `Open` (everyone) or `Closed` (nobody). Denied accounts never trade in any mode.
    /// @dev `Open` admits everyone not denied without reading any list, so entering it raises risk and requires the
    /// venue to be halted (`NotHalted`); `Listed` and `Closed` can be set at any time. `None` reverts
    /// `InvalidAccessMode`. Setting the current mode changes nothing but still emits `PairAccessUpdated`, so re-setting
    /// `Open` needs no halt. Every mode keeps the pair's member lists and admissions and the venue's denials.
    /// Reopening a closed pair re-arms its hot word: post a fresh word first.
    function setPairAccess(uint16 pairIndex, AccessMode mode) external;

    /// @notice Owner or updater: switches the pair to `Closed`, so it rejects every taker. Only the owner reopens it,
    /// with `setPairAccess`.
    /// @dev Closing fails closed, so it works at any time, and on a closed pair it changes nothing but still emits
    /// `PairAccessUpdated(pairIndex, Closed, Closed)`. It leaves the hot word in place, so reopening re-arms it: post a
    /// fresh word before reopening, or `removePair` a pair whose word can't be replaced.
    function closePair(uint16 pairIndex) external;

    /// @notice Owner only: registers a sponsor under `sponsorId`, with `admin` as the only key that lists its users.
    /// The owner chooses the id, so a business can carry the same id on every venue that serves it; the venue checks
    /// nothing about that convention, so a router that relies on it checks `sponsor(id)` itself. The sponsor starts
    /// enabled and admitted on no pair. An id is registered for good: there is no removal, only `setSponsorEnabled`
    /// and `resetSponsor`.
    /// @dev Reverts `SponsorExists` for 0 (the home list) or a registered id, and `InvalidAddress` for an `admin` of
    /// `address(0)`, the venue or a TIP-1022 virtual address (bytes 4 to 13 all `0xFD`), which never sends a call.
    /// Emits `SponsorAdded`.
    function addSponsor(uint64 sponsorId, address admin) external;

    /// @notice Switches a registered sponsor on or off for the whole venue. While it is off, no fill under it succeeds
    /// on any pair and it can't list anyone, but it can still delist, and its lists and admissions are kept, so
    /// switching it back on restores them.
    /// @dev The owner switches it either way; an updater can only switch it off (`NotOwner` otherwise), which only
    /// narrows access. Reverts `UnknownSponsor` for an id that isn't registered (0 included). Emits
    /// `SponsorEnabledSet` every time, even when nothing changes.
    function setSponsorEnabled(uint64 sponsorId, bool enabled) external;

    /// @notice Admits a registered sponsor on the pair (`admitted`), so its members there can trade under its id, or
    /// removes it. Removal keeps its list on the pair, so admitting it again restores every member, and keeps the
    /// admission's slot nonzero, so admitting it again is a rewrite rather than a new slot.
    /// @dev The owner admits and removes; an updater can only remove (`NotOwner` otherwise). Admission needs a live
    /// pair (`UnknownPair`); both need a registered sponsor (`UnknownSponsor`, 0 included: every pair admits the home
    /// list). Emits `PairSponsorSet` every time, even when nothing changes.
    function setPairSponsor(uint16 pairIndex, uint64 sponsorId, bool admitted) external;

    /// @notice Lists (`allowed`) or delists `accounts` on the pair under `sponsorId`: its admin's own list, or the home
    /// list (0), which only the owner edits. No one else edits a sponsor's lists: not the owner, an updater or another
    /// sponsor. Listing needs a live pair and, for a sponsor, that it is enabled and admitted on the pair; delisting
    /// needs neither, so a sponsor can always take its users off.
    /// @dev Works halted or not, whatever the pair's mode; each change applies from the next fill. Atomic: a bad
    /// account reverts the whole batch. Reverts `NotOwner` (home list) or `NotSponsorAdmin` for any other caller,
    /// `UnknownPair`, `SponsorDisabled` or `SponsorNotAdmitted` for a listing, `BatchTooLarge` for more than
    /// `MAX_BATCH` accounts, and `InvalidAddress` for `address(0)` or the venue. Writes only real changes and emits
    /// `MemberUpdated` for every entry, no-ops included. Each new member is a fresh storage slot (about 250k gas on
    /// Tempo, once per pair and sponsor).
    function setMembers(uint16 pairIndex, uint64 sponsorId, address[] calldata accounts, bool allowed) external;

    /// @notice The sponsor's admin starts handing its lists to `newAdmin`, which must accept (`acceptSponsorAdmin`).
    /// A new nomination replaces any pending one. The owner can't move a sponsor's lists.
    /// @dev Reverts `InvalidAddress` for zero, the venue or a TIP-1022 virtual address.
    function transferSponsorAdmin(uint64 sponsorId, address newAdmin) external;

    /// @notice The current sponsor admin cancels its pending handover without changing its lists or generation.
    /// @dev Reverts `NotSponsorAdmin` for any other caller, including on an unregistered id or the home list.
    /// Emits `SponsorAdminTransferStarted` with a zero pending admin, even when no handover is pending.
    function cancelSponsorAdminTransfer(uint64 sponsorId) external;

    /// @notice The pending admin takes over the sponsor's lists.
    function acceptSponsorAdmin(uint64 sponsorId) external;

    /// @notice Owner only: gives a registered sponsor a new admin and an empty list on every pair, keeping its id,
    /// whether it is enabled and its admissions. For a sponsor that lost its key: the owner can't take over a list,
    /// only start a new one, since every listing made under the old admin stops admitting anyone, at once and for good.
    /// @dev Reverts `UnknownSponsor` for an unregistered id (0 included) and `InvalidAddress` for a `newAdmin` of
    /// `address(0)`, the venue or a TIP-1022 virtual address. Cancels any pending handover. One slot write, whatever
    /// the lists hold. Emits `SponsorReset`.
    function resetSponsor(uint64 sponsorId, address newAdmin) external;

    /// @notice Denies (`deny`) or lifts the denial of `accounts`. A denied account never fills, whatever the lists say
    /// and on `Open` pairs too.
    /// @dev The owner denies and lifts; an updater can only deny (`NotOwner` when it lifts), the same fail-closed split
    /// as `setHalted`. Works halted or not; each change applies from the next fill. Atomic: a bad account reverts the
    /// whole batch. Reverts `BatchTooLarge` for more than `MAX_BATCH` accounts and `InvalidAddress` for `address(0)` or
    /// the venue. A fill checks the Settler's caller, so deny the account that calls: a TIP-1022 virtual address is
    /// accepted, but it never calls, so denying one blocks nothing; deny its master. Writes only real changes, so
    /// `deniedCount` stays exact, and emits `DenyUpdated` only for changed entries.
    function setDenied(address[] calldata accounts, bool deny) external;

    /// @notice Installs, replaces or removes (`hook = 0`, `flags = 0`) the pair's hook. Owner key only.
    /// @dev Rejects incoherent flags, flags the hook doesn't list in `supportedFlags()`, a hook without code, a
    /// nonzero hook with no flags (`flags = 0`), and a zero hook with nonzero flags.
    function setPairHook(uint16 pairIndex, address hook, uint8 flags) external;

    /// @notice Allows or revokes an updater. Owner only; a no-op succeeds silently.
    /// @dev Emits `UpdaterSet` only when the permission changes.
    function setUpdater(address updater, bool allowed) external;

    /// @notice Repoints the venue at a different settler. Only the owner can, so Tempo can't redirect custody.
    function setSettler(address settler) external;

    /// @notice Owner or updater can halt; only the owner can unhalt. A halted venue rejects `fill` and `quote`, and
    /// only a halted venue can switch a pair to `Open`. A no-op succeeds silently.
    /// @dev Emits `HaltedSet` only when the halt state changes.
    function setHalted(bool halted) external;

    /// @notice Moves inventory out to `to` as given, with exact balance-delta checks on the venue and on `to`, so a
    /// transfer a TIP-1028 receive policy would park in the ReceivePolicyGuard, or the token forwards to another
    /// account, reverts. Allowed while halted.
    function withdraw(address token, address to, uint256 amount, bytes32 memo) external;

    /// @notice Owner only: starts a two-step transfer to `newOwner`, which must call `acceptOwnership`.
    /// A new nomination replaces any pending one.
    /// @dev Reverts `NotOwner` unless the caller is the current owner and `ZeroAddress` for a zero nominee.
    /// A TIP-1022 virtual address can't accept.
    function transferOwnership(address newOwner) external;

    /// @notice Owner only: cancels the pending transfer without changing the current owner.
    /// @dev Reverts `NotOwner` unless the caller is the current owner. Emits `OwnershipTransferStarted` with a
    /// zero pending owner, even when no transfer is pending.
    function cancelOwnershipTransfer() external;

    /// @notice The pending owner accepts custody and administration of the venue.
    /// @dev Reverts `NotPendingOwner` unless the caller is the pending owner.
    function acceptOwnership() external;

    // ---------------------------------------------------------------------------------------------------------------
    // Quoting (owner or updater)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Batched hot-word update: `packed` is repeated `[uint16 pairIndex][bytes32 hotWord]`, 34 bytes each. An
    /// accepted entry with `HotWord.FLAG_REFILL_BIDS` clears the pair's bid consumption, with `FLAG_REFILL_ASKS` its
    /// ask consumption, so that side offers its whole ladder again from the first level, and emits `Refilled` after its
    /// `Posted`. The word is stored and emitted with both bits cleared, so a refill acts once: re-posting the stored
    /// word with a higher `seq` refills nothing. An entry without them keeps both sides' consumption, whatever it
    /// changes. Refill only with a quote that prices the inventory the fills left behind; routine re-quotes leave the
    /// bits off. Raising `depthScale` already lets the updater offer more depth, so refilling gives it no new power.
    /// @dev An entry whose `seq` isn't above the stored `seq` is skipped with no write and no event, whatever its mid
    /// and flags: a stale entry never refills.
    /// A malformed batch (bad length, unknown pair, `mid == 0`, reserved flag bits) reverts as a whole, and so does an
    /// updater's batch with an entry it would accept whose mid is outside the pair's band (`MidOutOfBand`). The owner's
    /// entries aren't band-checked.
    function post(bytes calldata packed) external;

    /// @notice Owner only, while halted: restores HotWord.INITIAL (seq 1, no live quote) without changing the pair's
    /// consumed depth, shapes, bands, hook or access. Recovers exhausted sequences without replacing the pair.
    /// @dev Stop quoting, revoke any compromised updater and discard queued posts before resetting; previously
    /// prepared posts from a still-authorized key can become newer again. Reseed the SDK sequencer from the reset
    /// state, post a fresh quote and only then resume. Refill deliberately with that post's flags when intended.
    function resetHotWord(uint16 pairIndex) external;

    /// @notice Defines, redefines or deletes (all-zero `words`) one of the pair's 256 shapes. Words are, in order:
    /// bid levels 1-5, bid levels 6-10, ask levels 1-5, ask levels 6-10. See `ShapeWord` for the encoding rules.
    /// @dev Unchanged words are not rewritten. On a removed pair only deletion is allowed.
    function setShape(uint16 pairIndex, uint8 shapeId, uint256[4] calldata words) external;

    /// @notice Caps the priority fee per gas, `tx.gasprice - block.basefee` in the gas price's own units, of every
    /// transaction that fills on the venue: `fill` and `quote` revert `TakerPriorityFeeTooHigh` above it, on every
    /// pair. `NO_PRIORITY_FEE_CAP` (a new venue's setting) removes the cap. Send every `post` with a priority fee above
    /// the cap: a builder that orders by priority fee then puts no take pending with the post ahead of it at the quote
    /// it replaces. A take that reaches a streaming builder, such as Tempo's, before the post still fills first.
    /// @dev The owner or an updater sets any cap, raising, lowering or removing it. It is a quoting setting, not an
    /// access one: it pairs with the priority fee the updater's own posts pay, and raising it only lets a take that
    /// outbids a post fill the quote that post replaces, while the updater can already post any quote within the
    /// pair's mid band. Venue-wide, like `halted`: one `post` reprices many pairs at one priority fee.
    /// The check is part of the fill's access check, after pricing and before every check on the taker
    /// (`TakerAccess.PriorityFeeTooHigh`), so `takerAccess` and `takerAllowed` report it. A transaction whose gas
    /// price is below the base fee, possible only in a call simulated without fees, counts as paying no priority fee.
    /// Emits `MaxTakerPriorityFeeSet` every time, even when nothing changes.
    function setMaxTakerPriorityFee(uint64 cap) external;

    /// @notice Sets the taker priority-fee cap to `DEFAULT_TAKER_PRIORITY_FEE_CAP`, 10 gwei per gas: on Tempo a
    /// 100,000-gas swap that tips at the cap pays about 0.1 cent of priority fee. One call for a maker that wants the
    /// cap without choosing a value; it then posts above 10 gwei, about 0.04 cents on a 40,000-gas `post`. Works as
    /// `setMaxTakerPriorityFee(DEFAULT_TAKER_PRIORITY_FEE_CAP)` does: from any current cap, raising, lowering or
    /// keeping it, and `setMaxTakerPriorityFee` can move it again.
    /// @dev The owner or an updater, as `setMaxTakerPriorityFee`. A new venue stays uncapped (`NO_PRIORITY_FEE_CAP`)
    /// until one of the two runs. Emits `MaxTakerPriorityFeeSet(previousCap, DEFAULT_TAKER_PRIORITY_FEE_CAP, by)`
    /// every time, even when nothing changes.
    function enableTakerPriorityFeeCap() external;

    /// @notice Owner only: bounds the mids an updater can `post` for the pair to `[minMid, maxMid]`, or clears the band
    /// with `(0, 0)`. Otherwise requires `0 < minMid <= maxMid`. Asks never sit below mid and bids never above it
    /// (`LadderMath`'s price factors), so with a band the updater can't make the venue sell base below `minMid` or buy
    /// it above `maxMid`, whatever it posts or shapes.
    /// @dev Doesn't re-check the live hot word: after tightening a band, halt the venue or post a mid inside it.
    function setMidBand(uint16 pairIndex, uint96 minMid, uint96 maxMid) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Settler only. The settler has already moved the input into this venue. `tokenIn` and `tokenOut` must be
    /// the pair's two tokens; the side follows from their order. `amount` is the input for `exactIn`, else the output,
    /// which goes to `taker`: there is no recipient. `sponsorId` is the sponsor the taker trades under: 0 for the home
    /// list, or a registered sponsor. All-or-nothing: a fill the ladder or inventory can't fully cover reverts. Prices
    /// from the side's consumed depth (`consumed`) down the posted ladder, and adds the fill's base to it: a side
    /// consumed to its depth fills nothing (`InsufficientDepth`) until the maker refills it. After pricing, rejects a
    /// transaction whose priority fee is above the venue's cap (`TakerPriorityFeeTooHigh`, see
    /// `setMaxTakerPriorityFee`), then checks the taker's access.
    /// @dev Access, after pricing: the priority fee against the cap, read from the slot `fill` read for `halted`
    /// (`TakerPriorityFeeTooHigh`); then `Closed` rejects (`TakerNotAllowed`) with no further read; then the deny
    /// list, read only while `deniedCount` is nonzero (`TakerDenied`); then `Open` admits whatever `sponsorId`, reading
    /// no list; and `Listed` reads only the list the fill names: `sponsorId` 0 the pair's home list, and any other id
    /// must be a registered sponsor (`UnknownSponsor`) that is enabled (`SponsorDisabled`) and admitted on the pair
    /// (`SponsorNotAdmitted`) and has listed the taker there under its current admin's list. A miss reverts
    /// `TakerNotAllowed`. `takerAllowed` and `takerAccess` run this same check.
    function fill(
        uint16 pairIndex,
        address tokenIn,
        address tokenOut,
        uint128 amount,
        bool exactIn,
        address taker,
        uint64 sponsorId,
        bytes32 ref
    ) external returns (uint128 amountIn, uint128 amountOut);

    /// @notice The pair's hook only, during its `afterFill` with TAKE_INPUT: takes up to the fill's input, in
    /// `tokenIn` only, with exact balance-delta checks on the venue and the hook. The window closes before `fill`
    /// returns.
    function hookTake(address token, uint256 amount) external;

    /// @notice What `fill` would return right now, from the side's consumed depth down the posted ladder, so a quote
    /// and the fill after it in the same transaction agree, provided the hook honors `IVenueHook.availableLiquidity`
    /// and no intervening external change invalidates the quote. A quote reserves no inventory or hook liquidity.
    /// It checks everything `fill` checks except the caller and
    /// the checks on the taker (`takerAllowed`, `takerAccess`), and it counts the hook's `availableLiquidity` toward
    /// inventory when the pair's hook has BEFORE_FILL. It does check the priority-fee cap, which `takerAccess` reports
    /// as `PriorityFeeTooHigh`, right after pricing as `fill` does, so an over-cap swap reverts
    /// `TakerPriorityFeeTooHigh` from `quote` and `fill` alike.
    function quote(uint16 pairIndex, address tokenIn, address tokenOut, uint128 amount, bool exactIn)
        external
        view
        returns (uint128 amountIn, uint128 amountOut);

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The most accounts one `setMembers` or `setDenied` call takes. Each new member or denial is a fresh
    /// storage slot (about 250,000 gas under TIP-1000), so a full batch of new accounts measures about 25.6M gas: send
    /// 50 at a time when Forge's 130% gas limit must stay under Tempo's 30M transaction cap.
    function MAX_BATCH() external view returns (uint256);

    /// @notice The `maxTakerPriorityFee` that means no cap: `type(uint64).max`.
    function NO_PRIORITY_FEE_CAP() external view returns (uint64);

    /// @notice The cap `enableTakerPriorityFeeCap` sets: 10 gwei (10_000_000_000) of priority fee per gas. A Tempo fee
    /// in a 6-decimal stablecoin is `gas * gasPrice / 1e12` units, so a 100,000-gas swap that tips this much pays
    /// 1,000 units, 0.001 USD (0.1 cent), of priority fee. Not a new venue's cap, which is `NO_PRIORITY_FEE_CAP`.
    function DEFAULT_TAKER_PRIORITY_FEE_CAP() external view returns (uint64);

    /// @notice The gas cap on the hook's `availableLiquidity` view, which `hookLiquidity` and `quote` call: 1,500,000.
    /// Enough for a lending vault that spans many markets: a MetaMorpho vault's `maxWithdraw` over six or more markets
    /// measured 282k to 1.07M gas.
    function HOOK_VIEW_GAS() external view returns (uint256);

    function factory() external view returns (address);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function settler() external view returns (address);
    function halted() external view returns (bool);
    function isUpdater(address account) external view returns (bool);
    function pairCount() external view returns (uint16);
    function pair(uint16 pairIndex) external view returns (Pair memory);
    function hotWord(uint16 pairIndex) external view returns (bytes32);

    /// @notice Base each side's ladder has given up since the maker last refilled it: `bids` to takers selling base,
    /// `asks` to takers buying it. The next fill on a side walks the posted ladder from this offset, in base units of
    /// the ladder posted now. Both 0 for a new, removed or unknown pair.
    function consumed(uint16 pairIndex) external view returns (uint128 bids, uint128 asks);
    function shape(uint16 pairIndex, uint8 shapeId) external view returns (uint256[4] memory words);

    /// @notice The pair's mid band, or `(0, 0)` when it has none.
    function midBand(uint16 pairIndex) external view returns (uint96 minMid, uint96 maxMid);

    /// @notice A registered sponsor: the key that lists its users, whether the venue has it switched on, and which of
    /// its lists is current (`generation`, raised by `resetSponsor`). All zero for an unregistered id, 0 included.
    function sponsor(uint64 sponsorId) external view returns (address admin, bool enabled, uint32 generation);

    function pendingSponsorAdmin(uint64 sponsorId) external view returns (address);

    /// @notice Whether the live pair admits the sponsor: true for the home list (0), else the owner's
    /// `setPairSponsor` choice. False for an unknown or removed pair without reading its retained admission. Says
    /// nothing about whether the sponsor is enabled.
    function pairSponsor(uint16 pairIndex, uint64 sponsorId) external view returns (bool);

    /// @notice Whether `account` is on the sponsor's current list for the live pair (0: the home list), whatever the
    /// pair's mode, the sponsor's switch, its admission and the deny list say. False for an unknown or removed pair
    /// without reading its retained member list.
    function isMember(uint16 pairIndex, uint64 sponsorId, address account) external view returns (bool);

    /// @notice Whether `account` is denied: a fill for it never happens.
    function denied(address account) external view returns (bool);

    /// @notice How many accounts are denied. A fill reads no `denied` slot while this is zero.
    function deniedCount() external view returns (uint32);

    /// @notice The most priority fee per gas, in the gas price's units, a transaction that fills on the venue may pay
    /// (`setMaxTakerPriorityFee`), or `NO_PRIORITY_FEE_CAP` for none.
    function maxTakerPriorityFee() external view returns (uint64);

    /// @notice Whether the pair's access check admits `taker` now for a fill under `sponsorId`, as `fill` checks it.
    /// False for an unknown or removed pair, a transaction over the priority-fee cap, a `Closed` pair, a denied taker,
    /// an unregistered, disabled or unadmitted sponsor, or a taker its current list doesn't hold. Exactly
    /// `takerAccess(...) == TakerAccess.Allowed`, so it reads the calling transaction's priority fee as `takerAccess`
    /// does: an `eth_call` without fee fields sees none.
    /// @dev Runs the fill's own check without reverting on a miss. Covers only the venue's access and the priority-fee
    /// cap, not `halted`, the hot word, inventory, the tokens' own transfer policies or TIP-1028 receive policies.
    function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (bool);

    /// @notice Why the pair's access check admits or refuses `taker` now for a fill under `sponsorId`: `Allowed`, or
    /// the refusal `fill` would revert with, when several apply the first one it checks (see `TakerAccess` for the
    /// order and each refusal's error). A router can read it in the multicall it reads the venue's other views in, so
    /// a refusal comes with its reason.
    /// @dev Runs the fill's own check, the one `takerAllowed` runs, without reverting; never reverts and never returns
    /// `None`, so a caller that reads `None` (a zero word) read something other than this view. Covers only the
    /// venue's access and the priority-fee cap, as `takerAllowed` does: not `halted`, the token binding, the hot word,
    /// the ladder, inventory, the settler, the tokens' own transfer policies or TIP-1028 receive policies. `fill`
    /// checks `halted` and prices the swap before access, so a swap that fails one of those reverts with that error
    /// whatever this returns. The cap is checked against the calling transaction's own priority fee: an `eth_call`
    /// without fee fields has a gas price of 0 and never reads `PriorityFeeTooHigh`, so a router simulates with the
    /// fees it will send (`maxPriorityFeePerGas`, or a legacy `gasPrice`, which pays all of itself above the base fee
    /// as priority fee).
    function takerAccess(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (TakerAccess);

    /// @notice The hook's `availableLiquidity(token)` behind a gas-capped staticcall, or 0 when the pair's hook lacks
    /// BEFORE_FILL or the call fails or returns malformed data. Never reverts for a known pair.
    /// @dev 0 doesn't prove the hook is empty: a view that needs more than the venue's `HOOK_VIEW_GAS` also reads 0,
    /// and so can one within it when the caller leaves the venue less than `HOOK_VIEW_GAS` plus 1/64, since the hook
    /// then gets only what is left. `quote` then counts nothing from the hook, although `fill` still pulls from it.
    /// Hooks over vaults with expensive views (a MetaMorpho vault's `maxWithdraw` walks its whole withdraw queue) need
    /// a bounded source of their own.
    function hookLiquidity(uint16 pairIndex, address token) external view returns (uint256);
}

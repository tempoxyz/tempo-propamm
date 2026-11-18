// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPriceOracle } from "../../interfaces/IPriceOracle.sol";

/// @notice The `ManagedDirectPropAMM` ABI: one maker's oracle-priced pool for any number of pairs, with v2 `Venue`'s
/// taker access.
/// @dev Each pair (`pairIndex` from 0, never reused) at zero fees is priced exactly like one `DirectPropAMM`: its own oracle,
/// freshness and deviation limits, directional anchors and rounding-credit routes, with `DirectPropAMM`'s errors, so a
/// v1-vs-Managed differential holds pair by pair. Inventory is held per token and shared by every pair that uses it.
/// Direct swaps and settler fills use and pay the caller as taker, including a router trading as itself.
/// Each swap names the sponsor it trades under (`sponsorId`, 0 for the pair's
/// home list). Access follows v2 `IVenue`'s list model, check order, events and errors, held in the pool's storage and
/// calling nothing: per-pair `Closed`/`Listed`/`Open` modes, a home list per pair that only the owner edits,
/// owner-registered sponsors whose admins list their own users pair by pair, a pool-wide deny list above every list
/// and `Open`. Pool administration is owner-only; sponsor admins retain control of their own lists. There is no
/// updater role or priority-fee cap. `Open` is entered only while the pool is paused (v2: halted);
/// leaving `Closed` runs `DirectPropAMM.unpause`'s oracle and anchor checks for the pair, and a pair's oracle and risk
/// settings change only while it is `Closed`; `withdraw` refuses a TIP-1022 virtual recipient by name (`VirtualRecipient`)
/// where `Venue.withdraw` fails its credit check.
interface IManagedDirectPropAMM {
    /// @dev One swap's inputs, shared by both swap entry points. `limit` is the minimum output (exact input) or the
    /// maximum input (exact output).
    struct SwapParams {
        uint16 pairIndex;
        bool baseToQuote;
        bool exactInput;
        uint256 amount;
        uint256 limit;
        uint64 sponsorId;
        bytes32 customerId;
        bytes32 tradeId;
        uint256 deadline;
        uint256 expectedOraclePrice;
        uint256 oraclePriceToleranceBps;
        uint256 minimumOracleUpdatedAt;
    }

    error AlreadyInitialized();
    error NotSettler();
    event SettlerSet(address indexed settler);

    /// @notice Initialize a clone once, only from the immutable factory's deployed code.
    function initialize(address owner_, address settler_) external;
    /// @notice Immutable factory, or zero for a standalone pool.
    function factory() external view returns (address);
    /// @notice Owner-chosen settlement contract, initially the factory default (zero for standalone pools).
    function settler() external view returns (address);
    /// @notice Owner replaces the trusted settlement contract, as in v2. Zero is refused.
    /// @dev The settler authenticates its caller and verifies prepaid input; a malicious settler can drain inventory.
    function setSettler(address settler_) external;
    /// @notice Settler-only execution over input already paid into the pool. Pays taker, with no separate recipient.
    /// @dev The trusted settler must pass its caller as taker and verify input before calling this function.
    /// Fees, access and credits use taker. Direct swaps still pull from and pay their caller.
    function fill(SwapParams calldata params, address taker) external returns (uint256 result);

    /// @notice Who may trade a pair. `Listed`: takers on the list the swap names, the pair's home list (`sponsorId` 0)
    /// or a registered sponsor's list on the pair, the sponsor enabled and admitted there. `Open`: everyone, whatever
    /// `sponsorId`; only the owner enters it, and only while the pool is paused. `Closed`: nobody; only the owner
    /// enters it at any time (`closePair`) or leaves it, which re-validates the pair's oracle
    /// and anchors. In `Listed` and `Open` the deny list rejects its accounts first.
    /// @dev Same values as `IVenue.AccessMode`. `None` is never stored for a live pair: `addPair` stores `Closed`, and
    /// only a removed or unknown pair reads `None`.
    enum AccessMode {
        None,
        Closed,
        Listed,
        Open
    }

    /// @notice What the pair's access check says about a taker under a sponsor id (`takerAccess`): `Allowed`, or the
    /// first refusal a swap reaches, in the order it checks them. With the error a swap reverts for each:
    /// - `None` (0): never returned; a zero word decodes to it, so treat it as a refusal.
    /// - `UnknownPair`: no live pair at the index, unknown or removed (`UnknownPair`).
    /// - `Closed`: the pair is `Closed` (`TakerNotAllowed`).
    /// - `Denied`: the taker is on the deny list (`TakerDenied`), on `Listed` and `Open` pairs alike.
    /// - `UnknownSponsor`: on a `Listed` pair, `sponsorId` is neither 0 nor a registered sponsor (`UnknownSponsor`).
    /// - `SponsorDisabled`: the sponsor is switched off (`SponsorDisabled`).
    /// - `SponsorNotAdmitted`: the sponsor isn't admitted on the pair (`SponsorNotAdmitted`).
    /// - `NotListed`: the list the swap names doesn't hold the taker on the pair (`TakerNotAllowed`).
    /// @dev `None` is 0, `Allowed` 1, then refusals 2 to 8. Unlike `IVenue.TakerAccess`, there is no priority-fee
    /// refusal, so values from `Closed` onward differ. `Open` admits every taker it doesn't deny, whatever
    /// `sponsorId`; sponsor refusals and `NotListed` only come from `Listed` pairs.
    enum TakerAccess {
        None,
        Allowed,
        UnknownPair,
        Closed,
        Denied,
        UnknownSponsor,
        SponsorDisabled,
        SponsorNotAdmitted,
        NotListed
    }

    /// @notice A pair's configuration, as `pair` returns it. A removed or unknown pair reads all zero (`access ==
    /// None`), and its index is never reused.
    /// @dev `priceScale` is `DirectPropAMM`'s: `10 ** (baseDecimals + oracleDecimals - quoteDecimals)`.
    struct Pair {
        address base;
        address quote;
        IPriceOracle oracle;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint8 oracleDecimals;
        uint256 priceScale;
        uint256 maxOracleAge;
        uint256 maxPriceDeviationBps;
        AccessMode access;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Events: pool, pairs and pricing (`DirectPropAMM`'s names, with `pairIndex` where the subject is a pair)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The pool-wide pause state changed. No-op `pause` and `unpause` calls emit nothing.
    event PausedStateChanged(bool paused);
    event OwnershipTransferStarted(address indexed oldOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    /// @notice A pair was added, `Closed`: its mode changes only with `PairAccessUpdated`. The `OracleUpdated`,
    /// `MaxOracleAgeUpdated` and `MaxPriceDeviationBpsUpdated` events that follow record its configuration.
    event PairAdded(uint16 indexed pairIndex, address indexed base, address indexed quote);
    event PairRemoved(uint16 indexed pairIndex);
    /// @notice The owner selected one optional hook and its enabled stages on this pair.
    event PairHookUpdated(uint16 indexed pairIndex, address indexed hook, uint8 flags);
    /// @notice Nonzero hook-selected input-token fee retained in shared inventory; amountIn includes this fee.
    event HookFeeCharged(uint16 indexed pairIndex, address indexed taker, address indexed token, uint256 amount);
    event OracleUpdated(uint16 indexed pairIndex, address indexed oldOracle, address indexed newOracle, uint8 decimals);
    event MaxOracleAgeUpdated(uint16 indexed pairIndex, uint256 oldMaxAge, uint256 newMaxAge);
    event MaxPriceDeviationBpsUpdated(
        uint16 indexed pairIndex, uint256 oldMaxPriceDeviationBps, uint256 newMaxPriceDeviationBps
    );
    event PriceAnchorUpdated(uint16 indexed pairIndex, bool indexed baseToQuote, uint256 oldAnchor, uint256 newAnchor);
    /// @notice `DirectPropAMM`'s signature. The route key names the pair (`roundingRouteKey`).
    event RoundingCreditUpdated(bytes32 indexed routeKey, uint256 previousCredit, uint256 newCredit);
    event Funded(address indexed token, uint256 amount, bytes32 indexed memo);
    event Withdrawn(address indexed token, address indexed recipient, uint256 amount, bytes32 memo);
    /// @notice A fill on `pairIndex`. Output went to `taker`. `sponsorId` is the list the taker traded
    /// under (0: the pair's home list), checked on a `Listed` pair; on an `Open` pair it is the caller's
    /// unchecked claim.
    event TradeExecuted(
        uint16 indexed pairIndex,
        address indexed taker,
        bytes32 indexed customerId,
        uint64 sponsorId,
        bytes32 tradeId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 oraclePrice,
        uint256 oracleUpdatedAt
    );

    // ---------------------------------------------------------------------------------------------------------------
    // Events: access (byte-identical to `IVenue`'s)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice The pair's access mode was set (`setPairAccess` or `closePair`). Emitted on every call, even when the
    /// mode doesn't change. A pair's first mode is `Closed`, which `PairAdded` records.
    event PairAccessUpdated(uint16 indexed pairIndex, AccessMode indexed oldMode, AccessMode indexed newMode);
    /// @notice The owner registered `sponsorId` with `admin` as the key that lists its users. It starts enabled and
    /// admitted on no pair.
    event SponsorAdded(uint64 indexed sponsorId, address indexed admin);
    /// @notice The sponsor was switched on or off for the whole pool. Emitted on every call, even when nothing changes.
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
    /// @notice Emitted for each `setDenied` entry that changes its denial; no-op entries emit nothing.
    event DenyUpdated(address indexed account, bool denied, address indexed by);

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    // `DirectPropAMM`'s, with its exact signatures: the pricing differential compares revert bytes, so none of them
    // names the pair (the caller named it).
    error AmountIsZero();
    error CustomerIdIsZero();
    error DeadlineExpired(uint256 deadline, uint256 currentTimestamp);
    error ExactBalanceDeltaFailed(address token, uint256 expected, uint256 actual);
    error FutureOracleTimestamp(uint256 updatedAt, uint256 currentTime);
    error InsufficientInventory(address token, uint256 available, uint256 required);
    error InvalidAddress();
    error InvalidMaxOracleAge();
    error InvalidMaxPriceDeviationBps(uint256 supplied, uint256 maximum);
    error InvalidOraclePriceToleranceBps(uint256 supplied, uint256 maximum);
    error InvalidPrice();
    error NotOwner();
    error NotPaused();
    error NotPendingOwner();
    error OraclePriceToleranceExceeded(uint256 expectedPrice, uint256 actualPrice, uint256 toleranceBps);
    error OracleTimestampTooOld(uint256 minimumUpdatedAt, uint256 actualUpdatedAt);
    error OracleDecimalsChanged(uint8 currentDecimals, uint8 proposedDecimals);
    error Paused();
    error PriceAnchorNotInitialized(bool baseToQuote);
    error PriceDeviationExceeded(bool baseToQuote, uint256 price, uint256 anchor, uint256 maxDeviationBps);
    error SameToken();
    error SlippageExceeded(uint256 limit, uint256 actual);
    error StaleOraclePrice(uint256 updatedAt, uint256 maxAge);
    error TokenTransferFailed(address token);
    error UnsupportedDecimals(uint8 baseDecimals, uint8 quoteDecimals, uint8 oracleDecimals);
    error UnsupportedToken(address token);

    // Multi-pair.
    error UnknownPair(uint16 pairIndex);
    error PairLimitReached();
    error InvalidHook();
    error InvalidHookFlags();
    error HookCallFailed();
    error InvalidHookResponse();
    error HookBalanceDecreased();
    error HookFeeTooHigh(uint256 supplied, uint256 maximum);
    /// @notice The call changes a pair's hook, oracle, risk settings or anchor, which needs the pair `Closed`.
    error PairNotClosed(uint16 pairIndex);

    // Access: `IVenue`'s, with its exact signatures.
    error TakerNotAllowed(address taker);
    error TakerDenied(address taker);
    error UnknownSponsor(uint64 sponsorId);
    error SponsorExists(uint64 sponsorId);
    error SponsorDisabled(uint64 sponsorId);
    error SponsorNotAdmitted(uint16 pairIndex, uint64 sponsorId);
    error NotSponsorAdmin(uint64 sponsorId);
    error NotPendingSponsorAdmin(uint64 sponsorId);
    error InvalidAccessMode();
    error BatchTooLarge(uint256 supplied, uint256 maximum);

    // Withdrawals.
    /// @notice `withdraw` pays no TIP-1022 virtual address (bytes 4 to 13 all `0xFD`): a transfer to one credits its
    /// master, which the pool doesn't resolve. As v2 `Venue`, and unlike `DirectPropAMM`, which resolves it.
    error VirtualRecipient(address recipient);

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Swaps an exact input on `pairIndex` within the caller's quoted-price tolerance using a non-older
    /// observation, paying the output to the caller.
    /// @dev `DirectPropAMM.swapExactInput`'s checks, in its order, with the pool's access check (`takerAccess` of the
    /// caller under `sponsorId`) where v1 checks its taker: `Paused`, then the deadline, access, `customerId`, the
    /// amount, the bound oracle, the credit math and the slippage limit. The rounding-credit route is
    /// `roundingRouteKey(pairIndex, msg.sender, customerId)`. The pool's debit and the caller's credit must each equal
    /// the output exactly. amountIn is gross: ceil(amountIn * feeBps / BPS) stays in inventory, and only the
    /// remainder enters oracle pricing and rounding credit. minAmountOut protects the final, fee-inclusive output.
    /// Oracle binding and anchors use the raw oracle price, never a fee-adjusted price.
    /// @param sponsorId The list the caller trades under on a `Listed` pair: 0 for the pair's home list, or a
    /// registered sponsor's. Ignored on an `Open` pair, but carried in `TradeExecuted`.
    function swapExactInput(
        uint16 pairIndex,
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        uint64 sponsorId,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountOut);

    /// @notice Swaps for an exact output on `pairIndex` within the caller's quoted-price tolerance using a non-older
    /// observation, paying the output to the caller.
    /// @dev As `swapExactInput`: the returned input and maxAmountIn include the input-token fee.
    /// Credits reduce the required net input before grossing up for fees; credit-only output pays no new fee.
    function swapExactOutput(
        uint16 pairIndex,
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint64 sponsorId,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountIn);

    // ---------------------------------------------------------------------------------------------------------------
    // Quotes (`DirectPropAMM`'s, per pair)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Quotes gross exact input after the hook-selected input-token fee for the named taker on this pair,
    /// without route credit.
    /// @dev Reverts UnknownPair for a pair that isn't live. Checks no access, pause or inventory.
    /// Reverts InvalidAddress for a zero taker. At zero fees this matches v1's quote exactly. price is the raw
    /// oracle price. Use the execution taker: the direct swap or Settler caller, including a router trading as itself,
    /// never the quote caller merely because it is quoting.
    function quoteExactInput(uint16 pairIndex, address taker, bool baseToQuote, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 price, uint256 updatedAt);

    /// @notice Quotes gross input including fees for exact output, without route credit.
    /// @dev As `quoteExactInput`.
    function quoteExactOutput(uint16 pairIndex, address taker, bool baseToQuote, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint256 price, uint256 updatedAt);

    /// @notice Quotes the exact execution of `taker`'s exact-input swap for `customerId` on the pair, including the
    /// route's accrued rounding credit and the hook-selected input-token fee. Checks no access, pause or inventory.
    function quoteExactInputFor(uint16 pairIndex, address taker, bytes32 customerId, bool baseToQuote, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 price, uint256 updatedAt, uint256 creditAfter);

    /// @notice Quotes the exact execution of `taker`'s exact-output swap for `customerId` on the pair, including the
    /// route's accrued rounding credit and the hook-selected input-token fee. Checks no access, pause or inventory.
    function quoteExactOutputFor(
        uint16 pairIndex,
        address taker,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 price, uint256 updatedAt, uint256 creditAfter);

    /// @notice The rounding-credit route of `taker`'s swaps for `customerId` on the pair:
    /// `keccak256(abi.encode(pairIndex, taker, customerId))`. The direct swap or Settler caller owns the credits;
    /// a router trading as itself may partition its credits by customerId.
    /// Credits are in the pair's own value units, so routes never mix pairs.
    /// @dev Reverts `InvalidAddress` for a zero taker and `CustomerIdIsZero` for a zero customer id.
    function roundingRouteKey(uint16 pairIndex, address taker, bytes32 customerId) external pure returns (bytes32);

    function roundingCredit(bytes32 routeKey) external view returns (uint256);

    /// @notice The pair's anchor for a direction: the price of its last fill, or what opening or `resetPriceAnchor`
    /// set. 0 for a pair never opened, removed or unknown.
    function priceAnchor(uint16 pairIndex, bool baseToQuote) external view returns (uint256);

    // ---------------------------------------------------------------------------------------------------------------
    // Pairs (owner)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Owner only: adds a pair, `Closed`, with zero anchors: nobody can trade it until the owner opens it with
    /// `setPairAccess`, which sets its anchors from a fresh oracle read.
    /// @dev Checks in `DirectPropAMM`'s constructor order: `InvalidAddress` (a zero token or oracle), `SameToken`,
    /// `InvalidMaxOracleAge` (0 or above `uint80`), `InvalidMaxPriceDeviationBps` (above `BPS`), the three `decimals()`
    /// reads, `UnsupportedDecimals`, then `PairLimitReached`. The same tokens may form several pairs, either way round.
    /// Emits `PairAdded`, `OracleUpdated`, `MaxOracleAgeUpdated` and `MaxPriceDeviationBpsUpdated`, so the events alone
    /// rebuild the pair's configuration. Creates three config slots, plus one `tokenPairCount` slot per token no live
    /// pair uses (about 250,000 gas each on Tempo): removing a token's last pair clears its count.
    function addPair(
        address base,
        address quote,
        IPriceOracle oracle,
        uint256 maxOracleAge,
        uint256 maxPriceDeviationBps
    ) external returns (uint16 pairIndex);

    /// @notice Owner only: removes a live pair in any mode, clearing its configuration, anchors and hook. The
    /// index is never
    /// reused. Its tokens stay in inventory, and `withdraw` can always take them out.
    /// @dev Its member lists, admissions and rounding credits stay in storage. The member and admission views report
    /// false for the removed pair without reading those maps; a later pair has another index. Emits `PairRemoved`.
    function removePair(uint16 pairIndex) external;

    /// @notice Maximum hook-selected input-token fee: 1,000 basis points (10%).
    function MAX_HOOK_FEE_BPS() external view returns (uint16);

    /// @notice Owner only, the pair Closed: selects its one optional hook and enabled ManagedPoolHookFlags stages.
    /// @dev A zero hook requires flags zero; nonzero hooks must have code, not be the pool or a virtual address,
    /// and advertise every selected flag through supportedFlags(). Unknown flags are refused. Configuration grants
    /// no access. Hook failures block only their pair; there is no fallback fee or built-in per-taker fee table.
    /// Hook fees stay in shared inventory with no separate claims. Every mutable pool entrypoint shares the swap
    /// lock, including this setter. Hooks cannot withdraw inventory even when they hold an administrative role.
    function setPairHook(uint16 pairIndex, address hook, uint8 flags) external;

    /// @notice The live pair's hook and enabled stages. Unknown or removed pairs revert UnknownPair.
    function pairHook(uint16 pairIndex) external view returns (address hook, uint8 flags);

    /// @notice Owner only, the pair `Closed`: `DirectPropAMM.setOracle` for the pair. The new oracle must have the
    /// same decimals (`OracleDecimalsChanged`).
    function setOracle(uint16 pairIndex, IPriceOracle newOracle) external;

    /// @notice Owner only, the pair `Closed`: `DirectPropAMM.setMaxOracleAge` for the pair.
    function setMaxOracleAge(uint16 pairIndex, uint256 newMaxOracleAge) external;

    /// @notice Owner only, the pair `Closed`: `DirectPropAMM.setMaxPriceDeviationBps` for the pair.
    function setMaxPriceDeviationBps(uint16 pairIndex, uint256 newMaxPriceDeviationBps) external;

    /// @notice Owner only, the pair `Closed`: accepts the current fresh oracle price as the direction's anchor, with
    /// no deviation check, to recover from legitimate drift beyond the deviation limit.
    function resetPriceAnchor(uint16 pairIndex, bool baseToQuote) external;

    /// @notice Owner only, any live pair (`Closed`, `Listed` or `Open`): sets the direction's anchor to the
    /// fresh oracle
    /// price, with no deviation check, if that price is within `priceToleranceBps` of `expectedPrice`
    /// (`OraclePriceToleranceExceeded` otherwise; tolerance above 10,000 is `InvalidOraclePriceToleranceBps`). Recovers
    /// a direction nobody traded whose anchor drifted out of band without closing the pair; the bound holds at
    /// execution because the pair keeps trading in the same block.
    function refreshPriceAnchor(uint16 pairIndex, bool baseToQuote, uint256 expectedPrice, uint256 priceToleranceBps)
        external;

    // ---------------------------------------------------------------------------------------------------------------
    // Access (`IVenue`'s names and semantics)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Owner only: sets who may trade the pair, `Listed` (the members its sponsors and the home list have
    /// listed on it), `Open` (everyone) or `Closed` (nobody). Denied accounts never trade in any mode.
    /// @dev `Open` admits everyone not denied without reading any list, so entering it raises risk and requires the
    /// pool to be paused (`NotPaused`). `None` reverts `InvalidAccessMode`. Leaving `Closed` is the pair's
    /// paused-to-active transition: it runs `DirectPropAMM.unpause`'s checks for the pair, one fresh oracle read
    /// (`InvalidPrice`, `FutureOracleTimestamp`, `StaleOraclePrice`), then for each direction either sets a zero anchor
    /// to that price or requires the price within the deviation limit of the anchor (`PriceDeviationExceeded`).
    /// `Listed` to `Open` and back reads no oracle. Setting the current mode changes nothing but still emits
    /// `PairAccessUpdated`, so re-setting `Open` needs no pause. Every mode keeps the pair's lists and admissions and
    /// the pool's denials.
    function setPairAccess(uint16 pairIndex, AccessMode mode) external;

    /// @notice Owner only: switches the pair to `Closed`, so it rejects every taker and its oracle and risk
    /// settings can change. Only the owner reopens it, with `setPairAccess`.
    /// @dev Closing fails closed, so it works at any time, and on a closed pair it changes nothing but still emits
    /// `PairAccessUpdated(pairIndex, Closed, Closed)`. Reverts `UnknownPair` for a pair that isn't live.
    function closePair(uint16 pairIndex) external;

    /// @notice Owner only: registers a sponsor under `sponsorId`, with `admin` as the only key that lists its users.
    /// The owner chooses the id (reuse a business's v2 sponsor id where it has one). The sponsor starts enabled and
    /// admitted on no pair. An id is registered for good: there is no removal, only `setSponsorEnabled` and
    /// `resetSponsor`.
    /// @dev Reverts `SponsorExists` for 0 (the home list) or a registered id, and `InvalidAddress` for an `admin` of
    /// `address(0)`, the pool or a TIP-1022 virtual address (bytes 4 to 13 all `0xFD`), which never sends a call.
    function addSponsor(uint64 sponsorId, address admin) external;

    /// @notice Switches a registered sponsor on or off for the whole pool. While it is off, no swap under it succeeds
    /// on any pair and it can't list anyone, but it can still delist, and its lists and admissions are kept, so
    /// switching it back on restores them.
    /// @dev Only the owner switches it either way (`NotOwner` otherwise). Reverts `UnknownSponsor` for an id
    /// that isn't registered (0 included). Emits
    /// `SponsorEnabledSet` every time, even when nothing changes.
    function setSponsorEnabled(uint64 sponsorId, bool enabled) external;

    /// @notice Admits a registered sponsor on the pair (`admitted`), so its members there can trade under its id, or
    /// removes it. Removal keeps its list on the pair, so admitting it again restores every member.
    /// @dev Only the owner admits and removes (`NotOwner` otherwise). Admission needs a live pair
    /// (`UnknownPair`); both need a registered sponsor
    /// (`UnknownSponsor`, 0 included: every pair admits the home list). Emits `PairSponsorSet` every time.
    function setPairSponsor(uint16 pairIndex, uint64 sponsorId, bool admitted) external;

    /// @notice Lists (`allowed`) or delists `accounts` on the pair under `sponsorId`: its admin's own list, or the home
    /// list (0), which only the owner edits. No one else edits a sponsor's lists: not the owner or another
    /// sponsor. Listing needs a live pair and, for a sponsor, that it is enabled and admitted on the pair; delisting
    /// needs neither, so a sponsor can always take its users off.
    /// @dev Works paused or not, whatever the pair's mode; each change applies from the next swap. Atomic: a bad
    /// account reverts the whole batch. Reverts `NotOwner` (home list) or `NotSponsorAdmin` for any other caller,
    /// `SponsorDisabled`, `SponsorNotAdmitted` or `UnknownPair` for a listing, `BatchTooLarge` for more than
    /// `MAX_BATCH` accounts, and `InvalidAddress` for `address(0)` or the pool. A swap checks its caller, so list the
    /// account that calls: a TIP-1022 virtual address is accepted but never calls. Writes only real changes and emits
    /// `MemberUpdated` for every entry, no-ops included.
    function setMembers(uint16 pairIndex, uint64 sponsorId, address[] calldata accounts, bool allowed) external;

    /// @notice The sponsor's admin starts handing its lists to nonzero `newAdmin`, which must accept
    /// (`acceptSponsorAdmin`). The owner can't move a sponsor's lists.
    /// @dev Reverts `NotSponsorAdmin` for any other caller and `InvalidAddress` for `address(0)`, the pool or a
    /// TIP-1022 virtual address, none of which could accept.
    function transferSponsorAdmin(uint64 sponsorId, address newAdmin) external;

    /// @notice The sponsor's current admin clears a pending handover, if any.
    /// @dev Idempotent. Reverts `NotSponsorAdmin` for any other caller. Emits `SponsorAdminTransferStarted` with a
    /// zero pending admin.
    function cancelSponsorAdminTransfer(uint64 sponsorId) external;

    /// @notice The pending admin takes over the sponsor's lists (`NotPendingSponsorAdmin` for anyone else).
    function acceptSponsorAdmin(uint64 sponsorId) external;

    /// @notice Owner only: gives a registered sponsor a new admin and an empty list on every pair, keeping its id,
    /// whether it is enabled and its admissions. For a sponsor that lost its key: the owner can't take over a list,
    /// only start a new one, since every listing made under the old admin stops admitting anyone, at once and for good.
    /// @dev Reverts `UnknownSponsor` for an unregistered id (0 included) and `InvalidAddress` for a `newAdmin` of
    /// `address(0)`, the pool or a TIP-1022 virtual address. Cancels any pending handover. Emits `SponsorReset`.
    function resetSponsor(uint64 sponsorId, address newAdmin) external;

    /// @notice Denies (`deny`) or lifts the denial of `accounts`, pool-wide. A denied account never trades on any
    /// pair, whatever the lists say and on `Open` pairs too.
    /// @dev Only the owner denies and lifts (`NotOwner` otherwise). Works paused or not; each change applies
    /// from the next swap. Atomic: a bad account
    /// reverts the whole batch. Reverts `BatchTooLarge` for more than `MAX_BATCH` accounts and `InvalidAddress` for
    /// `address(0)` or the pool. A TIP-1022 virtual address is accepted, but it never calls, so denying one blocks
    /// nothing; deny its master. Writes only real changes, so `deniedCount` stays exact, and emits `DenyUpdated` only
    /// for changed entries.
    function setDenied(address[] calldata accounts, bool deny) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Inventory and roles
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Owner only: adds `amount` of `token` to inventory from the owner, paused or not. `token` must be a
    /// token of some live pair (`UnsupportedToken`).
    /// @dev The pool's credit must equal `amount` exactly.
    function fund(address token, uint256 amount, bytes32 memo) external;

    /// @notice Owner only: sends `amount` of any `token` from inventory to `recipient`, paused or not.
    /// @dev v2 `Venue.withdraw`'s rule, without `DirectPropAMM`'s pause or pair-token requirement: `recipient` must be
    /// an account other than the pool (`InvalidAddress` for zero or the pool) and not a TIP-1022 virtual address
    /// (`VirtualRecipient`: the pool resolves none). The pool's debit and `recipient`'s own credit must each equal
    /// `amount` exactly, so a transfer the token takes a fee from, redirects or parks (a TIP-1028 receive policy)
    /// reverts. To pay a virtual address, such as a Bridge liquidation address, withdraw to an account and send it
    /// from there. A withdrawal changes no swap's price, only its capacity: a swap that needs more than is left reverts
    /// `InsufficientInventory` in full. Inventory is shared, so this reduces every pair that uses `token`.
    function withdraw(address token, address recipient, uint256 amount, bytes32 memo) external;

    /// @notice Owner only: stops every swap on every pair (`Paused`). Idempotent; emits PausedStateChanged
    /// only when the state changes.
    function pause() external;

    /// @notice Owner only: lets swaps run again on every pair that isn't `Closed`. Idempotent; emits
    /// PausedStateChanged only when the state changes.
    /// @dev Checks no oracle: a pool-wide pause changes no pair's settings, which change only while the pair is
    /// `Closed`, and every swap checks its own pair's oracle.
    function unpause() external;

    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    function BPS() external view returns (uint256);

    /// @notice The most accounts one `setMembers` or `setDenied` call takes. Each new member or denial is a fresh
    /// storage slot (about 250,000 gas under TIP-1000), so a full batch of new accounts measures about 25.6M gas: send
    /// 50 at a time from a Forge script, so its 130% gas limit stays under Tempo's 30M transaction cap.
    function MAX_BATCH() external view returns (uint256);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function paused() external view returns (bool);

    /// @notice How many pairs were ever added: the next `pairIndex`. Removed pairs still count.
    function pairCount() external view returns (uint16);

    /// @notice The pair's configuration; all zero for a removed or unknown pair.
    function pair(uint16 pairIndex) external view returns (Pair memory);

    /// @notice How many live pairs use `token`, as base or quote. `fund` takes only a token with a nonzero count.
    function tokenPairCount(address token) external view returns (uint16);

    /// @notice A registered sponsor: the key that lists its users, whether the pool has it switched on, and which of
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

    /// @notice Whether `account` is denied: a swap from it never fills.
    function denied(address account) external view returns (bool);

    /// @notice How many accounts are denied. A swap reads no `denied` slot while this is zero.
    function deniedCount() external view returns (uint32);

    /// @notice Exactly `takerAccess(pairIndex, taker, sponsorId) == TakerAccess.Allowed`.
    function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (bool);

    /// @notice Why the pair's access check admits or refuses `taker` now for a swap under `sponsorId`: `Allowed`, or
    /// the refusal a swap would revert with, the first one it checks when several apply (see `TakerAccess`).
    /// @dev Runs the swap's own check without reverting; never reverts and never returns `None`. Covers only the
    /// pool's list access: not the pool-wide pause, the oracle, inventory, the tokens' own transfer
    /// policies or TIP-1028 receive policies. A swap checks the pause first, so a paused pool reverts `Paused`
    /// whatever this returns.
    function takerAccess(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (TakerAccess);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IManagedPoolHook, ManagedPoolHookFlags } from "./interfaces/IManagedPoolHook.sol";
import { IManagedDirectPropAMM } from "./interfaces/IManagedDirectPropAMM.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { ITIP20 } from "../interfaces/ITIP20.sol";

/// @notice One maker's oracle-priced pool for any number of pairs, priced like `DirectPropAMM` before optional
/// input-token fees, with shared token inventory and v2 `Venue`'s access: home lists and registered sponsors whose
/// admins list their own users, a pool-wide deny list. Direct swaps and settler fills use the caller as taker,
/// including a router trading as itself.
/// @dev Zero-fee pricing, oracle checks and settlement are `DirectPropAMM`'s, with the pair's configuration
/// passed in and its errors' signatures unchanged, so the v1 differential holds pair by pair. `DirectPropAMM` itself is
/// unchanged. Each pair has its own oracle, freshness and deviation limits, directional anchors and rounding-credit
/// routes (keyed by pair, taker and customer). Inventory is the pool's balance of each token, shared by every pair
/// that uses it: there is no per-pair reservation, so one pair's flow, or a bad oracle on one pair, can use up a token
/// another pair needs. Keep tokens that back independent risk in separate pools.
///
/// Access is `Venue`'s check, re-implemented in the pool's storage (v2 is audit-locked, so nothing is shared), with
/// its modes, list check order, events and errors; it calls nothing. Pool administration is owner-only, and
/// sponsor admins retain control of their own lists. There is no updater role or priority-fee cap.
/// `Open` is entered only while the pool is paused (v2: halted); a pair's oracle and risk settings and an unbounded
/// anchor reset change only while it is `Closed` (on a live pair the owner's `refreshPriceAnchor` moves an anchor only
/// to a fresh price within its own expected-price bound), and leaving `Closed` runs `DirectPropAMM.unpause`'s oracle and anchor checks for
/// that pair, so `Closed` is the pair's own pause. The pool-wide `pause` is the emergency stop for every pair and
/// checks nothing on `unpause`.
///
/// Every mutable entrypoint shares the swaps' transient lock, including role and access changes: a hook may
/// itself be an owner or sponsor admin and must not change pool state during callbacks. Hook stages are
/// snapshotted before pricing; fees use a bounded static quote, and before/after callbacks may only add inventory.
/// For fills, the owner-chosen settler must transfer and verify input first. A malicious settler can drain
/// inventory; replacing it is a custody-trust decision.
///
/// The pool supports no TIP-1022 virtual address, as v2 `Venue`: `withdraw` refuses one (`VirtualRecipient`) and
/// requires its recipient's own exact credit. Direct swaps and settler fills pay the taker and use its access, fees
/// and credits. Unlike `DirectPropAMM`,
/// it holds no address registry and resolves nothing.
contract ManagedDirectPropAMM is ReentrancyGuardTransient, IManagedDirectPropAMM {
    /// @inheritdoc IManagedDirectPropAMM
    uint256 public constant BPS = 10_000;
    /// @inheritdoc IManagedDirectPropAMM
    uint16 public constant MAX_HOOK_FEE_BPS = 1_000;
    /// @inheritdoc IManagedDirectPropAMM
    uint256 public constant MAX_BATCH = 100;

    /// @dev The home list's sponsor id and its constant `generation`: an owner's listing stores 1.
    uint64 private constant HOME = 0;
    uint32 private constant HOME_GENERATION = 1;
    /// @dev A pair's admission of a sponsor: 0 if never admitted, `ADMITTED`, or `REMOVED`, which keeps the slot
    /// nonzero so a later admission rewrites it rather than paying for a new slot (about 250,000 gas on Tempo).
    uint8 private constant ADMITTED = 1;
    uint8 private constant REMOVED = 2;
    /// @dev The TIP-1022 virtual-address layout: bytes 4 to 13 of the address all `0xFD`.
    uint80 private constant VIRTUAL_MAGIC = 0xFDFDFDFDFDFDFDFDFDFD;

    /// @dev Three slots, all of which a swap reads. Slot a: `base` (never zero for a live pair, so it marks one), the
    /// access mode (never `None` for a live pair) and decimals; slot b: `quote`;
    /// slot c: v1's packing (oracle, deviation limit, oracle age), so its bounds hold, `uint80` age included.
    /// `scaleExponent` is at
    /// most 77 (`UnsupportedDecimals`), so `10 ** scaleExponent` is v1's `priceScale`.
    struct PairConfig {
        address base;
        AccessMode access;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint8 oracleDecimals;
        uint8 scaleExponent;
        address quote;
        IPriceOracle oracle;
        uint16 maxPriceDeviationBps;
        uint80 maxOracleAge;
    }

    /// @dev One optional owner-selected hook per pair, packed in one slot.
    struct PairHook {
        address hook;
        uint8 flags;
    }

    // Bounded gas and a single-word output buffer prevent hook gas/returndata bombs from exhausting router views.
    uint256 private constant HOOK_VIEW_GAS = 200_000;
    // Up to about 16 fresh context slots at Tempo's 250k/slot, plus token movement and callback logic; even
    // both enabled callbacks are bounded well below the chain's 30M transaction cap.
    uint256 private constant HOOK_CALLBACK_GAS = 5_000_000;

    /// @dev A pair's directional anchors: 0 until the pair first leaves `Closed`.
    struct PriceAnchors {
        uint256 baseToQuote;
        uint256 quoteToBase;
    }

    /// @dev A registered sponsor, one slot. `admin` is never zero once registered, so a zero admin means an
    /// unregistered id. A member's slot stores the `generation` it was listed in and admits only while that is still
    /// the sponsor's: `resetSponsor` raises it, voiding every earlier listing at once.
    struct Sponsor {
        address admin;
        bool enabled;
        uint32 generation;
    }

    // Slot 0 holds pause, deny count, owner and pair count. The nonzero owner keeps the slot populated,
    // so the first addPair rewrites it instead of creating a slot. A swap warms the deny count with its pause read.
    /// @inheritdoc IManagedDirectPropAMM
    bool public paused;
    /// @dev Each denial is its own fresh slot, so 2^24 of them are out of reach; increments are checked.
    uint24 private _deniedCount;
    /// @inheritdoc IManagedDirectPropAMM
    address public owner;
    /// @inheritdoc IManagedDirectPropAMM
    uint16 public pairCount;
    // Slot 1.
    /// @inheritdoc IManagedDirectPropAMM
    address public pendingOwner;

    mapping(uint16 pairIndex => PairConfig) private _pairs;
    mapping(uint16 pairIndex => PriceAnchors) private _anchors;
    /// @inheritdoc IManagedDirectPropAMM
    mapping(bytes32 routeKey => uint256 credit) public roundingCredit;
    /// @inheritdoc IManagedDirectPropAMM
    mapping(address token => uint16 pairs) public tokenPairCount;
    /// @inheritdoc IManagedDirectPropAMM
    mapping(address account => bool isDenied) public denied;
    mapping(uint64 sponsorId => Sponsor) private _sponsors;
    /// @inheritdoc IManagedDirectPropAMM
    mapping(uint64 sponsorId => address pendingAdmin) public pendingSponsorAdmin;
    /// @dev The owner's per-pair admissions of registered sponsors (`ADMITTED` or `REMOVED`; 0 if never admitted). The
    /// home list is never stored: every live pair admits it.
    mapping(uint16 pairIndex => mapping(uint64 sponsorId => uint8 admission)) private _admitted;
    /// @dev `[pairIndex][sponsorId][account]`: the sponsor's `generation` the account was listed in, or 0 for none.
    mapping(uint16 pairIndex => mapping(uint64 sponsorId => mapping(address account => uint32 generation))) private
        _members;

    mapping(uint16 pairIndex => PairHook) private _pairHooks;

    /// @inheritdoc IManagedDirectPropAMM
    address public immutable factory;
    address private immutable IMPLEMENTATION_SELF;
    /// @inheritdoc IManagedDirectPropAMM
    address public settler;

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    /// @notice Deploys the pool paused, with no pairs, no sponsors, nothing denied.
    constructor(address owner_, address factory_) {
        factory = factory_;
        IMPLEMENTATION_SELF = address(this);
        if (factory_ == address(0)) _initialize(owner_);
        else if (owner_ != address(0)) revert InvalidAddress();
    }

    function _initialize(address owner_) private {
        _requireAccount(owner_);
        owner = owner_;
        paused = true;
        emit OwnershipTransferred(address(0), owner_);
        emit PausedStateChanged(true);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function initialize(address owner_, address settler_) external nonReentrant {
        if (owner != address(0) || address(this) == IMPLEMENTATION_SELF) revert AlreadyInitialized();
        if (msg.sender != factory || factory.code.length == 0 || settler_ == address(0)) revert InvalidAddress();
        _initialize(owner_);
        settler = settler_;
        emit SettlerSet(settler_);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function setSettler(address settler_) external nonReentrant onlyOwner {
        if (settler_ == address(0)) revert InvalidAddress();
        settler = settler_;
        emit SettlerSet(settler_);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function fill(SwapParams calldata params, address taker)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 result)
    {
        if (msg.sender != settler || settler == address(0)) revert NotSettler();
        _requireAccount(taker);
        return _swap(params, taker, true);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IManagedDirectPropAMM
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
    ) external whenNotPaused nonReentrant returns (uint256 amountOut) {
        return _swap(
            SwapParams({
                pairIndex: pairIndex,
                baseToQuote: baseToQuote,
                exactInput: true,
                amount: amountIn,
                limit: minAmountOut,
                sponsorId: sponsorId,
                customerId: customerId,
                tradeId: tradeId,
                deadline: deadline,
                expectedOraclePrice: expectedOraclePrice,
                oraclePriceToleranceBps: oraclePriceToleranceBps,
                minimumOracleUpdatedAt: minimumOracleUpdatedAt
            }),
            msg.sender,
            false
        );
    }

    /// @inheritdoc IManagedDirectPropAMM
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
    ) external whenNotPaused nonReentrant returns (uint256 amountIn) {
        return _swap(
            SwapParams({
                pairIndex: pairIndex,
                baseToQuote: baseToQuote,
                exactInput: false,
                amount: amountOut,
                limit: maxAmountIn,
                sponsorId: sponsorId,
                customerId: customerId,
                tradeId: tradeId,
                deadline: deadline,
                expectedOraclePrice: expectedOraclePrice,
                oraclePriceToleranceBps: oraclePriceToleranceBps,
                minimumOracleUpdatedAt: minimumOracleUpdatedAt
            }),
            msg.sender,
            false
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Quotes
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IManagedDirectPropAMM
    function quoteExactInput(uint16 pairIndex, address taker, bool baseToQuote, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 price, uint256 updatedAt)
    {
        PairConfig storage config = _existingPair(pairIndex);
        if (taker == address(0)) revert InvalidAddress();
        if (amountIn == 0) revert AmountIsZero();
        (price, updatedAt) = _readGuardedOracle(pairIndex, config, baseToQuote);
        uint256 scale = _scale(config);
        amountIn -= _inputFee(amountIn, _feeBps(pairIndex, taker, baseToQuote, true, amountIn));
        amountOut = baseToQuote ? Math.mulDiv(amountIn, price, scale) : Math.mulDiv(amountIn, scale, price);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function quoteExactOutput(uint16 pairIndex, address taker, bool baseToQuote, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint256 price, uint256 updatedAt)
    {
        PairConfig storage config = _existingPair(pairIndex);
        if (taker == address(0)) revert InvalidAddress();
        if (amountOut == 0) revert AmountIsZero();
        (price, updatedAt) = _readGuardedOracle(pairIndex, config, baseToQuote);
        uint256 scale = _scale(config);
        amountIn = baseToQuote
            ? Math.mulDiv(amountOut, scale, price, Math.Rounding.Ceil)
            : Math.mulDiv(amountOut, price, scale, Math.Rounding.Ceil);
        amountIn = _grossInput(amountIn, _feeBps(pairIndex, taker, baseToQuote, false, amountOut));
    }

    /// @inheritdoc IManagedDirectPropAMM
    function quoteExactInputFor(uint16 pairIndex, address taker, bytes32 customerId, bool baseToQuote, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 price, uint256 updatedAt, uint256 creditAfter)
    {
        PairConfig storage config = _existingPair(pairIndex);
        if (amountIn == 0) revert AmountIsZero();
        bytes32 routeKey = roundingRouteKey(pairIndex, taker, customerId);
        (price, updatedAt) = _readGuardedOracle(pairIndex, config, baseToQuote);
        amountIn -= _inputFee(amountIn, _feeBps(pairIndex, taker, baseToQuote, true, amountIn));
        (amountOut, creditAfter) =
            _quoteExactInputWithCredit(baseToQuote, amountIn, price, roundingCredit[routeKey], _scale(config));
    }

    /// @inheritdoc IManagedDirectPropAMM
    function quoteExactOutputFor(
        uint16 pairIndex,
        address taker,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 price, uint256 updatedAt, uint256 creditAfter) {
        PairConfig storage config = _existingPair(pairIndex);
        if (amountOut == 0) revert AmountIsZero();
        bytes32 routeKey = roundingRouteKey(pairIndex, taker, customerId);
        (price, updatedAt) = _readGuardedOracle(pairIndex, config, baseToQuote);
        (amountIn, creditAfter) =
            _quoteExactOutputWithCredit(baseToQuote, amountOut, price, roundingCredit[routeKey], _scale(config));
        amountIn = _grossInput(amountIn, _feeBps(pairIndex, taker, baseToQuote, false, amountOut));
    }

    /// @inheritdoc IManagedDirectPropAMM
    function roundingRouteKey(uint16 pairIndex, address taker, bytes32 customerId) public pure returns (bytes32) {
        if (taker == address(0)) revert InvalidAddress();
        if (customerId == bytes32(0)) revert CustomerIdIsZero();
        return _roundingRouteKey(pairIndex, taker, customerId);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function priceAnchor(uint16 pairIndex, bool baseToQuote) public view returns (uint256) {
        PriceAnchors storage anchors = _anchors[pairIndex];
        return baseToQuote ? anchors.baseToQuote : anchors.quoteToBase;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Pairs (owner)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IManagedDirectPropAMM
    /// @dev Needs no pause: the pair starts `Closed`, and opening it validates its oracle.
    function addPair(
        address base,
        address quote,
        IPriceOracle oracle,
        uint256 maxOracleAge,
        uint256 maxPriceDeviationBps
    ) external nonReentrant onlyOwner returns (uint16 pairIndex) {
        if (base == address(0) || quote == address(0) || address(oracle) == address(0)) {
            revert InvalidAddress();
        }
        if (base == quote) revert SameToken();
        if (maxOracleAge == 0 || maxOracleAge > type(uint80).max) revert InvalidMaxOracleAge();
        if (maxPriceDeviationBps > BPS) revert InvalidMaxPriceDeviationBps(maxPriceDeviationBps, BPS);
        uint8 baseDecimals = ITIP20(base).decimals();
        uint8 quoteDecimals = ITIP20(quote).decimals();
        uint8 oracleDecimals = oracle.decimals();
        uint16 exponent = uint16(baseDecimals) + uint16(oracleDecimals);
        if (exponent < quoteDecimals || exponent - quoteDecimals > 77) {
            revert UnsupportedDecimals(baseDecimals, quoteDecimals, oracleDecimals);
        }
        pairIndex = pairCount;
        if (pairIndex == type(uint16).max) revert PairLimitReached();
        pairCount = pairIndex + 1;
        // The bounds checks above make these narrowing conversions safe.
        _pairs[pairIndex] = PairConfig({
            base: base,
            access: AccessMode.Closed,
            baseDecimals: baseDecimals,
            quoteDecimals: quoteDecimals,
            oracleDecimals: oracleDecimals,
            // forge-lint: disable-next-line(unsafe-typecast)
            scaleExponent: uint8(exponent - quoteDecimals),
            quote: quote,
            oracle: oracle,
            // forge-lint: disable-next-line(unsafe-typecast)
            maxPriceDeviationBps: uint16(maxPriceDeviationBps),
            // forge-lint: disable-next-line(unsafe-typecast)
            maxOracleAge: uint80(maxOracleAge)
        });
        // Checked: a token is in at most one side of each pair, and there are fewer than 2^16 pairs.
        ++tokenPairCount[base];
        ++tokenPairCount[quote];
        // The only external calls above are the `decimals()` views, which compile to STATICCALL.
        // forge-lint: disable-start(reentrancy-events)
        emit PairAdded(pairIndex, base, quote);
        emit OracleUpdated(pairIndex, address(0), address(oracle), oracleDecimals);
        emit MaxOracleAgeUpdated(pairIndex, 0, maxOracleAge);
        emit MaxPriceDeviationBpsUpdated(pairIndex, 0, maxPriceDeviationBps);
        // forge-lint: disable-end(reentrancy-events)
    }

    /// @inheritdoc IManagedDirectPropAMM
    function removePair(uint16 pairIndex) external nonReentrant onlyOwner {
        PairConfig storage config = _existingPair(pairIndex);
        --tokenPairCount[config.base];
        --tokenPairCount[config.quote];
        delete _pairs[pairIndex];
        delete _anchors[pairIndex];
        delete _pairHooks[pairIndex];
        emit PairRemoved(pairIndex);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function setPairHook(uint16 pairIndex, address hook, uint8 flags) external nonReentrant onlyOwner {
        _closedPair(pairIndex);
        if ((flags & ~ManagedPoolHookFlags.ALL) != 0) revert InvalidHookFlags();
        if (hook == address(0)) {
            if (flags != 0) revert InvalidHookFlags();
        } else {
            if (hook == address(this) || _isVirtual(hook) || hook.code.length == 0) revert InvalidHook();
            uint256 supported = uint256(_staticHookWord(hook, abi.encodeCall(IManagedPoolHook.supportedFlags, ())));
            if (supported > ManagedPoolHookFlags.ALL || (flags & supported) != flags) revert InvalidHookFlags();
        }
        _pairHooks[pairIndex] = PairHook(hook, flags);
        emit PairHookUpdated(pairIndex, hook, flags);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function pairHook(uint16 pairIndex) external view returns (address hook, uint8 flags) {
        _existingPair(pairIndex);
        PairHook memory selected = _pairHooks[pairIndex];
        return (selected.hook, selected.flags);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function setOracle(uint16 pairIndex, IPriceOracle newOracle) external nonReentrant onlyOwner {
        PairConfig storage config = _closedPair(pairIndex);
        if (address(newOracle) == address(0)) revert InvalidAddress();
        uint8 newOracleDecimals = newOracle.decimals();
        uint8 oracleDecimals = config.oracleDecimals;
        if (newOracleDecimals != oracleDecimals) revert OracleDecimalsChanged(oracleDecimals, newOracleDecimals);
        address oldOracle = address(config.oracle);
        config.oracle = newOracle;
        // The only external call above is the `decimals()` view.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OracleUpdated(pairIndex, oldOracle, address(newOracle), newOracleDecimals);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function setMaxOracleAge(uint16 pairIndex, uint256 newMaxOracleAge) external nonReentrant onlyOwner {
        PairConfig storage config = _closedPair(pairIndex);
        if (newMaxOracleAge == 0 || newMaxOracleAge > type(uint80).max) revert InvalidMaxOracleAge();
        uint256 oldMaxOracleAge = config.maxOracleAge;
        // The bounds check above makes this narrowing conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        config.maxOracleAge = uint80(newMaxOracleAge);
        emit MaxOracleAgeUpdated(pairIndex, oldMaxOracleAge, newMaxOracleAge);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function setMaxPriceDeviationBps(uint16 pairIndex, uint256 newMaxPriceDeviationBps)
        external
        nonReentrant
        onlyOwner
    {
        PairConfig storage config = _closedPair(pairIndex);
        if (newMaxPriceDeviationBps > BPS) revert InvalidMaxPriceDeviationBps(newMaxPriceDeviationBps, BPS);
        uint256 oldMaxPriceDeviationBps = config.maxPriceDeviationBps;
        // The bounds check above makes this narrowing conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        config.maxPriceDeviationBps = uint16(newMaxPriceDeviationBps);
        emit MaxPriceDeviationBpsUpdated(pairIndex, oldMaxPriceDeviationBps, newMaxPriceDeviationBps);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function resetPriceAnchor(uint16 pairIndex, bool baseToQuote) external nonReentrant onlyOwner {
        PairConfig storage config = _closedPair(pairIndex);
        (uint256 price,) = _readOracle(config);
        _setPriceAnchor(pairIndex, baseToQuote, price);
    }

    /// @inheritdoc IManagedDirectPropAMM
    /// @dev Any live pair: a swap moves only its own direction's anchor, so a direction nobody trades can drift past the
    /// limit while the other trades on. Unlike `resetPriceAnchor`, the pair stays tradable, so the owner's bound must
    /// hold at execution: the fresh read must sit within `priceToleranceBps` of `expectedPrice`, which the owner
    /// validated, or nothing changes. The deviation check is skipped, as in `resetPriceAnchor`.
    function refreshPriceAnchor(uint16 pairIndex, bool baseToQuote, uint256 expectedPrice, uint256 priceToleranceBps)
        external
        nonReentrant
        onlyOwner
    {
        PairConfig storage config = _existingPair(pairIndex);
        if (priceToleranceBps > BPS) revert InvalidOraclePriceToleranceBps(priceToleranceBps, BPS);
        (uint256 price,) = _readOracle(config);
        uint256 priceDeviation = price > expectedPrice ? price - expectedPrice : expectedPrice - price;
        if (priceDeviation > Math.mulDiv(expectedPrice, priceToleranceBps, BPS)) {
            revert OraclePriceToleranceExceeded(expectedPrice, price, priceToleranceBps);
        }
        _setPriceAnchor(pairIndex, baseToQuote, price);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Access
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IManagedDirectPropAMM
    function setPairAccess(uint16 pairIndex, AccessMode mode) external nonReentrant onlyOwner {
        PairConfig storage config = _existingPair(pairIndex);
        AccessMode oldMode = config.access;
        if (mode != oldMode) {
            if (mode == AccessMode.None) revert InvalidAccessMode();
            if (mode == AccessMode.Open && !paused) revert NotPaused();
            if (oldMode == AccessMode.Closed) _activate(pairIndex, config);
            config.access = mode;
        }
        // The only external call above is `_activate`'s oracle read, a view.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PairAccessUpdated(pairIndex, oldMode, mode);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function closePair(uint16 pairIndex) external nonReentrant onlyOwner {
        PairConfig storage config = _existingPair(pairIndex);
        AccessMode oldMode = config.access;
        config.access = AccessMode.Closed;
        emit PairAccessUpdated(pairIndex, oldMode, AccessMode.Closed);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function addSponsor(uint64 sponsorId, address admin) external nonReentrant onlyOwner {
        if (sponsorId == HOME || _sponsors[sponsorId].admin != address(0)) revert SponsorExists(sponsorId);
        _requireAccount(admin);
        _sponsors[sponsorId] = Sponsor({ admin: admin, enabled: true, generation: 1 });
        emit SponsorAdded(sponsorId, admin);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function setSponsorEnabled(uint64 sponsorId, bool enabled) external nonReentrant onlyOwner {
        Sponsor storage record = _registered(sponsorId);
        // `SponsorEnabledSet` below records every call.
        // forge-lint: disable-next-line(missing-events-access-control)
        if (record.enabled != enabled) record.enabled = enabled;
        emit SponsorEnabledSet(sponsorId, enabled, msg.sender);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function setPairSponsor(uint16 pairIndex, uint64 sponsorId, bool admitted) external nonReentrant onlyOwner {
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

    /// @inheritdoc IManagedDirectPropAMM
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

    /// @inheritdoc IManagedDirectPropAMM
    function transferSponsorAdmin(uint64 sponsorId, address newAdmin) external nonReentrant {
        address admin = _sponsors[sponsorId].admin;
        // An unregistered id has no admin, and `msg.sender` is never zero.
        if (msg.sender != admin) revert NotSponsorAdmin(sponsorId);
        // The pool and a virtual address could never accept.
        if (newAdmin == address(0) || newAdmin == address(this) || _isVirtual(newAdmin)) revert InvalidAddress();
        pendingSponsorAdmin[sponsorId] = newAdmin;
        emit SponsorAdminTransferStarted(sponsorId, admin, newAdmin);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function cancelSponsorAdminTransfer(uint64 sponsorId) external nonReentrant {
        address admin = _sponsors[sponsorId].admin;
        // An unregistered id has no admin, and `msg.sender` is never zero.
        if (msg.sender != admin) revert NotSponsorAdmin(sponsorId);
        // The event makes an idempotent cancellation observable. Deleting avoids a redundant write.
        if (pendingSponsorAdmin[sponsorId] != address(0)) delete pendingSponsorAdmin[sponsorId];
        emit SponsorAdminTransferStarted(sponsorId, admin, address(0));
    }

    /// @inheritdoc IManagedDirectPropAMM
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

    /// @inheritdoc IManagedDirectPropAMM
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

    /// @inheritdoc IManagedDirectPropAMM
    function setDenied(address[] calldata accounts, bool deny) external nonReentrant onlyOwner {
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

    // ---------------------------------------------------------------------------------------------------------------
    // Inventory and roles
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IManagedDirectPropAMM
    function fund(address token, uint256 amount, bytes32 memo) external onlyOwner nonReentrant {
        if (tokenPairCount[token] == 0) revert UnsupportedToken(token);
        if (amount == 0) revert AmountIsZero();
        _pullExact(token, msg.sender, amount, memo);
        // The transfer runs under the swaps' lock, and the event follows it as in `DirectPropAMM`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Funded(token, amount, memo);
    }

    /// @inheritdoc IManagedDirectPropAMM
    /// @dev `DirectPropAMM.withdraw` and its `_pushExact`, minus the pause, the pair-token requirement and TIP-1022
    /// resolution: any token, so a removed pair's inventory and stray tokens can leave. The swaps' lock keeps a
    /// withdrawal and a swap from interleaving.
    function withdraw(address token, address recipient, uint256 amount, bytes32 memo) external onlyOwner nonReentrant {
        if (token == address(0)) revert UnsupportedToken(token);
        if (amount == 0) revert AmountIsZero();
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        if (_isVirtual(recipient)) revert VirtualRecipient(recipient);
        _pushExact(token, recipient, amount, memo);
        // The transfer runs under the swaps' lock, and the event follows it as in `DirectPropAMM`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Withdrawn(token, recipient, amount, memo);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function pause() external nonReentrant onlyOwner {
        if (!paused) {
            paused = true;
            emit PausedStateChanged(true);
        }
    }

    /// @inheritdoc IManagedDirectPropAMM
    function unpause() external nonReentrant onlyOwner {
        if (paused) {
            paused = false;
            emit PausedStateChanged(false);
        }
    }

    /// @inheritdoc IManagedDirectPropAMM
    function transferOwnership(address newOwner) external nonReentrant onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IManagedDirectPropAMM
    function pair(uint16 pairIndex) external view returns (Pair memory info) {
        PairConfig storage config = _pairs[pairIndex];
        if (config.base == address(0)) return info;
        info = Pair({
            base: config.base,
            quote: config.quote,
            oracle: config.oracle,
            baseDecimals: config.baseDecimals,
            quoteDecimals: config.quoteDecimals,
            oracleDecimals: config.oracleDecimals,
            priceScale: _scale(config),
            maxOracleAge: config.maxOracleAge,
            maxPriceDeviationBps: config.maxPriceDeviationBps,
            access: config.access
        });
    }

    /// @inheritdoc IManagedDirectPropAMM
    function deniedCount() external view returns (uint32) {
        return _deniedCount;
    }

    /// @inheritdoc IManagedDirectPropAMM
    function sponsor(uint64 sponsorId) external view returns (address admin, bool enabled, uint32 generation) {
        Sponsor memory record = _sponsors[sponsorId];
        return (record.admin, record.enabled, record.generation);
    }

    /// @inheritdoc IManagedDirectPropAMM
    function pairSponsor(uint16 pairIndex, uint64 sponsorId) external view returns (bool) {
        if (_pairs[pairIndex].base == address(0)) return false;
        if (sponsorId == HOME) return true;
        return _admitted[pairIndex][sponsorId] == ADMITTED;
    }

    /// @inheritdoc IManagedDirectPropAMM
    function isMember(uint16 pairIndex, uint64 sponsorId, address account) external view returns (bool) {
        if (_pairs[pairIndex].base == address(0)) return false;
        uint32 stored = _members[pairIndex][sponsorId][account];
        return stored != 0 && stored == (sponsorId == HOME ? HOME_GENERATION : _sponsors[sponsorId].generation);
    }

    /// @inheritdoc IManagedDirectPropAMM
    /// @dev A removed or unknown pair reads `None` and is false without reading any list.
    function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (bool) {
        return _takerAccess(pairIndex, _pairs[pairIndex].access, taker, sponsorId) == TakerAccess.Allowed;
    }

    /// @inheritdoc IManagedDirectPropAMM
    /// @dev A removed or unknown pair reads `None` and is `UnknownPair` without reading any list.
    function takerAccess(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (TakerAccess) {
        return _takerAccess(pairIndex, _pairs[pairIndex].access, taker, sponsorId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals: the swap
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `DirectPropAMM`'s swap order: the deadline, access (where v1 checks its taker), `customerId`, the amount,
    /// the bound oracle, the credit math and the limits, the credit write, the anchor, settlement, then the events.
    function _swap(SwapParams memory s, address taker, bool prepaid) private returns (uint256 result) {
        if (block.timestamp > s.deadline) revert DeadlineExpired(s.deadline, block.timestamp);
        PairConfig storage config = _pairs[s.pairIndex];
        TakerAccess outcome = _takerAccess(s.pairIndex, config.access, taker, s.sponsorId);
        if (outcome != TakerAccess.Allowed) _refuse(outcome, s.pairIndex, taker, s.sponsorId);
        if (s.customerId == bytes32(0)) revert CustomerIdIsZero();
        if (s.amount == 0) revert AmountIsZero();

        (uint256 price, uint256 updatedAt) = _readBoundOracle(
            s.pairIndex,
            config,
            s.baseToQuote,
            s.expectedOraclePrice,
            s.oraclePriceToleranceBps,
            s.minimumOracleUpdatedAt
        );
        bytes32 routeKey = _roundingRouteKey(s.pairIndex, taker, s.customerId);
        uint256 previousCredit = roundingCredit[routeKey];
        uint256 scale = _scale(config);
        PairHook memory selected = _pairHooks[s.pairIndex];
        IManagedPoolHook.QuoteContext memory quoteContext = IManagedPoolHook.QuoteContext({
            pairIndex: s.pairIndex, taker: taker, baseToQuote: s.baseToQuote, exactInput: s.exactInput, amount: s.amount
        });
        uint16 feeBps = _hookFeeBps(selected, quoteContext);
        uint256 fee;
        uint256 newCredit;
        uint256 amountIn;
        uint256 amountOut;
        if (s.exactInput) {
            amountIn = s.amount;
            fee = _inputFee(amountIn, feeBps);
            (amountOut, newCredit) =
                _quoteExactInputWithCredit(s.baseToQuote, amountIn - fee, price, previousCredit, scale);
            if (amountOut == 0) revert AmountIsZero();
            if (amountOut < s.limit) revert SlippageExceeded(s.limit, amountOut);
            result = amountOut;
        } else {
            amountOut = s.amount;
            (amountIn, newCredit) = _quoteExactOutputWithCredit(s.baseToQuote, amountOut, price, previousCredit, scale);
            uint256 netInput = amountIn;
            amountIn = _grossInput(netInput, feeBps);
            fee = amountIn - netInput;
            if (amountIn > s.limit) revert SlippageExceeded(s.limit, amountIn);
            result = amountIn;
        }

        roundingCredit[routeKey] = newCredit;
        _setPriceAnchor(s.pairIndex, s.baseToQuote, price);
        (address tokenIn, address tokenOut) = s.baseToQuote ? (config.base, config.quote) : (config.quote, config.base);
        if (!prepaid && amountIn != 0) {
            _pullExact(tokenIn, msg.sender, amountIn, _memo("SWAP_IN", s.customerId, s.tradeId));
        }
        IManagedPoolHook.SwapContext memory context;
        if ((selected.flags & (ManagedPoolHookFlags.BEFORE_SWAP | ManagedPoolHookFlags.AFTER_SWAP)) != 0) {
            context = IManagedPoolHook.SwapContext({
                quote: quoteContext,
                sponsorId: s.sponsorId,
                customerId: s.customerId,
                tradeId: s.tradeId,
                caller: taker,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                amountOut: amountOut
            });
            if ((selected.flags & ManagedPoolHookFlags.BEFORE_SWAP) != 0) {
                _callSwapHook(selected.hook, IManagedPoolHook.beforeSwap.selector, context);
            }
        }
        _pushExact(tokenOut, taker, amountOut, _memo("SWAP_OUT", s.customerId, s.tradeId));
        if ((selected.flags & ManagedPoolHookFlags.AFTER_SWAP) != 0) {
            _callSwapHook(selected.hook, IManagedPoolHook.afterSwap.selector, context);
        }
        // `DirectPropAMM`'s order: the transfers run under the swaps' lock, and the events follow them.
        // forge-lint: disable-start(reentrancy-events)
        if (fee != 0) emit HookFeeCharged(s.pairIndex, taker, tokenIn, fee);
        emit RoundingCreditUpdated(routeKey, previousCredit, newCredit);
        emit TradeExecuted(
            s.pairIndex,
            taker,
            s.customerId,
            s.sponsorId,
            s.tradeId,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            price,
            updatedAt
        );
        // forge-lint: disable-end(reentrancy-events)
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals: access (`Venue`'s check)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev List access in order: a pair that isn't live (`None`); `Closed`; the deny list, read
    /// only while `deniedCount` is nonzero; `Open` admits whatever `sponsorId`, reading no list; and `Listed` reads the
    /// list the swap names: the home list (0) with one read, and any other id its sponsor slot, which must be
    /// registered and enabled, the pair's admission, then the member, which must carry the sponsor's current
    /// generation. Returns `Allowed` or the first refusal, never `None`.
    function _takerAccess(uint16 pairIndex, AccessMode mode, address taker, uint64 sponsorId)
        private
        view
        returns (TakerAccess)
    {
        if (mode == AccessMode.None) return TakerAccess.UnknownPair;
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

    /// @dev Reverts with the swap's error for an access refusal (`TakerAccess` lists them).
    function _refuse(TakerAccess outcome, uint16 pairIndex, address taker, uint64 sponsorId) private pure {
        if (outcome == TakerAccess.UnknownPair) revert UnknownPair(pairIndex);
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

    /// @dev A sponsor admin: not `address(0)`, which marks an unregistered id, nor an account that can never call: the
    /// pool, or a TIP-1022 virtual address.
    function _requireAccount(address account) private view {
        if (account == address(0) || account == address(this) || _isVirtual(account)) revert InvalidAddress();
    }

    /// @dev Whether `account` has the TIP-1022 virtual-address layout, which never sends a call. The layout alone
    /// identifies one: no registry is asked.
    function _isVirtual(address account) private pure returns (bool) {
        return ((uint160(account) >> 48) & type(uint80).max) == VIRTUAL_MAGIC;
    }

    function _onlyOwner() private view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _existingPair(uint16 pairIndex) private view returns (PairConfig storage config) {
        config = _pairs[pairIndex];
        if (config.base == address(0)) revert UnknownPair(pairIndex);
    }

    /// @dev A live pair whose oracle, risk settings and unbounded anchor reset may change: it must be `Closed`.
    function _closedPair(uint16 pairIndex) private view returns (PairConfig storage config) {
        config = _existingPair(pairIndex);
        if (config.access != AccessMode.Closed) revert PairNotClosed(pairIndex);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals: pricing (`DirectPropAMM`'s, with the pair's configuration passed in)
    // ---------------------------------------------------------------------------------------------------------------

    function _scale(PairConfig storage config) private view returns (uint256) {
        return 10 ** uint256(config.scaleExponent);
    }

    /// @dev `DirectPropAMM.unpause`'s paused-to-active checks, for one pair leaving `Closed`.
    function _activate(uint16 pairIndex, PairConfig storage config) private {
        (uint256 price,) = _readOracle(config);
        PriceAnchors storage anchors = _anchors[pairIndex];
        if (anchors.baseToQuote == 0) _setPriceAnchor(pairIndex, true, price);
        else _validatePriceDeviation(pairIndex, config, true, price);
        if (anchors.quoteToBase == 0) _setPriceAnchor(pairIndex, false, price);
        else _validatePriceDeviation(pairIndex, config, false, price);
    }

    function _readOracle(PairConfig storage config) private view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = config.oracle.latestPrice();
        if (price == 0 || updatedAt == 0) revert InvalidPrice();
        if (updatedAt > block.timestamp) revert FutureOracleTimestamp(updatedAt, block.timestamp);
        uint256 maxOracleAge = config.maxOracleAge;
        if (block.timestamp - updatedAt > maxOracleAge) revert StaleOraclePrice(updatedAt, maxOracleAge);
    }

    function _readGuardedOracle(uint16 pairIndex, PairConfig storage config, bool baseToQuote)
        private
        view
        returns (uint256 price, uint256 updatedAt)
    {
        (price, updatedAt) = _readOracle(config);
        _validatePriceDeviation(pairIndex, config, baseToQuote, price);
    }

    function _readBoundOracle(
        uint16 pairIndex,
        PairConfig storage config,
        bool baseToQuote,
        uint256 expectedPrice,
        uint256 priceToleranceBps,
        uint256 minimumUpdatedAt
    ) private view returns (uint256 price, uint256 updatedAt) {
        if (priceToleranceBps > BPS) {
            revert InvalidOraclePriceToleranceBps(priceToleranceBps, BPS);
        }
        (price, updatedAt) = _readGuardedOracle(pairIndex, config, baseToQuote);
        if (priceToleranceBps == 0) {
            if (price != expectedPrice) revert OraclePriceToleranceExceeded(expectedPrice, price, 0);
        } else {
            uint256 priceDeviation = price > expectedPrice ? price - expectedPrice : expectedPrice - price;
            uint256 maximumPriceDeviation = Math.mulDiv(expectedPrice, priceToleranceBps, BPS);
            if (priceDeviation > maximumPriceDeviation) {
                revert OraclePriceToleranceExceeded(expectedPrice, price, priceToleranceBps);
            }
        }
        if (updatedAt < minimumUpdatedAt) revert OracleTimestampTooOld(minimumUpdatedAt, updatedAt);
    }

    function _validatePriceDeviation(uint16 pairIndex, PairConfig storage config, bool baseToQuote, uint256 price)
        private
        view
    {
        uint256 anchor = priceAnchor(pairIndex, baseToQuote);
        if (anchor == 0) revert PriceAnchorNotInitialized(baseToQuote);
        uint256 maxPriceDeviationBps = config.maxPriceDeviationBps;
        uint256 deviation = price > anchor ? price - anchor : anchor - price;
        uint256 maximumDeviation = Math.mulDiv(anchor, maxPriceDeviationBps, BPS);
        if (deviation > maximumDeviation) {
            revert PriceDeviationExceeded(baseToQuote, price, anchor, maxPriceDeviationBps);
        }
    }

    function _setPriceAnchor(uint16 pairIndex, bool baseToQuote, uint256 newAnchor) private {
        PriceAnchors storage anchors = _anchors[pairIndex];
        uint256 oldAnchor = baseToQuote ? anchors.baseToQuote : anchors.quoteToBase;
        if (oldAnchor == newAnchor) return;
        if (baseToQuote) anchors.baseToQuote = newAnchor;
        else anchors.quoteToBase = newAnchor;
        emit PriceAnchorUpdated(pairIndex, baseToQuote, oldAnchor, newAnchor);
    }

    function _roundingRouteKey(uint16 pairIndex, address taker, bytes32 customerId) private pure returns (bytes32) {
        return keccak256(abi.encode(pairIndex, taker, customerId));
    }

    function _feeBps(uint16 pairIndex, address taker, bool baseToQuote, bool exactInput, uint256 amount)
        private
        view
        returns (uint16)
    {
        return _hookFeeBps(
            _pairHooks[pairIndex], IManagedPoolHook.QuoteContext(pairIndex, taker, baseToQuote, exactInput, amount)
        );
    }

    function _hookFeeBps(PairHook memory selected, IManagedPoolHook.QuoteContext memory context)
        private
        view
        returns (uint16)
    {
        if ((selected.flags & ManagedPoolHookFlags.QUOTE) == 0) return 0;
        uint256 fee = uint256(_staticHookWord(selected.hook, abi.encodeCall(IManagedPoolHook.quote, (context))));
        if (fee > MAX_HOOK_FEE_BPS) revert HookFeeTooHigh(fee, MAX_HOOK_FEE_BPS);
        // The cap check above also validates canonical uint16 encoding.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(fee);
    }

    /// @dev Fixed output buffer: never allocate or bubble unbounded hook returndata. Fail closed on all errors.
    function _staticHookWord(address hook, bytes memory data) private view returns (bytes32 word) {
        bool success;
        uint256 size;
        uint256 gasLimit = HOOK_VIEW_GAS;
        assembly ("memory-safe") {
            let output := mload(0x40)
            success := staticcall(gasLimit, hook, add(data, 0x20), mload(data), output, 0x20)
            size := returndatasize()
            word := mload(output)
        }
        if (!success) revert HookCallFailed();
        if (size != 32) revert InvalidHookResponse();
    }

    /// @dev Run each stage against its own pre-call balances: neither pair token may decrease. The lock blocks
    /// all pool mutations even if the hook has an administrative role. No allowances or delegatecalls are used.
    function _callSwapHook(address hook, bytes4 selector, IManagedPoolHook.SwapContext memory context) private {
        uint256 inputBefore = ITIP20(context.tokenIn).balanceOf(address(this));
        uint256 outputBefore = ITIP20(context.tokenOut).balanceOf(address(this));
        bytes memory data = abi.encodeWithSelector(selector, context);
        bool success;
        uint256 size;
        bytes32 word;
        uint256 gasLimit = HOOK_CALLBACK_GAS;
        assembly ("memory-safe") {
            let output := mload(0x40)
            success := call(gasLimit, hook, 0, add(data, 0x20), mload(data), output, 0x20)
            size := returndatasize()
            word := mload(output)
        }
        if (!success) revert HookCallFailed();
        if (size != 32 || word != bytes32(selector)) revert InvalidHookResponse();
        if (
            ITIP20(context.tokenIn).balanceOf(address(this)) < inputBefore
                || ITIP20(context.tokenOut).balanceOf(address(this)) < outputBefore
        ) revert HookBalanceDecreased();
    }

    /// @dev Fees are whole input-token units, rounded toward the maker. They never enter rounding credit.
    function _inputFee(uint256 grossInput, uint16 feeBps) private pure returns (uint256) {
        return feeBps == 0 ? 0 : Math.mulDiv(grossInput, feeBps, BPS, Math.Rounding.Ceil);
    }

    /// @dev Least gross input for the required net input: net = floor(gross * (BPS - feeBps) / BPS).
    /// The cap is below BPS. Credit-only exact-output fills need no new input and pay no new fee.
    function _grossInput(uint256 netInput, uint16 feeBps) private pure returns (uint256) {
        return feeBps == 0 ? netInput : Math.mulDiv(netInput, BPS, BPS - feeBps, Math.Rounding.Ceil);
    }

    function _quoteExactInputWithCredit(
        bool baseToQuote,
        uint256 amountIn,
        uint256 price,
        uint256 credit,
        uint256 scale
    ) private pure returns (uint256 amountOut, uint256 creditAfter) {
        uint256 inputValue = baseToQuote ? price : scale;
        uint256 outputValue = baseToQuote ? scale : price;
        uint256 quotient = Math.mulDiv(amountIn, inputValue, outputValue);
        uint256 remainder = mulmod(amountIn, inputValue, outputValue);
        uint256 creditQuotient = credit / outputValue;
        uint256 creditRemainder = credit % outputValue;
        uint256 carry = 0;

        if (creditRemainder != 0 && remainder >= outputValue - creditRemainder) {
            carry = 1;
            creditAfter = remainder - (outputValue - creditRemainder);
        } else {
            creditAfter = remainder + creditRemainder;
        }
        amountOut = quotient + creditQuotient + carry;
    }

    function _quoteExactOutputWithCredit(
        bool baseToQuote,
        uint256 amountOut,
        uint256 price,
        uint256 credit,
        uint256 scale
    ) private pure returns (uint256 amountIn, uint256 creditAfter) {
        uint256 outputValue = baseToQuote ? scale : price;
        uint256 inputValue = baseToQuote ? price : scale;
        uint256 quotient = Math.mulDiv(amountOut, outputValue, inputValue);
        uint256 remainder = mulmod(amountOut, outputValue, inputValue);
        uint256 creditQuotient = credit / inputValue;
        uint256 creditRemainder = credit % inputValue;

        if (creditQuotient > quotient || (creditQuotient == quotient && creditRemainder >= remainder)) {
            uint256 outputValueRequired = quotient * inputValue + remainder;
            return (0, credit - outputValueRequired);
        }

        uint256 differenceQuotient;
        uint256 differenceRemainder;
        if (remainder >= creditRemainder) {
            differenceQuotient = quotient - creditQuotient;
            differenceRemainder = remainder - creditRemainder;
        } else {
            differenceQuotient = quotient - creditQuotient - 1;
            differenceRemainder = inputValue - (creditRemainder - remainder);
        }

        amountIn = differenceQuotient;
        if (differenceRemainder != 0) {
            amountIn += 1;
            creditAfter = inputValue - differenceRemainder;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals: token movement (`DirectPropAMM`'s exact-delta checks)
    // ---------------------------------------------------------------------------------------------------------------

    function _pullExact(address token, address from, uint256 amount, bytes32 memo) private {
        uint256 beforeBalance = ITIP20(token).balanceOf(address(this));
        bool success = ITIP20(token).transferFromWithMemo(from, address(this), amount, memo);
        if (!success) revert TokenTransferFailed(token);
        uint256 afterBalance = ITIP20(token).balanceOf(address(this));
        uint256 actual = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (actual != amount) revert ExactBalanceDeltaFailed(token, amount, actual);
    }

    /// @dev Sends `amount` to `recipient` and requires the pool's debit and `recipient`'s credit to equal it exactly.
    function _pushExact(address token, address recipient, uint256 amount, bytes32 memo) private {
        uint256 poolBefore = ITIP20(token).balanceOf(address(this));
        if (poolBefore < amount) revert InsufficientInventory(token, poolBefore, amount);
        uint256 recipientBefore = ITIP20(token).balanceOf(recipient);
        ITIP20(token).transferWithMemo(recipient, amount, memo);
        uint256 poolAfter = ITIP20(token).balanceOf(address(this));
        uint256 recipientAfter = ITIP20(token).balanceOf(recipient);

        uint256 poolDelta = poolBefore >= poolAfter ? poolBefore - poolAfter : 0;
        uint256 recipientDelta = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (poolDelta != amount) revert ExactBalanceDeltaFailed(token, amount, poolDelta);
        if (recipientDelta != amount) revert ExactBalanceDeltaFailed(token, amount, recipientDelta);
    }

    function _memo(string memory action, bytes32 customerId, bytes32 tradeId) private pure returns (bytes32) {
        return keccak256(abi.encode(action, customerId, tradeId));
    }
}

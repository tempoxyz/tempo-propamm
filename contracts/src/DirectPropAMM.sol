// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IAddressRegistry } from "./interfaces/IAddressRegistry.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";
import { ITIP20 } from "./interfaces/ITIP20.sol";

/// @notice Permissioned, owner-inventoried, oracle-priced direct swap venue for one immutable pair.
contract DirectPropAMM is ReentrancyGuardTransient {
    using Math for uint256;

    uint256 public constant BPS = 10_000;

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
    error NotGuardianOrOwner();
    error NotOwner();
    error NotPaused();
    error NotPendingOwner();
    error OraclePriceToleranceExceeded(uint256 expectedPrice, uint256 actualPrice, uint256 toleranceBps);
    error OracleTimestampTooOld(uint256 minimumUpdatedAt, uint256 actualUpdatedAt);
    error OracleDecimalsChanged(uint8 currentDecimals, uint8 proposedDecimals);
    error Paused();
    error PriceAnchorNotInitialized(bool baseToQuote);
    error PriceDeviationExceeded(bool baseToQuote, uint256 price, uint256 anchor, uint256 maxDeviationBps);
    error RecipientNotAllowed(address recipient);
    error SameToken();
    error SlippageExceeded(uint256 limit, uint256 actual);
    error StaleOraclePrice(uint256 updatedAt, uint256 maxAge);
    error TakerNotAllowed(address taker);
    error TokenTransferFailed(address token);
    error UnsupportedDecimals(uint8 baseDecimals, uint8 quoteDecimals, uint8 oracleDecimals);
    error UnsupportedToken(address token);

    event Funded(address indexed token, uint256 amount, bytes32 indexed memo);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event MaxOracleAgeUpdated(uint256 oldMaxAge, uint256 newMaxAge);
    event MaxPriceDeviationBpsUpdated(uint256 oldMaxPriceDeviationBps, uint256 newMaxPriceDeviationBps);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle, uint8 decimals);
    event OwnershipTransferStarted(address indexed oldOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event PausedStateChanged(bool paused);
    event PriceAnchorUpdated(bool indexed baseToQuote, uint256 oldAnchor, uint256 newAnchor);
    event RecipientPermissionUpdated(address indexed recipient, bool allowed);
    event RoundingCreditUpdated(bytes32 indexed routeKey, uint256 previousCredit, uint256 newCredit);
    event TakerPermissionUpdated(address indexed taker, bool allowed);
    event TradeExecuted(
        address indexed taker,
        address indexed recipient,
        bytes32 indexed customerId,
        bytes32 tradeId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 oraclePrice,
        uint256 oracleUpdatedAt
    );
    event Withdrawn(address indexed token, address indexed recipient, uint256 amount, bytes32 memo);

    ITIP20 public immutable baseToken;
    ITIP20 public immutable quoteToken;
    IAddressRegistry public immutable addressRegistry;
    uint8 public immutable baseDecimals;
    uint8 public immutable quoteDecimals;

    // Packed together so guarded oracle reads warm one storage slot for all three values.
    IPriceOracle public oracle;
    uint8 public immutable oracleDecimals;
    uint256 public immutable priceScale;
    uint16 public maxPriceDeviationBps;
    // uint80 seconds exceeds any practical oracle-age configuration horizon.
    uint80 public maxOracleAge;
    uint256 public baseToQuotePriceAnchor;
    uint256 public quoteToBasePriceAnchor;

    address public owner;
    address public pendingOwner;
    address public guardian;
    bool public paused;

    mapping(address taker => bool allowed) public takerAllowed;
    mapping(address recipient => bool allowed) public recipientAllowed;
    mapping(bytes32 routeKey => uint256 credit) public roundingCredit;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPaused() {
        if (!paused) revert NotPaused();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(
        ITIP20 baseToken_,
        ITIP20 quoteToken_,
        IPriceOracle oracle_,
        IAddressRegistry addressRegistry_,
        address owner_,
        address guardian_,
        uint256 maxOracleAge_,
        uint256 maxPriceDeviationBps_
    ) {
        if (
            address(baseToken_) == address(0) || address(quoteToken_) == address(0) || address(oracle_) == address(0)
                || address(addressRegistry_) == address(0) || owner_ == address(0) || guardian_ == address(0)
        ) revert InvalidAddress();
        if (address(baseToken_) == address(quoteToken_)) revert SameToken();
        if (maxOracleAge_ == 0 || maxOracleAge_ > type(uint80).max) revert InvalidMaxOracleAge();
        if (maxPriceDeviationBps_ > BPS) {
            revert InvalidMaxPriceDeviationBps(maxPriceDeviationBps_, BPS);
        }

        baseToken = baseToken_;
        quoteToken = quoteToken_;
        addressRegistry = addressRegistry_;
        baseDecimals = baseToken_.decimals();
        quoteDecimals = quoteToken_.decimals();
        uint8 oracleDecimals_ = oracle_.decimals();
        uint16 exponent = uint16(baseDecimals) + uint16(oracleDecimals_);
        if (exponent < quoteDecimals || exponent - quoteDecimals > 77) {
            revert UnsupportedDecimals(baseDecimals, quoteDecimals, oracleDecimals_);
        }
        oracle = oracle_;
        oracleDecimals = oracleDecimals_;
        priceScale = 10 ** (exponent - quoteDecimals);
        // The bounds check above makes this narrowing conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        maxPriceDeviationBps = uint16(maxPriceDeviationBps_);
        owner = owner_;
        guardian = guardian_;
        // The bounds check above makes this narrowing conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        maxOracleAge = uint80(maxOracleAge_);
        paused = true;

        emit OracleUpdated(address(0), address(oracle_), oracleDecimals_);
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianUpdated(address(0), guardian_);
        emit MaxOracleAgeUpdated(0, maxOracleAge_);
        emit MaxPriceDeviationBpsUpdated(0, maxPriceDeviationBps_);
        emit PausedStateChanged(true);
    }

    /// @notice Swaps an exact input within the caller's quoted-price tolerance using a non-older observation.
    function swapExactInput(
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external whenNotPaused nonReentrant returns (uint256 amountOut) {
        _validateDeadline(deadline);
        address resolvedRecipient = _validateTrade(recipient, customerId);
        if (amountIn == 0) revert AmountIsZero();

        (uint256 price, uint256 updatedAt) =
            _readBoundOracle(baseToQuote, expectedOraclePrice, oraclePriceToleranceBps, minimumOracleUpdatedAt);
        bytes32 routeKey = _roundingRouteKey(msg.sender, resolvedRecipient, customerId);
        uint256 previousCredit = roundingCredit[routeKey];
        uint256 newCredit;
        (amountOut, newCredit) = _quoteExactInputWithCredit(baseToQuote, amountIn, price, previousCredit);
        if (amountOut == 0) revert AmountIsZero();
        if (amountOut < minAmountOut) revert SlippageExceeded(minAmountOut, amountOut);

        roundingCredit[routeKey] = newCredit;
        _setPriceAnchor(baseToQuote, price);
        _settle(baseToQuote, amountIn, amountOut, recipient, resolvedRecipient, customerId, tradeId);
        emit RoundingCreditUpdated(routeKey, previousCredit, newCredit);
        emit TradeExecuted(
            msg.sender,
            recipient,
            customerId,
            tradeId,
            address(baseToQuote ? baseToken : quoteToken),
            address(baseToQuote ? quoteToken : baseToken),
            amountIn,
            amountOut,
            price,
            updatedAt
        );
    }

    /// @notice Swaps for an exact output within the caller's quoted-price tolerance using a non-older observation.
    function swapExactOutput(
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external whenNotPaused nonReentrant returns (uint256 amountIn) {
        _validateDeadline(deadline);
        address resolvedRecipient = _validateTrade(recipient, customerId);
        if (amountOut == 0) revert AmountIsZero();

        (uint256 price, uint256 updatedAt) =
            _readBoundOracle(baseToQuote, expectedOraclePrice, oraclePriceToleranceBps, minimumOracleUpdatedAt);
        bytes32 routeKey = _roundingRouteKey(msg.sender, resolvedRecipient, customerId);
        uint256 previousCredit = roundingCredit[routeKey];
        uint256 newCredit;
        (amountIn, newCredit) = _quoteExactOutputWithCredit(baseToQuote, amountOut, price, previousCredit);
        if (amountIn > maxAmountIn) revert SlippageExceeded(maxAmountIn, amountIn);

        roundingCredit[routeKey] = newCredit;
        _setPriceAnchor(baseToQuote, price);
        _settle(baseToQuote, amountIn, amountOut, recipient, resolvedRecipient, customerId, tradeId);
        emit RoundingCreditUpdated(routeKey, previousCredit, newCredit);
        emit TradeExecuted(
            msg.sender,
            recipient,
            customerId,
            tradeId,
            address(baseToQuote ? baseToken : quoteToken),
            address(baseToQuote ? quoteToken : baseToken),
            amountIn,
            amountOut,
            price,
            updatedAt
        );
    }

    function quoteExactInput(bool baseToQuote, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 price, uint256 updatedAt)
    {
        if (amountIn == 0) revert AmountIsZero();
        (price, updatedAt) = _readGuardedOracle(baseToQuote);
        amountOut = baseToQuote ? Math.mulDiv(amountIn, price, priceScale) : Math.mulDiv(amountIn, priceScale, price);
    }

    function quoteExactOutput(bool baseToQuote, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint256 price, uint256 updatedAt)
    {
        if (amountOut == 0) revert AmountIsZero();
        (price, updatedAt) = _readGuardedOracle(baseToQuote);
        amountIn = baseToQuote
            ? Math.mulDiv(amountOut, priceScale, price, Math.Rounding.Ceil)
            : Math.mulDiv(amountOut, price, priceScale, Math.Rounding.Ceil);
    }

    /// @notice Quotes the exact execution for a route, including its accrued rounding credit.
    function quoteExactInputFor(
        address taker,
        address recipient,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 price, uint256 updatedAt, uint256 creditAfter) {
        if (amountIn == 0) revert AmountIsZero();
        bytes32 routeKey = roundingRouteKey(taker, recipient, customerId);
        (price, updatedAt) = _readGuardedOracle(baseToQuote);
        (amountOut, creditAfter) = _quoteExactInputWithCredit(baseToQuote, amountIn, price, roundingCredit[routeKey]);
    }

    /// @notice Quotes the exact execution for a route, including its accrued rounding credit.
    function quoteExactOutputFor(
        address taker,
        address recipient,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 price, uint256 updatedAt, uint256 creditAfter) {
        if (amountOut == 0) revert AmountIsZero();
        bytes32 routeKey = roundingRouteKey(taker, recipient, customerId);
        (price, updatedAt) = _readGuardedOracle(baseToQuote);
        (amountIn, creditAfter) = _quoteExactOutputWithCredit(baseToQuote, amountOut, price, roundingCredit[routeKey]);
    }

    function roundingRouteKey(address taker, address recipient, bytes32 customerId) public view returns (bytes32) {
        if (taker == address(0)) revert InvalidAddress();
        if (customerId == bytes32(0)) revert CustomerIdIsZero();
        return _roundingRouteKey(taker, resolveRecipient(recipient), customerId);
    }

    function priceAnchor(bool baseToQuote) public view returns (uint256) {
        return baseToQuote ? baseToQuotePriceAnchor : quoteToBasePriceAnchor;
    }

    function resolveRecipient(address recipient) public view returns (address resolved) {
        if (recipient == address(0)) revert InvalidAddress();
        resolved = addressRegistry.resolveRecipient(recipient);
        if (resolved == address(0)) revert InvalidAddress();
    }

    function fund(address token, uint256 amount, bytes32 memo) external onlyOwner nonReentrant {
        _requirePairToken(token);
        if (amount == 0) revert AmountIsZero();
        _pullExact(ITIP20(token), msg.sender, amount, memo);
        emit Funded(token, amount, memo);
    }

    function withdraw(address token, address recipient, uint256 amount, bytes32 memo)
        external
        onlyOwner
        onlyPaused
        nonReentrant
    {
        _requirePairToken(token);
        if (amount == 0) revert AmountIsZero();
        address resolvedRecipient = resolveRecipient(recipient);
        if (resolvedRecipient == address(this)) revert InvalidAddress();
        _pushExact(ITIP20(token), recipient, resolvedRecipient, amount, memo);
        emit Withdrawn(token, recipient, amount, memo);
    }

    function setTakerAllowed(address taker, bool allowed) external onlyOwner {
        if (taker == address(0)) revert InvalidAddress();
        takerAllowed[taker] = allowed;
        emit TakerPermissionUpdated(taker, allowed);
    }

    function setRecipientAllowed(address recipient, bool allowed) external onlyOwner {
        address resolved = resolveRecipient(recipient);
        recipientAllowed[resolved] = allowed;
        emit RecipientPermissionUpdated(resolved, allowed);
    }

    function setOracle(IPriceOracle newOracle) external onlyOwner onlyPaused {
        if (address(newOracle) == address(0)) revert InvalidAddress();
        uint8 newOracleDecimals = newOracle.decimals();
        if (newOracleDecimals != oracleDecimals) {
            revert OracleDecimalsChanged(oracleDecimals, newOracleDecimals);
        }

        address oldOracle = address(oracle);
        oracle = newOracle;
        emit OracleUpdated(oldOracle, address(newOracle), newOracleDecimals);
    }

    function setMaxOracleAge(uint256 newMaxOracleAge) external onlyOwner onlyPaused {
        if (newMaxOracleAge == 0 || newMaxOracleAge > type(uint80).max) revert InvalidMaxOracleAge();
        uint256 oldMaxOracleAge = maxOracleAge;
        // The bounds check above makes this narrowing conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        maxOracleAge = uint80(newMaxOracleAge);
        emit MaxOracleAgeUpdated(oldMaxOracleAge, newMaxOracleAge);
    }

    /// @notice Updates the maximum permitted move from a direction's last successful trade price.
    /// @dev Only the owner may update this safety parameter, and only while trading is paused.
    function setMaxPriceDeviationBps(uint256 newMaxPriceDeviationBps) external onlyOwner onlyPaused {
        if (newMaxPriceDeviationBps > BPS) {
            revert InvalidMaxPriceDeviationBps(newMaxPriceDeviationBps, BPS);
        }
        uint256 oldMaxPriceDeviationBps = maxPriceDeviationBps;
        // The bounds check above makes this narrowing conversion safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        maxPriceDeviationBps = uint16(newMaxPriceDeviationBps);
        emit MaxPriceDeviationBpsUpdated(oldMaxPriceDeviationBps, newMaxPriceDeviationBps);
    }

    /// @notice Accepts the current fresh oracle price as the new circuit-breaker anchor.
    /// @dev Required to recover from legitimate drift beyond the configured deviation limit.
    function resetPriceAnchor(bool baseToQuote) external onlyOwner onlyPaused {
        (uint256 price,) = _readOracle();
        _setPriceAnchor(baseToQuote, price);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert InvalidAddress();
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    /// @notice Requests the paused state and emits the resulting state even when already paused.
    function pause() external {
        if (msg.sender != owner && msg.sender != guardian) revert NotGuardianOrOwner();
        if (!paused) {
            paused = true;
        }
        emit PausedStateChanged(true);
    }

    /// @notice Requests the active state and emits the resulting state even when already active.
    /// @dev Oracle and anchor validation runs only for a paused-to-active transition.
    function unpause() external onlyOwner {
        if (paused) {
            (uint256 price,) = _readOracle();
            if (baseToQuotePriceAnchor == 0) {
                _setPriceAnchor(true, price);
            } else {
                _validatePriceDeviation(true, price);
            }
            if (quoteToBasePriceAnchor == 0) {
                _setPriceAnchor(false, price);
            } else {
                _validatePriceDeviation(false, price);
            }
            paused = false;
        }
        emit PausedStateChanged(false);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    function _validateTrade(address recipient, bytes32 customerId) internal view returns (address resolved) {
        if (!takerAllowed[msg.sender]) revert TakerNotAllowed(msg.sender);
        if (customerId == bytes32(0)) revert CustomerIdIsZero();
        resolved = resolveRecipient(recipient);
        if (!recipientAllowed[resolved]) revert RecipientNotAllowed(resolved);
        if (resolved == address(this)) revert InvalidAddress();
    }

    function _readOracle() internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = oracle.latestPrice();
        if (price == 0 || updatedAt == 0) revert InvalidPrice();
        if (updatedAt > block.timestamp) revert FutureOracleTimestamp(updatedAt, block.timestamp);
        if (block.timestamp - updatedAt > maxOracleAge) revert StaleOraclePrice(updatedAt, maxOracleAge);
    }

    function _readGuardedOracle(bool baseToQuote) internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = _readOracle();
        _validatePriceDeviation(baseToQuote, price);
    }

    function _readBoundOracle(
        bool baseToQuote,
        uint256 expectedPrice,
        uint256 priceToleranceBps,
        uint256 minimumUpdatedAt
    ) internal view returns (uint256 price, uint256 updatedAt) {
        if (priceToleranceBps > BPS) {
            revert InvalidOraclePriceToleranceBps(priceToleranceBps, BPS);
        }
        (price, updatedAt) = _readGuardedOracle(baseToQuote);
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

    function _validateDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
    }

    function _validatePriceDeviation(bool baseToQuote, uint256 price) internal view {
        uint256 anchor = priceAnchor(baseToQuote);
        if (anchor == 0) revert PriceAnchorNotInitialized(baseToQuote);

        uint256 deviation = price > anchor ? price - anchor : anchor - price;
        uint256 maximumDeviation = Math.mulDiv(anchor, maxPriceDeviationBps, BPS);
        if (deviation > maximumDeviation) {
            revert PriceDeviationExceeded(baseToQuote, price, anchor, maxPriceDeviationBps);
        }
    }

    function _setPriceAnchor(bool baseToQuote, uint256 newAnchor) internal {
        uint256 oldAnchor = priceAnchor(baseToQuote);
        if (oldAnchor == newAnchor) return;
        if (baseToQuote) {
            baseToQuotePriceAnchor = newAnchor;
        } else {
            quoteToBasePriceAnchor = newAnchor;
        }
        emit PriceAnchorUpdated(baseToQuote, oldAnchor, newAnchor);
    }

    function _roundingRouteKey(address taker, address resolvedRecipient, bytes32 customerId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(taker, resolvedRecipient, customerId));
    }

    function _quoteExactInputWithCredit(bool baseToQuote, uint256 amountIn, uint256 price, uint256 credit)
        internal
        view
        returns (uint256 amountOut, uint256 creditAfter)
    {
        uint256 inputValue = baseToQuote ? price : priceScale;
        uint256 outputValue = baseToQuote ? priceScale : price;
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

    function _quoteExactOutputWithCredit(bool baseToQuote, uint256 amountOut, uint256 price, uint256 credit)
        internal
        view
        returns (uint256 amountIn, uint256 creditAfter)
    {
        uint256 outputValue = baseToQuote ? priceScale : price;
        uint256 inputValue = baseToQuote ? price : priceScale;
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

    function _settle(
        bool baseToQuote,
        uint256 amountIn,
        uint256 amountOut,
        address recipient,
        address resolvedRecipient,
        bytes32 customerId,
        bytes32 tradeId
    ) internal {
        ITIP20 tokenIn = baseToQuote ? baseToken : quoteToken;
        ITIP20 tokenOut = baseToQuote ? quoteToken : baseToken;

        if (amountIn != 0) {
            _pullExact(tokenIn, msg.sender, amountIn, _memo("SWAP_IN", customerId, tradeId));
        }
        _pushExact(tokenOut, recipient, resolvedRecipient, amountOut, _memo("SWAP_OUT", customerId, tradeId));
    }

    function _pullExact(ITIP20 token, address from, uint256 amount, bytes32 memo) internal {
        uint256 beforeBalance = token.balanceOf(address(this));
        bool success = token.transferFromWithMemo(from, address(this), amount, memo);
        if (!success) revert TokenTransferFailed(address(token));
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 actual = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (actual != amount) revert ExactBalanceDeltaFailed(address(token), amount, actual);
    }

    function _pushExact(ITIP20 token, address recipient, address resolved, uint256 amount, bytes32 memo) internal {
        uint256 poolBefore = token.balanceOf(address(this));
        if (poolBefore < amount) revert InsufficientInventory(address(token), poolBefore, amount);
        uint256 recipientBefore = token.balanceOf(resolved);
        token.transferWithMemo(recipient, amount, memo);
        uint256 poolAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(resolved);

        uint256 poolDelta = poolBefore >= poolAfter ? poolBefore - poolAfter : 0;
        uint256 recipientDelta = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (poolDelta != amount) revert ExactBalanceDeltaFailed(address(token), amount, poolDelta);
        if (recipientDelta != amount) revert ExactBalanceDeltaFailed(address(token), amount, recipientDelta);
    }

    function _requirePairToken(address token) internal view {
        if (token != address(baseToken) && token != address(quoteToken)) revert UnsupportedToken(token);
    }

    function _memo(string memory action, bytes32 customerId, bytes32 tradeId) internal pure returns (bytes32) {
        return keccak256(abi.encode(action, customerId, tradeId));
    }
}

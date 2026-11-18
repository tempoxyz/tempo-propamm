// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IDirectPropAMM } from "./interfaces/IDirectPropAMM.sol";

/// @notice Owns one propAMM pool and splits the pool owner's authority between two keys.
/// @dev The keeper (a hot key) can only send a token's pool inventory to that token's Bridge liquidation address, fixed
/// at construction. Each liquidation address converts the token it receives and sends another pool token to its
/// destination address, the pool. The owner (an offline key) makes every other pool owner call through `execute` and
/// sets the keeper.
///
/// The pool is a `DirectPropAMM` (two tokens) or a `ManagedDirectPropAMM` (every token its pairs use). A pool has one
/// owner, so one controller serves all of its tokens: it calls only the owner calls both kinds share (`paused`,
/// `pause`, `withdraw`, `unpause`). A `DirectPropAMM` resolves a TIP-1022 liquidation address to its master and
/// requires the master's exact credit, so a virtual liquidation address works there. A `ManagedDirectPropAMM` pays
/// no virtual address, so the constructor refuses one for it (`VirtualLiquidationAddress`): the keeper's path would
/// otherwise revert on every rebalance of that token. It tells the kinds apart by `pairCount()`, which only a
/// `ManagedDirectPropAMM` answers, the one read it makes of the pool.
contract DirectPropAMMRebalanceController is Ownable2Step {
    /// @notice The most tokens one controller takes.
    uint256 public constant MAX_TOKENS = 16;
    /// @dev The TIP-1022 virtual-address layout: bytes 4 to 13 of the address all `0xFD`.
    uint80 private constant VIRTUAL_MAGIC = 0xFDFDFDFDFDFDFDFDFDFD;

    error InvalidAddress();
    error InvalidTokenCount(uint256 tokens, uint256 liquidationAddresses);
    /// @notice A TIP-1022 virtual liquidation address for a `ManagedDirectPropAMM`, which refuses to pay one.
    error VirtualLiquidationAddress(address token, address liquidationAddress);
    error DuplicateToken(address token);
    error UnsupportedToken(address token);
    error NotKeeper();
    error PoolPaused();
    error Disabled();

    event Executed(bytes data);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event LiquidationAddressSet(address indexed token, address indexed liquidationAddress);
    event Rebalanced(address indexed token, address indexed liquidationAddress, uint256 amount);

    IDirectPropAMM public immutable pool;
    /// @notice The Bridge liquidation address `rebalance` sends `token` to, or 0 for a token the controller doesn't
    /// rebalance. Fixed at construction; changing one means a new controller.
    mapping(address token => address liquidationAddress) public liquidationAddress;
    address[] internal _tokens;
    address public keeper;

    /// @param tokens_ The pool tokens the keeper may rebalance, each once: a `DirectPropAMM`'s base and quote, or any
    ///        of a `ManagedDirectPropAMM`'s pair tokens. 1 to `MAX_TOKENS`.
    /// @param liquidationAddresses_ One per token, in the same order: where `rebalance` sends that token. Nonzero, not
    ///        the pool or the controller. A TIP-1022 virtual address is accepted for a `DirectPropAMM`, which pays its
    ///        master, and refused for a `ManagedDirectPropAMM` (`VirtualLiquidationAddress`).
    constructor(
        IDirectPropAMM pool_,
        address initialOwner,
        // The keeper may start unset (zero), which disables rebalancing.
        // forge-lint: disable-next-line(missing-zero-check)
        address keeper_,
        address[] memory tokens_,
        address[] memory liquidationAddresses_
    ) Ownable(initialOwner) {
        if (address(pool_).code.length == 0) revert InvalidAddress();
        uint256 count = tokens_.length;
        if (count == 0 || count > MAX_TOKENS || liquidationAddresses_.length != count) {
            revert InvalidTokenCount(count, liquidationAddresses_.length);
        }
        pool = pool_;
        bool managed = _isManaged(address(pool_));
        // A check of the deployer's input, bounded by `MAX_TOKENS`: any bad entry stops the deployment.
        for (uint256 i; i < count; ++i) {
            address token = tokens_[i];
            address destination = liquidationAddresses_[i];
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (token == address(0)) revert InvalidAddress();
            if (destination == address(0) || destination == address(pool_) || destination == address(this)) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert InvalidAddress();
            }
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (managed && _isVirtual(destination)) revert VirtualLiquidationAddress(token, destination);
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (liquidationAddress[token] != address(0)) revert DuplicateToken(token);
            liquidationAddress[token] = destination;
            _tokens.push(token);
            emit LiquidationAddressSet(token, destination);
        }
        keeper = keeper_;
        emit KeeperUpdated(address(0), keeper_);
    }

    /// @notice The tokens the keeper may rebalance, in constructor order.
    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    /// @notice Sends `amount` of `token` from the pool to its liquidation address.
    /// @dev Pauses the pool, withdraws and unpauses it in one transaction. Reverts on a paused pool, so it never undoes
    /// a pause: the guardian's `pause` is the keeper's emergency stop (a `ManagedDirectPropAMM`'s `closePair` is not,
    /// since a withdrawal changes no pair). A `DirectPropAMM` withdraws only while paused, and its `unpause` re-checks
    /// its oracle and anchors, so a stale or deviated oracle reverts the rebalance. A `ManagedDirectPropAMM` withdraws
    /// paused or not and its `unpause` checks no oracle, so the same cycle succeeds whatever its pairs' oracles say.
    function rebalance(address token, uint256 amount) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (pool.paused()) revert PoolPaused();
        address destination = liquidationAddress[token];
        if (destination == address(0)) revert UnsupportedToken(token);

        emit Rebalanced(token, destination, amount);
        pool.pause();
        pool.withdraw(token, destination, amount, bytes32(0));
        pool.unpause();
    }

    /// @notice Calls the pool as its owner with `data`: for example `setTakerAllowed` or a paused `withdraw` on a
    /// `DirectPropAMM`, or `setMembers` on a pair's home list, `setPairAccess` or `withdraw` on a `ManagedDirectPropAMM`.
    function execute(bytes calldata data) external onlyOwner {
        emit Executed(data);
        Address.functionCall(address(pool), data);
    }

    /// @notice Always reverts: without an owner, nobody could withdraw inventory or revoke the keeper.
    function renounceOwnership() public pure override {
        revert Disabled();
    }

    /// @notice Sets the keeper; the zero address disables rebalancing.
    // forge-lint: disable-next-line(missing-zero-check)
    function setKeeper(address newKeeper) external onlyOwner {
        address oldKeeper = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(oldKeeper, newKeeper);
    }

    /// @dev Whether `pool_` is a `ManagedDirectPropAMM`: it answers `pairCount()` with one word, which a
    /// `DirectPropAMM` (no such function, no fallback) never does.
    function _isManaged(address pool_) private view returns (bool) {
        // A probe of the deployer's pool, once, at construction.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory answer) = pool_.staticcall(abi.encodeWithSignature("pairCount()"));
        return ok && answer.length == 32;
    }

    /// @dev Whether `account` has the TIP-1022 virtual-address layout. The layout alone identifies one.
    function _isVirtual(address account) private pure returns (bool) {
        return ((uint160(account) >> 48) & type(uint80).max) == VIRTUAL_MAGIC;
    }
}

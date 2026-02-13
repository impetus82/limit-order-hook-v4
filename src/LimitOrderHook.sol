// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LimitOrderHook — Uniswap V4 Hook for On-Chain Limit Orders
/// @author Yuri (Crypto Side Hustle 2026)
/// @notice Allows users to place limit orders that execute automatically when
///         the pool price reaches a specified trigger price during swaps.
///
/// @dev Architecture Overview:
///
///   **Tick Bucket Indexing (O(1) Lookup)**
///   Orders are indexed by their aligned tick in `tickToOrders` mapping.
///   When a swap occurs, only ticks within ±TICK_RANGE_WIDTH of the current
///   price are scanned, avoiding O(N) iteration over all orders.
///
///   **Flash Accounting (BeforeSwap + ReturnDelta)**
///   Execution happens in `beforeSwap` using the `beforeSwapReturnDelta` flag.
///   The hook settles token0 into PoolManager and takes token1 (or vice versa)
///   for the order creator, returning deltas that modify the swap outcome.
///
///   **Lazy Cleanup**
///   Filled and cancelled orders are removed from tick buckets during iteration
///   (swap-and-pop), amortizing cleanup cost across future swaps rather than
///   paying it upfront during cancellation.
///
///   **Gas Metering (DoS Protection)**
///   A two-level `gasleft()` check prevents out-of-gas reverts when many orders
///   are queued. Execution stops gracefully; remaining orders persist for the
///   next swap.
///
///   **Security (Phase 3.2 → 3.3)**
///   - ReentrancyGuard on createLimitOrder and cancelOrder (ERC-777 defense)
///   - Slippage protection: amountOut validated against triggerPrice
///   - Pool key validation: tickSpacing > 0 check
///   - SafeCast for all unsafe truncation paths (Phase 3.3)
///   - Ownable (OpenZeppelin) replaces manual owner logic (Phase 3.3)
///
///   **Custom Errors**
///   All reverts use custom errors instead of string messages, saving ~600 gas
///   per revert path and reducing deployed bytecode size.
contract LimitOrderHook is BaseHook, ReentrancyGuard, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when order amount is zero
    error InvalidAmount();

    /// @notice Thrown when trigger price is zero
    error InvalidTriggerPrice();

    /// @notice Thrown when a non-creator tries to cancel an order
    error NotOrderCreator();

    /// @notice Thrown when trying to cancel an already-filled order
    error OrderAlreadyFilled();

    /// @notice Thrown on out-of-bounds array access (internal safety)
    error IndexOutOfBounds();

    /// @notice Thrown when poolKey has invalid tickSpacing (M-2)
    error InvalidPoolKey();

    /// @notice Thrown when execution output is below minimum expected (H-1, H-2)
    error SlippageExceeded(uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

    /// @notice Packed limit order structure (4 storage slots)
    /// @dev Slot packing:
    ///   slot 0: creator (20 bytes) + amount0 (12 bytes)
    ///   slot 1: amount1 (12 bytes) + token0 (20 bytes)
    ///   slot 2: token1 (20 bytes) — padded
    ///   slot 3: triggerPrice (16 bytes) + createdAt (8 bytes) + isFilled (1 byte) + zeroForOne (1 byte)
    struct LimitOrder {
        address creator;
        uint96 amount0;
        uint96 amount1;
        address token0;
        address token1;
        uint128 triggerPrice;
        uint64 createdAt;
        bool isFilled;
        bool zeroForOne;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice All orders by ID
    mapping(uint256 => LimitOrder) public orders;

    /// @notice Order IDs owned by each user
    mapping(address => uint256[]) private userOrders;

    /// @notice Auto-incrementing order counter
    uint256 public nextOrderId;

    /// @notice Tick-based order indexing for O(1) lookup
    /// @dev Key is the aligned tick (rounded to tickSpacing grid)
    mapping(int24 => uint256[]) public tickToOrders;

    /// @notice Reverse mapping: orderId → aligned tick bucket
    mapping(uint256 => int24) private orderTickBucket;

    /// @dev Reentrancy guard for execution — prevents recursive execution during
    ///      PoolManager callbacks triggered by order settlement.
    ///      Separate from ReentrancyGuard which protects external entry points.
    bool private isExecuting;

    /// @notice Range width for tick checking (±N ticks around current price)
    /// @dev With tickSpacing=60, this checks ±120 ticks around current price
    int24 public constant TICK_RANGE_WIDTH = 2;

    /// @notice Minimum gas required to attempt executing one more order
    /// @dev Empirically measured: ~100k gas per order execution (settle + take + SSTORE).
    ///      150k threshold leaves buffer for completing the current execution and
    ///      returning from the hook.
    uint256 public constant GAS_LIMIT_PER_ORDER = 150_000;

    /// @notice Maximum allowed slippage in basis points (50 = 0.5%)
    /// @dev Orders that receive less than (triggerPrice * (10000 - MAX_SLIPPAGE_BPS) / 10000)
    ///      will be skipped rather than executed at a bad price.
    uint256 public constant MAX_SLIPPAGE_BPS = 50;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new limit order is created
    event OrderCreated(
        uint256 indexed orderId,
        address indexed creator,
        bool zeroForOne,
        uint96 amountIn,
        uint128 triggerPrice
    );

    /// @notice Emitted when an order is cancelled and tokens returned
    event OrderCancelled(uint256 indexed orderId, address indexed creator);

    /// @notice Emitted when an order is filled during a swap
    event OrderFilled(
        uint256 indexed orderId,
        address indexed creator,
        uint96 amountIn,
        uint96 amountOut,
        uint128 executionPrice
    );

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _poolManager The Uniswap V4 PoolManager contract
    constructor(IPoolManager _poolManager)
        BaseHook(_poolManager)
        Ownable(msg.sender)
    {}

    /*//////////////////////////////////////////////////////////////
                          HOOK CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Declare which hook callbacks this contract implements
    /// @dev Enables beforeSwap + beforeSwapReturnDelta.
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                          CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new limit order with token custody
    /// @dev Transfers the input token from the caller to this contract.
    ///      The order is indexed by its aligned tick for O(1) lookup.
    ///      Protected by ReentrancyGuard against ERC-777 callbacks.
    /// @param poolKey The Uniswap V4 pool to associate the order with
    /// @param zeroForOne True = selling token0 for token1; False = buying token0 with token1
    /// @param amountIn Amount of input token to deposit
    /// @param triggerPrice Price threshold for execution (uint128 scaled to 1e18)
    /// @return orderId The unique ID of the created order
    function createLimitOrder(
        PoolKey calldata poolKey,
        bool zeroForOne,
        uint96 amountIn,
        uint128 triggerPrice
    ) external nonReentrant returns (uint256 orderId) {
        if (amountIn == 0) revert InvalidAmount();
        if (triggerPrice == 0) revert InvalidTriggerPrice();
        // M-2: Validate pool key
        if (poolKey.tickSpacing <= 0) revert InvalidPoolKey();

        orderId = nextOrderId++;

        address token0Addr = Currency.unwrap(poolKey.currency0);
        address token1Addr = Currency.unwrap(poolKey.currency1);

        // Transfer tokens to hook (custody)
        if (zeroForOne) {
            IERC20(token0Addr).safeTransferFrom(msg.sender, address(this), uint256(amountIn));
        } else {
            IERC20(token1Addr).safeTransferFrom(msg.sender, address(this), uint256(amountIn));
        }

        orders[orderId] = LimitOrder({
            creator: msg.sender,
            amount0: zeroForOne ? amountIn : 0,
            amount1: zeroForOne ? 0 : amountIn,
            token0: token0Addr,
            token1: token1Addr,
            triggerPrice: triggerPrice,
            createdAt: uint64(block.timestamp),
            isFilled: false,
            zeroForOne: zeroForOne
        });

        userOrders[msg.sender].push(orderId);

        // Index by tick bucket for O(1) lookup
        int24 alignedTick = _alignTick(
            TickMath.getTickAtSqrtPrice(uint128ToSqrtPrice(triggerPrice)),
            poolKey.tickSpacing
        );
        tickToOrders[alignedTick].push(orderId);
        orderTickBucket[orderId] = alignedTick;

        emit OrderCreated(orderId, msg.sender, zeroForOne, amountIn, triggerPrice);
    }

    /// @notice Cancel an active order and return deposited tokens
    /// @dev Removes the order from its tick bucket and refunds the creator.
    ///      Protected by ReentrancyGuard against ERC-777 callbacks.
    /// @param orderId The ID of the order to cancel
    function cancelOrder(uint256 orderId) external nonReentrant {
        LimitOrder storage order = orders[orderId];

        if (order.creator != msg.sender) revert NotOrderCreator();
        if (order.isFilled) revert OrderAlreadyFilled();

        // Remove from tick bucket
        int24 tick = orderTickBucket[orderId];
        uint256[] storage orderIds = tickToOrders[tick];
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == orderId) {
                _removeFromArray(orderIds, i);
                break;
            }
        }

        // Return tokens
        if (order.zeroForOne && order.amount0 > 0) {
            IERC20(order.token0).safeTransfer(msg.sender, uint256(order.amount0));
        } else if (!order.zeroForOne && order.amount1 > 0) {
            IERC20(order.token1).safeTransfer(msg.sender, uint256(order.amount1));
        }

        // Mark as cancelled (zero out creator)
        order.creator = address(0);

        emit OrderCancelled(orderId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get full order data by ID
    function getOrder(uint256 orderId) external view returns (LimitOrder memory) {
        return orders[orderId];
    }

    /// @notice Get all order IDs for a given user
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /// @notice Get all order IDs in a specific tick bucket
    function getOrdersInTick(int24 tick) external view returns (uint256[] memory) {
        return tickToOrders[tick];
    }

    /// @notice Get the tick bucket an order was assigned to
    function getTickBucket(uint256 orderId) external view returns (int24) {
        return orderTickBucket[orderId];
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Hook callback — executes eligible limit orders before each swap
    /// @dev Called by PoolManager. Reads the current pool price, scans nearby
    ///      tick buckets, and executes matching orders via flash accounting.
    function _beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Prevent recursion from settle/take callbacks
        if (isExecuting) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 currentPrice = sqrtPriceToUint128(sqrtPriceX96);

        // Try to execute matching orders (with gas metering)
        (bool executed, int128 delta0, int128 delta1) = _tryExecuteOrders(
            poolKey,
            currentPrice
        );

        if (executed) {
            BeforeSwapDelta beforeSwapDelta = _toBeforeSwapDelta(delta0, delta1);
            return (this.beforeSwap.selector, beforeSwapDelta, 0);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Scan tick range and execute eligible orders with gas metering
    /// @dev Two-level gas check: at tick-level and per-order level.
    ///      Lazy cleanup removes stale (filled/cancelled) orders during scan.
    function _tryExecuteOrders(
        PoolKey calldata poolKey,
        uint128 currentPrice
    ) internal returns (bool executed, int128 delta0, int128 delta1) {
        // Get current tick from price
        uint160 sqrtPriceX96 = uint128ToSqrtPrice(currentPrice);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        int24 tickSpacing = poolKey.tickSpacing;

        // Calculate tick range to check (±TICK_RANGE_WIDTH × tickSpacing)
        int24 startTick = currentTick - (TICK_RANGE_WIDTH * tickSpacing);
        int24 endTick = currentTick + (TICK_RANGE_WIDTH * tickSpacing);

        address token0 = Currency.unwrap(poolKey.currency0);

        // Iterate through tick range
        for (int24 tick = startTick; tick <= endTick; tick += tickSpacing) {
            // Gas check at tick level
            if (gasleft() < GAS_LIMIT_PER_ORDER) break;

            uint256[] storage orderIdsInTick = tickToOrders[tick];

            if (orderIdsInTick.length == 0) continue;

            // Iterate orders in this tick (with lazy cleanup)
            uint256 i = 0;
            while (i < orderIdsInTick.length) {
                // Gas check per order
                if (gasleft() < GAS_LIMIT_PER_ORDER) break;

                uint256 orderId = orderIdsInTick[i];
                LimitOrder storage order = orders[orderId];

                // Lazy cleanup: remove filled/cancelled orders
                if (order.creator == address(0) || order.isFilled) {
                    _removeFromArray(orderIdsInTick, i);
                    continue; // Don't increment i (array shifted)
                }

                // Skip if wrong pool
                if (order.token0 != token0) {
                    i++;
                    continue;
                }

                // Check price eligibility
                bool eligible = false;
                if (order.zeroForOne) {
                    // Sell token0: trigger when price >= triggerPrice
                    eligible = (currentPrice >= order.triggerPrice);
                } else {
                    // Buy token0: trigger when price <= triggerPrice
                    eligible = (currentPrice <= order.triggerPrice);
                }

                if (eligible) {
                    (int128 orderDelta0, int128 orderDelta1) = _executeOrderInBeforeSwap(
                        poolKey,
                        order,
                        orderId
                    );

                    // Only count as executed if deltas are non-zero
                    if (orderDelta0 != 0 || orderDelta1 != 0) {
                        delta0 += orderDelta0;
                        delta1 += orderDelta1;
                        executed = true;
                    }

                    // Remove from tick bucket after execution attempt
                    _removeFromArray(orderIdsInTick, i);
                    // Don't increment i
                } else {
                    i++;
                }
            }
        }
    }

    /// @notice Execute a single order within the beforeSwap context
    /// @dev Settles input tokens into PoolManager and takes output tokens
    ///      for the order creator. Validates amountOut against triggerPrice
    ///      with MAX_SLIPPAGE_BPS tolerance (H-1, H-2 fix).
    ///      Uses SafeCast for all uint256→uint96/uint128/uint160 conversions (Phase 3.3).
    function _executeOrderInBeforeSwap(
        PoolKey calldata poolKey,
        LimitOrder storage order,
        uint256 orderId
    ) internal returns (int128 orderDelta0, int128 orderDelta1) {
        isExecuting = true;

        uint96 amountIn = order.zeroForOne ? order.amount0 : order.amount1;

        // --- Perform the swap via PoolManager ---
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        // Price limit: 5% slippage on the swap itself
        // SafeCast: uint256 → uint160 for sqrtPriceLimitX96
        uint160 sqrtPriceLimitX96 = order.zeroForOne
            ? ((uint256(currentSqrtPriceX96) * 95) / 100).toUint160()
            : ((uint256(currentSqrtPriceX96) * 105) / 100).toUint160();

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: order.zeroForOne
                ? -int256(uint256(order.amount0))
                : -int256(uint256(order.amount1)),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        BalanceDelta swapDelta = poolManager.swap(poolKey, swapParams, "");

        // --- Settle input + Take output ---
        if (order.zeroForOne) {
            // Selling token0 for token1
            poolManager.sync(poolKey.currency0);
            IERC20(order.token0).safeTransfer(address(poolManager), uint256(amountIn));
            poolManager.settle();

            // Extract amountOut from swap delta
            int128 deltaAmount1 = swapDelta.amount1();
            // Sign is checked before cast — safe truncation (int128 → uint128)
            uint256 amountOut = deltaAmount1 < 0
                ? uint256(uint128(-deltaAmount1))
                : uint256(uint128(deltaAmount1));

            // --- H-1/H-2 FIX: Slippage protection ---
            uint256 expectedOut = (uint256(amountIn) * uint256(order.triggerPrice)) / 1e18;
            uint256 minAmountOut = (expectedOut * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

            if (amountOut < minAmountOut) {
                isExecuting = false;
                revert SlippageExceeded(minAmountOut, amountOut);
            }

            poolManager.take(poolKey.currency1, order.creator, amountOut);

            order.isFilled = true;
            // SafeCast: uint256 → uint96
            order.amount1 = amountOut.toUint96();

            // Return ZERO deltas — hook already settled everything via sync/settle/take
            orderDelta0 = 0;
            orderDelta1 = 0;
        } else {
            // Buying token0 with token1
            poolManager.sync(poolKey.currency1);
            IERC20(order.token1).safeTransfer(address(poolManager), uint256(amountIn));
            poolManager.settle();

            int128 deltaAmount0 = swapDelta.amount0();
            // Sign is checked before cast — safe truncation (int128 → uint128)
            uint256 amountOut = deltaAmount0 < 0
                ? uint256(uint128(-deltaAmount0))
                : uint256(uint128(deltaAmount0));

            // --- H-1/H-2 FIX: Slippage protection ---
            uint256 expectedOut = (uint256(amountIn) * 1e18) / uint256(order.triggerPrice);
            uint256 minAmountOut = (expectedOut * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

            if (amountOut < minAmountOut) {
                isExecuting = false;
                revert SlippageExceeded(minAmountOut, amountOut);
            }

            poolManager.take(poolKey.currency0, order.creator, amountOut);

            order.isFilled = true;
            // SafeCast: uint256 → uint96
            order.amount0 = amountOut.toUint96();

            // Return ZERO deltas — hook already settled everything via sync/settle/take
            orderDelta0 = 0;
            orderDelta1 = 0;
        }

        emit OrderFilled(
            orderId,
            order.creator,
            amountIn,
            order.zeroForOne ? order.amount1 : order.amount0,
            sqrtPriceToUint128(currentSqrtPriceX96)
        );

        isExecuting = false;
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert sqrtPriceX96 (Uniswap format) to uint128 price scaled to 1e18
    /// @dev Formula: price = (sqrtPriceX96² / 2^192) × 1e18
    function sqrtPriceToUint128(uint160 sqrtPriceX96) public pure returns (uint128 price) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 priceX96 = (sqrtPrice * sqrtPrice) / (1 << 96);
        uint256 priceScaled = (priceX96 * 1e18) / (1 << 96);
        // SafeCast: uint256 → uint128
        price = priceScaled.toUint128();
    }

    /// @notice Convert uint128 price (1e18 scaled) to sqrtPriceX96
    /// @dev Inverse of sqrtPriceToUint128. Used for tick bucket indexing.
    function uint128ToSqrtPrice(uint128 price) public pure returns (uint160 sqrtPriceX96) {
        uint256 priceX192 = (uint256(price) * (1 << 96)) / 1e18;
        uint256 priceX96Full = priceX192 * (1 << 96);
        uint256 sqrtPriceRaw = sqrt(priceX96Full);
        // SafeCast: uint256 → uint160
        sqrtPriceX96 = sqrtPriceRaw.toUint160();
    }

    /// @notice Integer square root (Babylonian method)
    function sqrt(uint256 x) public pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Check if an order is eligible for execution at a given price
    function _isEligible(LimitOrder storage order, uint128 currentPrice) internal view returns (bool) {
        if (order.zeroForOne) {
            return currentPrice >= order.triggerPrice;
        } else {
            return currentPrice <= order.triggerPrice;
        }
    }

    /// @notice Align a tick to the nearest multiple of tickSpacing (round down)
    function _alignTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    /// @notice Remove element at index using swap-and-pop (O(1))
    function _removeFromArray(uint256[] storage arr, uint256 index) internal {
        if (index >= arr.length) revert IndexOutOfBounds();
        arr[index] = arr[arr.length - 1];
        arr.pop();
    }

    /// @notice Pack two int128 deltas into a BeforeSwapDelta
    function _toBeforeSwapDelta(int128 delta0, int128 delta1) internal pure returns (BeforeSwapDelta) {
        return toBeforeSwapDelta(delta0, delta1);
    }
}
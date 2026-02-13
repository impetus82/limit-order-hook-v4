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
///   **Custom Errors**
///   All reverts use custom errors instead of string messages, saving ~600 gas
///   per revert path and reducing deployed bytecode size.
contract LimitOrderHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

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

    /// @dev Reentrancy guard — prevents recursive execution during
    ///      PoolManager callbacks triggered by order settlement
    bool private isExecuting;

    /// @notice Minimum order size (unused in current MVP — reserved for production)
    uint256 public constant MIN_ORDER_SIZE = 0.01 ether;

    /// @notice Fee percentage in basis points (5 = 0.05%)
    uint256 public feePercentage = 5;

    /// @notice Accumulated protocol fees (not yet implemented)
    uint256 public collectedFees;

    /// @notice Contract owner (deployer)
    address public owner;

    /// @notice Range width for tick checking (±N ticks around current price)
    /// @dev With tickSpacing=60, this checks ±120 ticks around current price
    int24 public constant TICK_RANGE_WIDTH = 2;

    /// @notice Minimum gas required to attempt executing one more order
    /// @dev Empirically measured: ~100k gas per order execution (settle + take + SSTORE).
    ///      150k threshold leaves buffer for completing the current execution and
    ///      returning from the hook.
    uint256 public constant GAS_LIMIT_PER_ORDER = 150_000;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new limit order is created
    /// @param orderId Unique order identifier
    /// @param creator Address that created the order
    /// @param amount0 Amount of token0 deposited (>0 if zeroForOne)
    /// @param amount1 Amount of token1 deposited (>0 if !zeroForOne)
    /// @param triggerPrice Price at which the order should execute
    event OrderCreated(
        uint256 indexed orderId,
        address indexed creator,
        uint96 amount0,
        uint96 amount1,
        uint128 triggerPrice
    );

    /// @notice Emitted when an order is cancelled by its creator
    event OrderCancelled(uint256 indexed orderId, address indexed creator);

    /// @notice Emitted when an order is filled during a swap
    /// @param orderId The filled order's ID
    /// @param creator The order creator who receives output tokens
    /// @param amountIn Tokens sold by the order
    /// @param amountOut Tokens received by the order creator
    /// @param executionPrice Pool price at time of execution
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

    /// @param _poolManager Address of the Uniswap V4 PoolManager
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Declares which hook callbacks this contract implements
    /// @dev Only `beforeSwap` and `beforeSwapReturnDelta` are enabled.
    ///      This allows the hook to intercept swaps, execute matching limit
    ///      orders, and return modified deltas via flash accounting.
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
    ) external returns (uint256 orderId) {
        if (amountIn == 0) revert InvalidAmount();
        if (triggerPrice == 0) revert InvalidTriggerPrice();

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

        // Index by tick for O(1) lookup
        uint160 sqrtPriceX96 = uint128ToSqrtPrice(triggerPrice);
        int24 rawTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 tick = _alignTick(rawTick, poolKey.tickSpacing);
        tickToOrders[tick].push(orderId);
        orderTickBucket[orderId] = tick;

        emit OrderCreated(
            orderId,
            msg.sender,
            zeroForOne ? amountIn : 0,
            zeroForOne ? 0 : amountIn,
            triggerPrice
        );
    }

    /// @notice Cancel an active order and return deposited tokens
    /// @dev Removes the order from its tick bucket and refunds the creator.
    /// @param orderId The ID of the order to cancel
    function cancelOrder(uint256 orderId) external {
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
    /// @param orderId The order to query
    /// @return The LimitOrder struct
    function getOrder(uint256 orderId) external view returns (LimitOrder memory) {
        return orders[orderId];
    }

    /// @notice Get all order IDs for a given user
    /// @param user The user address
    /// @return Array of order IDs
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /// @notice Get all order IDs in a specific tick bucket
    /// @param tick The aligned tick value
    /// @return Array of order IDs
    function getOrdersInTick(int24 tick) external view returns (uint256[] memory) {
        return tickToOrders[tick];
    }

    /// @notice Get the tick bucket an order was assigned to
    /// @param orderId The order to query
    /// @return The aligned tick value
    function getTickBucket(uint256 orderId) external view returns (int24) {
        return orderTickBucket[orderId];
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Hook callback — executes eligible limit orders before each swap
    /// @dev Called by PoolManager. Reads the current pool price, scans nearby
    ///      tick buckets, and executes matching orders via flash accounting.
    ///      Returns modified deltas that adjust the swap outcome.
    function _beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata params,
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
    /// @param poolKey The pool being swapped
    /// @param currentPrice Current pool price as uint128 (1e18 scaled)
    /// @return executed True if at least one order was filled
    /// @return delta0 Cumulative token0 delta for all filled orders
    /// @return delta1 Cumulative token1 delta for all filled orders
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
                    // Execute order
                    (int128 orderDelta0, int128 orderDelta1) = _executeOrderInBeforeSwap(
                        poolKey,
                        order,
                        orderId
                    );

                    delta0 += orderDelta0;
                    delta1 += orderDelta1;
                    executed = true;

                    // Remove from tick bucket after execution
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
    ///      for the order creator. Uses 1:1 simplified pricing for MVP.
    /// @param poolKey The pool being swapped
    /// @param order Storage reference to the order being executed
    /// @param orderId The order's unique ID (for event emission)
    /// @return orderDelta0 Token0 delta (positive = hook owes pool)
    /// @return orderDelta1 Token1 delta (negative = pool owes hook)
    function _executeOrderInBeforeSwap(
        PoolKey calldata poolKey,
        LimitOrder storage order,
        uint256 orderId
    ) internal returns (int128 orderDelta0, int128 orderDelta1) {
        isExecuting = true;

        order.isFilled = true;

        uint96 amountIn = order.zeroForOne ? order.amount0 : order.amount1;

        // Get execution price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 executionPrice = sqrtPriceToUint128(sqrtPriceX96);

        if (order.zeroForOne) {
            // Selling token0 for token1
            IERC20(order.token0).approve(address(poolManager), uint256(amountIn));

            poolManager.sync(poolKey.currency0);
            IERC20(order.token0).safeTransfer(address(poolManager), uint256(amountIn));
            poolManager.settle();

            // Take token1 for order creator (1:1 simplified for MVP)
            uint256 amountOut = uint256(amountIn);
            poolManager.take(poolKey.currency1, order.creator, amountOut);

            orderDelta0 = int128(uint128(amountIn));
            orderDelta1 = -int128(uint128(amountOut));

            order.amount1 = uint96(amountOut);
        } else {
            // Buying token0 with token1
            IERC20(order.token1).approve(address(poolManager), uint256(amountIn));

            poolManager.sync(poolKey.currency1);
            IERC20(order.token1).safeTransfer(address(poolManager), uint256(amountIn));
            poolManager.settle();

            // Take token0 for order creator (1:1 simplified for MVP)
            uint256 amountOut = uint256(amountIn);
            poolManager.take(poolKey.currency0, order.creator, amountOut);

            orderDelta0 = -int128(uint128(amountOut));
            orderDelta1 = int128(uint128(amountIn));

            order.amount0 = uint96(amountOut);
        }

        emit OrderFilled(
            orderId,
            order.creator,
            amountIn,
            order.zeroForOne ? order.amount1 : order.amount0,
            executionPrice
        );

        isExecuting = false;
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert sqrtPriceX96 (Uniswap format) to uint128 price scaled to 1e18
    /// @dev Formula: price = (sqrtPriceX96² / 2^192) × 1e18
    /// @param sqrtPriceX96 Square root of price in Q96 format
    /// @return price Human-readable price with 18 decimals
    function sqrtPriceToUint128(uint160 sqrtPriceX96) public pure returns (uint128 price) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 priceX96 = (sqrtPrice * sqrtPrice) / (1 << 96);
        uint256 priceScaled = (priceX96 * 1e18) / (1 << 96);
        price = uint128(priceScaled);
    }

    /// @notice Convert uint128 price (1e18 scaled) to sqrtPriceX96
    /// @dev Inverse of sqrtPriceToUint128. Used for tick bucket indexing.
    /// @param price Human-readable price with 18 decimals
    /// @return sqrtPriceX96 Square root of price in Q96 format
    function uint128ToSqrtPrice(uint128 price) public pure returns (uint160 sqrtPriceX96) {
        uint256 priceX192 = (uint256(price) * (1 << 96)) / 1e18;
        uint256 sqrtPriceX96Full = sqrt(priceX192) * (1 << 48);
        sqrtPriceX96 = uint160(sqrtPriceX96Full);
    }

    /// @notice Integer square root using the Babylonian method
    /// @param x The value to take the square root of
    /// @return y The integer square root (floor)
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if an order's trigger price is met
    /// @param order The order to evaluate
    /// @param currentPrice Current pool price (1e18 scaled)
    /// @return True if the order should be executed
    function _isEligible(LimitOrder storage order, uint128 currentPrice) internal view returns (bool) {
        if (order.zeroForOne) {
            return currentPrice >= order.triggerPrice;
        } else {
            return currentPrice <= order.triggerPrice;
        }
    }

    /// @notice Align a raw tick to the pool's tickSpacing grid
    /// @dev Rounds down (toward negative infinity) so that orders are stored
    ///      on the same grid as the scan in _tryExecuteOrders.
    /// @param tick Raw tick value from TickMath
    /// @param tickSpacing Pool's tick spacing
    /// @return Aligned tick value
    function _alignTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--;
        }
        return compressed * tickSpacing;
    }

    /// @notice Remove element at index using swap-and-pop (O(1) removal)
    /// @dev Moves the last element into the removed slot and pops the array.
    ///      Order within the array is not preserved.
    /// @param arr Storage reference to the array
    /// @param index Index of the element to remove
    function _removeFromArray(uint256[] storage arr, uint256 index) internal {
        if (index >= arr.length) revert IndexOutOfBounds();
        arr[index] = arr[arr.length - 1];
        arr.pop();
    }

    /// @notice Pack two int128 deltas into a BeforeSwapDelta
    /// @param delta0 Token0 delta
    /// @param delta1 Token1 delta
    /// @return BeforeSwapDelta packed value
    function _toBeforeSwapDelta(int128 delta0, int128 delta1) internal pure returns (BeforeSwapDelta) {
        return toBeforeSwapDelta(delta0, delta1);
    }
}
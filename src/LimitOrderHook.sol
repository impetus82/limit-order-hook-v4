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

/// @title LimitOrderHook - Uniswap V4 Hook for On-Chain Limit Orders
/// @author Yuri (Crypto Side Hustle 2026)
/// @notice Allows users to place limit orders that execute automatically when
///         the pool price reaches a specified trigger price during swaps.
///
/// @dev Architecture Overview (Phase 3.12 - Dynamic Tick Tracking):
///
///   **Sorted Linked List of Active Ticks**
///   Instead of blindly scanning MAX_TICK_SCAN consecutive tick buckets (which
///   wastes gas on empty ticks and fails for large price movements), we maintain
///   a sorted doubly-linked list of only those ticks that actually contain orders.
///
///   Storage layout:
///     - `nextActiveTick[tick]` → next higher active tick (or SENTINEL_MAX)
///     - `prevActiveTick[tick]` → next lower active tick (or SENTINEL_MIN)
///     - Two sentinel values anchor the list boundaries
///
///   This gives us:
///     - O(1) insertion: given the sorted position (found via binary hint or walk)
///     - O(1) removal: unlink node when its bucket becomes empty
///     - O(K) scan during afterSwap: iterate only K populated ticks, skipping
///       all empty space regardless of how far the price has moved
///
///   **afterSwap Execution**
///   Execution happens in `afterSwap`, AFTER the user's swap has moved the price.
///   The hook reads the post-swap tick, then walks the linked list from the
///   current tick in the appropriate direction to find and execute eligible orders.
///
///   **Gas Metering (DoS Protection)**
///   A `gasleft()` check prevents out-of-gas reverts when many orders are queued.
///   Execution stops gracefully; remaining orders persist for the next swap.
///
///   **Security**
///   - ReentrancyGuard on createLimitOrder and cancelOrder (ERC-777 defense)
///   - Slippage protection: amountOut validated against triggerPrice
///   - Pool key validation: tickSpacing > 0 check
///   - SafeCast for all unsafe truncation paths
///   - Ownable (OpenZeppelin) for admin functions
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

    /// @notice Reverse mapping: orderId -> aligned tick bucket
    mapping(uint256 => int24) private orderTickBucket;

    /*//////////////////////////////////////////////////////////////
                    SORTED LINKED LIST OF ACTIVE TICKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sentinel values for linked list boundaries
    /// @dev These are beyond Uniswap's tick range (±887272) and serve as
    ///      permanent anchors. SENTINEL_MIN.next = first real tick,
    ///      SENTINEL_MAX.prev = last real tick.
    int24 public constant SENTINEL_MIN = type(int24).min; // -8388608
    int24 public constant SENTINEL_MAX = type(int24).max; //  8388607

    /// @notice Forward pointer: tick -> next higher active tick
    mapping(int24 => int24) public nextActiveTick;

    /// @notice Backward pointer: tick -> next lower active tick
    mapping(int24 => int24) public prevActiveTick;

    /// @notice Quick check: does this tick have orders?
    /// @dev True when tickToOrders[tick].length > 0 AND tick is linked.
    ///      Prevents double-insertion and enables O(1) removal check.
    mapping(int24 => bool) public isActiveTick;

    /// @dev Reentrancy guard for execution
    bool private isExecuting;

    /// @notice Maximum number of *populated* ticks to process per swap
    /// @dev Unlike the old MAX_TICK_SCAN which counted empty ticks too,
    ///      this counts only ticks that actually have orders. 100 populated
    ///      ticks is generous — most swaps will encounter 1-5.
    int24 public constant MAX_ACTIVE_TICK_SCAN = 100;

    /// @notice Minimum gas required to attempt executing one more order
    uint256 public constant GAS_LIMIT_PER_ORDER = 150_000;

    /// @notice Maximum allowed slippage in basis points (50 = 0.5%)
    uint256 public constant MAX_SLIPPAGE_BPS = 50;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event OrderCreated(
        uint256 indexed orderId,
        address indexed creator,
        bool zeroForOne,
        uint96 amountIn,
        uint128 triggerPrice
    );

    event OrderCancelled(uint256 indexed orderId, address indexed creator);

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
    /// @param _initialOwner The address that will own this contract (EOA deployer)
    constructor(IPoolManager _poolManager, address _initialOwner)
        BaseHook(_poolManager)
        Ownable(_initialOwner)
    {
        // Initialize sentinel linked list: SENTINEL_MIN <-> SENTINEL_MAX
        nextActiveTick[SENTINEL_MIN] = SENTINEL_MAX;
        prevActiveTick[SENTINEL_MAX] = SENTINEL_MIN;
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Declare which hook callbacks this contract implements
    /// @dev Phase 3.10: afterSwap only (no beforeSwap, no returnDelta)
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
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
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
    ///      The order is indexed by its aligned tick and inserted into the
    ///      sorted active tick linked list for efficient scanning.
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

        // Index by tick bucket
        int24 alignedTick = _alignTick(
            TickMath.getTickAtSqrtPrice(uint128ToSqrtPrice(triggerPrice)),
            poolKey.tickSpacing
        );
        tickToOrders[alignedTick].push(orderId);
        orderTickBucket[orderId] = alignedTick;

        // Insert tick into sorted linked list if not already active
        if (!isActiveTick[alignedTick]) {
            _insertActiveTick(alignedTick);
        }

        emit OrderCreated(orderId, msg.sender, zeroForOne, amountIn, triggerPrice);
    }

    /// @notice Cancel an active order and return deposited tokens
    /// @dev Removes the order from its tick bucket. If the bucket becomes empty,
    ///      removes the tick from the active linked list.
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

        // If tick bucket is now empty, remove from linked list
        if (tickToOrders[tick].length == 0) {
            _removeActiveTick(tick);
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

    /// @notice Get the next active tick above the given tick
    function getNextActiveTick(int24 tick) external view returns (int24) {
        return nextActiveTick[tick];
    }

    /// @notice Get the next active tick below the given tick
    function getPrevActiveTick(int24 tick) external view returns (int24) {
        return prevActiveTick[tick];
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Hook callback - executes eligible limit orders AFTER each swap
    function _afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Prevent recursion from our own internal swaps
        if (isExecuting) {
            return (this.afterSwap.selector, 0);
        }

        // Read the ACTUAL post-swap price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 currentPrice = sqrtPriceToUint128(sqrtPriceX96);

        // Execute matching orders using the linked list
        _tryExecuteOrders(poolKey, currentPrice, params.zeroForOne);

        return (this.afterSwap.selector, 0);
    }

    /// @notice Scan ONLY active (populated) ticks and execute eligible orders
    /// @dev Instead of blindly iterating MAX_TICK_SCAN * tickSpacing range,
    ///      we walk the sorted linked list of active ticks. This means:
    ///      - Whale swaps that move price 50,000 ticks: still works (O(K) where K = populated ticks)
    ///      - Sparse order book with 3 orders spread across 100,000 ticks: 3 iterations, not 100
    ///
    ///      Direction logic:
    ///      - !zeroForOne swap (price UP) → scan downward for SELL orders (trigger when price >= X)
    ///      - zeroForOne swap (price DOWN) → scan upward for BUY orders (trigger when price <= X)
    function _tryExecuteOrders(
        PoolKey calldata poolKey,
        uint128 currentPrice,
        bool swapZeroForOne
    ) internal {
        address token0 = Currency.unwrap(poolKey.currency0);

        int24 activeTickCount = 0;

        if (swapZeroForOne) {
            // Price went DOWN → scan upward for BUY orders (triggerPrice >= currentPrice)
            // Start from the lowest active tick and go up
            int24 tick = nextActiveTick[SENTINEL_MIN];

            while (tick != SENTINEL_MAX && activeTickCount < MAX_ACTIVE_TICK_SCAN) {
                if (gasleft() < GAS_LIMIT_PER_ORDER) break;

                // Cache next before potential removal
                int24 nextTick = nextActiveTick[tick];

                _processTickBucket(tick, token0, currentPrice, poolKey);

                // If bucket is now empty after processing, remove from list
                if (tickToOrders[tick].length == 0) {
                    _removeActiveTick(tick);
                }

                activeTickCount++;
                tick = nextTick;
            }
        } else {
            // Price went UP → scan downward for SELL orders (triggerPrice <= currentPrice)
            // Start from the highest active tick and go down
            int24 tick = prevActiveTick[SENTINEL_MAX];

            while (tick != SENTINEL_MIN && activeTickCount < MAX_ACTIVE_TICK_SCAN) {
                if (gasleft() < GAS_LIMIT_PER_ORDER) break;

                // Cache prev before potential removal
                int24 prevTick = prevActiveTick[tick];

                _processTickBucket(tick, token0, currentPrice, poolKey);

                // If bucket is now empty after processing, remove from list
                if (tickToOrders[tick].length == 0) {
                    _removeActiveTick(tick);
                }

                activeTickCount++;
                tick = prevTick;
            }
        }
    }

    /// @notice Process all orders in a single tick bucket
    /// @dev Iterates orders in the bucket, executes eligible ones, performs
    ///      lazy cleanup of filled/cancelled orders.
    function _processTickBucket(
        int24 tick,
        address token0,
        uint128 currentPrice,
        PoolKey calldata poolKey
    ) internal {
        uint256[] storage orderIdsInTick = tickToOrders[tick];

        uint256 i = 0;
        while (i < orderIdsInTick.length) {
            if (gasleft() < GAS_LIMIT_PER_ORDER) break;

            uint256 orderId = orderIdsInTick[i];
            LimitOrder storage order = orders[orderId];

            // Lazy cleanup: remove filled/cancelled orders
            if (order.creator == address(0) || order.isFilled) {
                _removeFromArray(orderIdsInTick, i);
                continue;
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
                _executeOrder(poolKey, order, orderId);
                _removeFromArray(orderIdsInTick, i);
            } else {
                i++;
            }
        }
    }

    /// @notice Execute a single order via internal swap
    /// @dev Performs a swap through PoolManager to fill the order:
    ///      1. Approve PoolManager for the input token
    ///      2. Execute swap via poolManager.swap()
    ///      3. Settle input tokens (sync + transfer + settle)
    ///      4. Take output tokens for the order creator
    ///      5. Validate slippage and mark order as filled
    function _executeOrder(
        PoolKey calldata poolKey,
        LimitOrder storage order,
        uint256 orderId
    ) internal {
        isExecuting = true;

        uint96 amountIn = order.zeroForOne ? order.amount0 : order.amount1;

        // Get current price for slippage limit
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        // Price limit: 5% slippage on the internal swap
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

        // Settle input + Take output
        if (order.zeroForOne) {
            poolManager.sync(poolKey.currency0);
            IERC20(order.token0).safeTransfer(address(poolManager), uint256(amountIn));
            poolManager.settle();

            int128 deltaAmount1 = swapDelta.amount1();
            uint256 amountOut = deltaAmount1 < 0
                ? uint256(uint128(-deltaAmount1))
                : uint256(uint128(deltaAmount1));

            // Slippage protection
            uint256 expectedOut = (uint256(amountIn) * uint256(order.triggerPrice)) / 1e18;
            uint256 minAmountOut = (expectedOut * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

            if (amountOut < minAmountOut) {
                isExecuting = false;
                revert SlippageExceeded(minAmountOut, amountOut);
            }

            poolManager.take(poolKey.currency1, order.creator, amountOut);

            order.isFilled = true;
            order.amount1 = amountOut.toUint96();
        } else {
            poolManager.sync(poolKey.currency1);
            IERC20(order.token1).safeTransfer(address(poolManager), uint256(amountIn));
            poolManager.settle();

            int128 deltaAmount0 = swapDelta.amount0();
            uint256 amountOut = deltaAmount0 < 0
                ? uint256(uint128(-deltaAmount0))
                : uint256(uint128(deltaAmount0));

            // Slippage protection
            uint256 expectedOut = (uint256(amountIn) * 1e18) / uint256(order.triggerPrice);
            uint256 minAmountOut = (expectedOut * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

            if (amountOut < minAmountOut) {
                isExecuting = false;
                revert SlippageExceeded(minAmountOut, amountOut);
            }

            poolManager.take(poolKey.currency0, order.creator, amountOut);

            order.isFilled = true;
            order.amount0 = amountOut.toUint96();
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
                   SORTED LINKED LIST OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Insert a tick into the sorted doubly-linked list
    /// @dev Walks forward from SENTINEL_MIN to find the correct sorted position.
    ///      For most use cases (few dozen active ticks), this is cheap.
    ///      Worst case: O(N) where N = number of active ticks.
    ///      Could be optimized with a hint parameter if needed for >1000 active ticks.
    function _insertActiveTick(int24 tick) internal {
        // Walk from the lowest sentinel to find insertion point
        int24 cursor = SENTINEL_MIN;
        while (nextActiveTick[cursor] != SENTINEL_MAX && nextActiveTick[cursor] < tick) {
            cursor = nextActiveTick[cursor];
        }

        // Insert between cursor and cursor.next
        // Before: cursor <-> cursorNext
        // After:  cursor <-> tick <-> cursorNext
        int24 cursorNext = nextActiveTick[cursor];

        nextActiveTick[cursor] = tick;
        prevActiveTick[tick] = cursor;
        nextActiveTick[tick] = cursorNext;
        prevActiveTick[cursorNext] = tick;

        isActiveTick[tick] = true;
    }

    /// @notice Remove a tick from the sorted doubly-linked list
    /// @dev O(1) operation — just unlink the node.
    function _removeActiveTick(int24 tick) internal {
        if (!isActiveTick[tick]) return;

        int24 prev = prevActiveTick[tick];
        int24 next = nextActiveTick[tick];

        // Before: prev <-> tick <-> next
        // After:  prev <-> next
        nextActiveTick[prev] = next;
        prevActiveTick[next] = prev;

        // Clean up
        delete nextActiveTick[tick];
        delete prevActiveTick[tick];
        isActiveTick[tick] = false;
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert sqrtPriceX96 (Uniswap format) to uint128 price scaled to 1e18
    function sqrtPriceToUint128(uint160 sqrtPriceX96) public pure returns (uint128 price) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 priceX96 = (sqrtPrice * sqrtPrice) / (1 << 96);
        uint256 priceScaled = (priceX96 * 1e18) / (1 << 96);
        price = priceScaled.toUint128();
    }

    /// @notice Convert uint128 price (1e18 scaled) to sqrtPriceX96
    function uint128ToSqrtPrice(uint128 price) public pure returns (uint160 sqrtPriceX96) {
        uint256 priceX192 = (uint256(price) * (1 << 96)) / 1e18;
        uint256 priceX96Full = priceX192 * (1 << 96);
        uint256 sqrtPriceRaw = sqrt(priceX96Full);
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
}
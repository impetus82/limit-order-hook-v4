// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LimitOrderHook
/// @notice Gas-efficient limit orders for Uniswap V4 with real token transfers
/// @dev Phase 2.6: Batch execution with gas metering + custom errors
contract LimitOrderHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error InvalidAmount();
    error OrderNotFound();
    error NotOrderCreator();
    error OrderAlreadyFilled();
    error InvalidTriggerPrice();
    error Unauthorized();
    error IndexOutOfBounds();

    /*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Packed limit order structure (4 storage slots)
    struct LimitOrder {
        address creator;        // slot 0: 20 bytes
        uint96 amount0;         // slot 0: 12 bytes
        uint96 amount1;         // slot 1: 12 bytes
        address token0;         // slot 1: 20 bytes
        address token1;         // slot 2: 20 bytes
        uint128 triggerPrice;   // slot 3: 16 bytes
        uint64 createdAt;       // slot 3: 8 bytes
        bool isFilled;          // slot 3: 1 byte
        bool zeroForOne;        // slot 3: 1 byte
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/
    
    mapping(uint256 => LimitOrder) public orders;
    mapping(address => uint256[]) private userOrders;
    uint256 public nextOrderId;
    /// @notice Tick-based order indexing for O(1) lookup
    mapping(int24 => uint256[]) public tickToOrders;
    mapping(uint256 => int24) private orderTickBucket;
    
    /// @dev Reentrancy guard for execution
    bool private isExecuting;

    uint256 public constant MIN_ORDER_SIZE = 0.01 ether;
    uint256 public feePercentage = 5;
    uint256 public collectedFees;
    address public owner;

    /// @notice Range width for tick checking (±N ticks around current)
    int24 public constant TICK_RANGE_WIDTH = 2;

    /// @notice Minimum gas required to attempt executing one more order
    /// @dev Based on empirical ~100-150k gas per order execution (Phase 2.3)
    ///      150k threshold leaves buffer for settle/take + loop overhead
    uint256 public constant GAS_LIMIT_PER_ORDER = 150_000;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event OrderCreated(
        uint256 indexed orderId,
        address indexed creator,
        uint96 amount0,
        uint96 amount1,
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
    
    constructor(IPoolManager _poolManager) 
        BaseHook(_poolManager)
    {
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/
    
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
        
        emit OrderCreated(orderId, msg.sender, 
            zeroForOne ? amountIn : 0,
            zeroForOne ? 0 : amountIn,
            triggerPrice
        );
    }

    /// @notice Cancel an order and return tokens
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
    
    function getOrder(uint256 orderId) external view returns (LimitOrder memory) {
        return orders[orderId];
    }
    
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }
    
    function getOrdersInTick(int24 tick) external view returns (uint256[] memory) {
        return tickToOrders[tick];
    }
    
    function getTickBucket(uint256 orderId) external view returns (int24) {
        return orderTickBucket[orderId];
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION LOGIC
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Hook called BEFORE every swap - executes eligible limit orders
    function _beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Prevent recursion
        if (isExecuting) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        
        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 currentPrice = sqrtPriceToUint128(sqrtPriceX96);
        
        // Try to execute matching orders (with gas metering)
        (bool executed, int128 delta0, int128 delta1) = _tryExecuteOrders(
            poolKey, 
            currentPrice, 
            params.zeroForOne
        );
        
        if (executed) {
            BeforeSwapDelta beforeSwapDelta = _toBeforeSwapDelta(delta0, delta1);
            return (this.beforeSwap.selector, beforeSwapDelta, 0);
        }
        
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Try to execute orders in a tick range (with lazy cleanup + gas metering)
    function _tryExecuteOrders(
        PoolKey calldata poolKey,
        uint128 currentPrice,
        bool userSwapDirection
    ) internal returns (bool executed, int128 delta0, int128 delta1) {
        // Get current tick
        uint160 sqrtPriceX96 = uint128ToSqrtPrice(currentPrice);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        
        int24 tickSpacing = poolKey.tickSpacing;
        
        // Calculate tick range to check
        int24 startTick = currentTick - (TICK_RANGE_WIDTH * tickSpacing);
        int24 endTick = currentTick + (TICK_RANGE_WIDTH * tickSpacing);
        
        address token0 = Currency.unwrap(poolKey.currency0);
        
        // Iterate through tick range
        for (int24 tick = startTick; tick <= endTick; tick += tickSpacing) {
            // Gas check at tick level: bail out if not enough gas for even one order
            if (gasleft() < GAS_LIMIT_PER_ORDER) break;
            
            uint256[] storage orderIdsInTick = tickToOrders[tick];
            
            if (orderIdsInTick.length == 0) continue;
            
            // Iterate through orders in this tick (with lazy cleanup)
            uint256 i = 0;
            while (i < orderIdsInTick.length) {
                // Gas check per order: stop executing if running low
                if (gasleft() < GAS_LIMIT_PER_ORDER) break;
                
                uint256 orderId = orderIdsInTick[i];
                LimitOrder storage order = orders[orderId];
                
                // Lazy cleanup: remove filled/cancelled orders
                if (order.creator == address(0) || order.isFilled) {
                    _removeFromArray(orderIdsInTick, i);
                    continue; // Don't increment i (array shifted)
                }
                
                // Skip if wrong direction
                bool isSellOrder = order.zeroForOne;
                
                // Check eligibility
                bool eligible = false;
                if (isSellOrder) {
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
                        orderId,
                        token0
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
    
    /// @notice Execute a single order within beforeSwap context
    function _executeOrderInBeforeSwap(
        PoolKey calldata poolKey,
        LimitOrder storage order,
        uint256 orderId,
        address token0
    ) internal returns (int128 orderDelta0, int128 orderDelta1) {
        isExecuting = true;
        
        order.isFilled = true;
        
        uint96 amountIn = order.zeroForOne ? order.amount0 : order.amount1;
        
        // Calculate execution price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 executionPrice = sqrtPriceToUint128(sqrtPriceX96);
        
        if (order.zeroForOne) {
            // Selling token0 for token1
            // Hook gives token0 to pool, pool gives token1 to user
            IERC20(order.token0).approve(address(poolManager), uint256(amountIn));
            
            poolManager.sync(poolKey.currency0);
            IERC20(order.token0).safeTransfer(address(poolManager), uint256(amountIn));
            poolManager.settle();
            
            // Take token1 for order creator
            uint256 amountOut = uint256(amountIn); // 1:1 simplified for MVP
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
            
            // Take token0 for order creator
            uint256 amountOut = uint256(amountIn); // 1:1 simplified for MVP
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
    
    /// @notice Convert sqrtPriceX96 to uint128 price (1e18 scale)
    function sqrtPriceToUint128(uint160 sqrtPriceX96) public pure returns (uint128) {
        uint256 price = uint256(sqrtPriceX96);
        // price = (sqrtPriceX96 / 2^96)^2 * 1e18
        // Split to avoid overflow: (sqrtPriceX96^2 / 2^192) * 1e18
        price = (price * price) >> 96;
        price = (price * 1e18) >> 96;
        return uint128(price);
    }
    
    /// @notice Convert uint128 price to sqrtPriceX96
    function uint128ToSqrtPrice(uint128 price) public pure returns (uint160) {
        // sqrtPriceX96 = sqrt(price / 1e18) * 2^96
        uint256 priceScaled = uint256(price) << 96;
        uint256 priceDiv = priceScaled / 1e18;
        uint256 sqrtPrice = sqrt(priceDiv);
        uint256 sqrtPriceX96 = sqrtPrice << 48;
        return uint160(sqrtPriceX96);
    }
    
    /// @notice Integer square root (Babylonian method)
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Align tick to tick spacing grid
    function _alignTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        if (tick >= 0) {
            return (tick / tickSpacing) * tickSpacing;
        } else {
            return ((tick - tickSpacing + 1) / tickSpacing) * tickSpacing;
        }
    }

    /// @notice Remove element from array by swapping with last and popping (O(1))
    function _removeFromArray(uint256[] storage array, uint256 index) private {
        if (index >= array.length) revert IndexOutOfBounds();
        
        uint256 lastIndex = array.length - 1;
        if (index != lastIndex) {
            array[index] = array[lastIndex];
        }
        array.pop();
    }

    /// @notice Convert delta values to BeforeSwapDelta
    function _toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified) 
        internal 
        pure 
        returns (BeforeSwapDelta) 
    {
        // Pack two int128 values into BeforeSwapDelta
        return BeforeSwapDelta.wrap(
            int256(deltaSpecified) << 128 | int256(uint256(uint128(deltaUnspecified)))
        );
    }
}
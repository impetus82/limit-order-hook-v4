// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @title LimitOrderHook
/// @notice Gas-efficient limit orders for Uniswap V4 using packed storage
/// @dev Phase 1: Day 5-7 - Order execution logic implemented
contract LimitOrderHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error InvalidAmount();
    error OrderNotFound();
    error UnauthorizedCancellation();
    error OrderAlreadyFilled();
    error InvalidTriggerPrice();

    /*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Packed limit order structure (3 storage slots)
    /// @dev Gas optimization: uint96 for amounts (supports up to 79B tokens with 18 decimals)
    ///      uint128 for price, uint64 for timestamp, bool for status flags
    struct LimitOrder {
        address creator;        // slot 0: 20 bytes
        uint96 amount0;         // slot 0: 12 bytes (max ~79B tokens)
        uint96 amount1;         // slot 1: 12 bytes
        address token0;         // slot 1: 20 bytes (pool token0)
        uint128 triggerPrice;   // slot 2: 16 bytes (encoded as fixed-point 1e18)
        uint64 createdAt;       // slot 2: 8 bytes (timestamp)
        bool isFilled;          // slot 2: 1 byte
        bool zeroForOne;        // slot 2: 1 byte (sell direction)
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Mapping from orderId to LimitOrder
    mapping(uint256 => LimitOrder) public orders;
    
    /// @notice Mapping from user address to their order IDs
    mapping(address => uint256[]) private userOrders;
    
    /// @notice Next order ID counter
    uint256 public nextOrderId;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Emitted when a new limit order is created
    event OrderCreated(
        uint256 indexed orderId,
        address indexed creator,
        uint96 amount0,
        uint96 amount1,
        uint128 triggerPrice
    );
    
    /// @notice Emitted when an order is cancelled
    event OrderCancelled(uint256 indexed orderId, address indexed creator);
    
    /// @notice Emitted when an order is filled
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
    
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

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
            beforeSwap: false,
            afterSwap: true,  // Enabled for limit order execution
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
    
    /// @notice Create a new limit order
    /// @param poolKey The pool key for the Uniswap V4 pool
    /// @param zeroForOne true = sell token0 for token1, false = sell token1 for token0
    /// @param amountIn Amount to sell
    /// @param triggerPrice Target price encoded as fixed-point (1e18 = 1.0)
    /// @return orderId The unique ID of the created order
    /// @dev Gas cost: ~60k gas for new order (3 SSTORE operations)
    function createLimitOrder(
        PoolKey calldata poolKey,
        bool zeroForOne,
        uint96 amountIn,
        uint128 triggerPrice
    ) external returns (uint256 orderId) {
        // Validation: amount must be non-zero
        if (amountIn == 0) {
            revert InvalidAmount();
        }
        
        // Validation: trigger price must be positive
        if (triggerPrice == 0) {
            revert InvalidTriggerPrice();
        }

        // Get order ID and increment counter
        orderId = nextOrderId++;

        // Create order with packed storage (3 slots)
        if (zeroForOne) {
            orders[orderId] = LimitOrder({
                creator: msg.sender,
                amount0: amountIn,
                amount1: 0,
                token0: Currency.unwrap(poolKey.currency0),
                triggerPrice: triggerPrice,
                createdAt: uint64(block.timestamp),
                isFilled: false,
                zeroForOne: true
            });
        } else {
            orders[orderId] = LimitOrder({
                creator: msg.sender,
                amount0: 0,
                amount1: amountIn,
                token0: Currency.unwrap(poolKey.currency0),
                triggerPrice: triggerPrice,
                createdAt: uint64(block.timestamp),
                isFilled: false,
                zeroForOne: false
            });
        }

        // Track user orders
        userOrders[msg.sender].push(orderId);

        emit OrderCreated(
            orderId, 
            msg.sender, 
            zeroForOne ? amountIn : 0, 
            zeroForOne ? 0 : amountIn, 
            triggerPrice
        );
    }

    /// @notice Cancel an existing limit order
    /// @param orderId The ID of the order to cancel
    /// @dev Only the order creator can cancel
    /// @dev Cannot cancel already filled orders
    function cancelOrder(uint256 orderId) external {
        LimitOrder storage order = orders[orderId];

        // Validation: order must exist
        if (order.creator == address(0)) {
            revert OrderNotFound();
        }

        // Access control: only creator can cancel
        if (order.creator != msg.sender) {
            revert UnauthorizedCancellation();
        }

        // Validation: cannot cancel filled orders
        if (order.isFilled) {
            revert OrderAlreadyFilled();
        }

        // Delete order (gas refund: ~15k gas)
        delete orders[orderId];

        emit OrderCancelled(orderId, msg.sender);
    }

    /// @notice Get order details
    /// @param orderId The ID of the order
    /// @return order The limit order struct
    function getOrder(uint256 orderId) external view returns (LimitOrder memory) {
        return orders[orderId];
    }

    /// @notice Get all order IDs for a user
    /// @param user The user address
    /// @return orderIds Array of order IDs created by the user
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION LOGIC (DAY 5-7)
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Internal hook called after every swap
    /// @dev Override _afterSwap instead of afterSwap (BaseHook pattern)
    /// @dev Detects price changes and executes eligible limit orders
    function _afterSwap(
        address,
        PoolKey calldata poolKey,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // PHASE 1: Get current pool price
        (uint160 sqrtPriceX96,,, ) = poolManager.getSlot0(poolKey.toId());
        uint128 currentPrice = sqrtPriceToUint128(sqrtPriceX96);
        
        // PHASE 2 & 3: Match and execute eligible orders
        _matchOrders(poolKey, currentPrice);
        
        return (this.afterSwap.selector, 0);
    }

    /// @notice Convert sqrtPriceX96 to human-readable price (1e18 fixed-point)
    /// @param sqrtPriceX96 The square root price in Q64.96 format
    /// @return price The price as uint128 with 1e18 precision
    /// @dev Formula: price = (sqrtPriceX96 / 2^96)^2 * 1e18
    function sqrtPriceToUint128(uint160 sqrtPriceX96) public pure returns (uint128 price) {
        // Step 1: Convert sqrtPriceX96 to uint256 for safe math
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        
        // Step 2: Divide by 2^96 to get sqrt(P)
        // sqrtPrice / 2^96 = sqrtPrice >> 96
        uint256 sqrtP = sqrtPrice;
        
        // Step 3: Square to get P, then scale to 1e18
        // P = (sqrtPrice / 2^96)^2
        // To avoid overflow: (sqrtPrice^2) / (2^192) * 1e18
        // Rewrite as: (sqrtPrice^2 * 1e18) / 2^192
        // But 2^192 is too large, so we do: (sqrtPrice * 1e18 / 2^96)^2 / 2^96
        
        // Simplified approach: sqrtPrice * sqrtPrice / 2^96 * 1e18 / 2^96
        // = sqrtPrice^2 * 1e18 / 2^192
        // Split division to avoid overflow
        uint256 priceX96 = (sqrtP * sqrtP) / (1 << 96); // Divide by 2^96 once
        uint256 priceScaled = (priceX96 * 1e18) / (1 << 96); // Divide by 2^96 again, scale to 1e18
        
        // Step 4: Cast to uint128 (safe because price won't exceed uint128 range)
        // casting to 'uint128' is safe because priceScaled is result of division
        // and will never exceed uint128 max value in realistic price ranges
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint128(priceScaled);

    }

    /// @notice Match and execute eligible limit orders for the pool
    /// @param poolKey The pool key
    /// @param currentPrice The current price of the pool (1e18 fixed-point)
    /// @dev Iterates through all orders and executes eligible ones
    function _matchOrders(PoolKey calldata poolKey, uint128 currentPrice) internal {
        address token0 = Currency.unwrap(poolKey.currency0);
        
        // Loop through all orders (MVP: O(n) - optimize in Phase 2 with buckets)
        for (uint256 i = 0; i < nextOrderId; i++) {
            LimitOrder storage order = orders[i];
            
            // Skip deleted/filled orders
            if (order.creator == address(0) || order.isFilled) continue;
            
            // Skip orders for other pools
            if (order.token0 != token0) continue;
            
            // Check if order is eligible for execution
            if (_isEligible(order, currentPrice)) {
                _executeOrder(i, currentPrice);
            }
        }
    }

    /// @notice Check if an order is eligible for execution
    /// @param order The limit order
    /// @param currentPrice The current pool price (1e18 fixed-point)
    /// @return eligible True if order should be executed
    /// @dev Buy order (zeroForOne=false): trigger if currentPrice <= triggerPrice
    ///      Sell order (zeroForOne=true): trigger if currentPrice >= triggerPrice
    function _isEligible(LimitOrder storage order, uint128 currentPrice) 
        internal 
        view 
        returns (bool eligible) 
    {
        if (order.zeroForOne) {
            // Sell token0 for token1: trigger when price goes UP (currentPrice >= triggerPrice)
            eligible = currentPrice >= order.triggerPrice;
        } else {
            // Buy token0 with token1: trigger when price goes DOWN (currentPrice <= triggerPrice)
            eligible = currentPrice <= order.triggerPrice;
        }
    }

    /// @notice Execute a limit order
    /// @param orderId The ID of the order to execute
    /// @param executionPrice The price at which the order is executed
    /// @dev Marks order as filled and emits event
    /// @dev TODO Phase 2: Implement actual token transfers via PoolManager.take()/settle()
    function _executeOrder(uint256 orderId, uint128 executionPrice) internal {
        LimitOrder storage order = orders[orderId];
        
        // Mark as filled (prevents double execution)
        order.isFilled = true;
        
        // TODO Phase 2: Implement token transfers
        // For MVP, we just mark as filled and emit event
        // Production implementation would do:
        // 1. poolManager.unlock() to enable transfers
        // 2. poolManager.take() to withdraw tokens from pool
        // 3. poolManager.settle() to deposit tokens to pool
        // 4. Transfer output tokens to order.creator
        
        emit OrderFilled(
            orderId,
            order.creator,
            order.zeroForOne ? order.amount0 : order.amount1,
            order.zeroForOne ? order.amount1 : order.amount0,
            executionPrice
        );
    }
}
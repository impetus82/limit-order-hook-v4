// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";  // ADD THIS

/// @title LimitOrderHook
/// @notice Gas-efficient limit orders for Uniswap V4 using packed storage
/// @dev Phase 1 MVP - Day 3-4: Order creation and cancellation
contract LimitOrderHook is BaseHook {
    using PoolIdLibrary for PoolKey;

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

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /*//////////////////////////////////////////////////////////////
                        HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Required hook permissions for limit order functionality
    /// @dev Only afterSwap is enabled for execution logic (Day 5-7)
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
    /// @param amount0 Amount of token0 to sell (if non-zero)
    /// @param amount1 Amount of token1 to sell (if non-zero)
    /// @param triggerPrice Target price encoded as fixed-point (1e18 = 1.0)
    /// @return orderId The unique ID of the created order
    /// @dev Gas cost: ~60k gas for new order (3 SSTORE operations)
    function createLimitOrder(
        PoolKey calldata poolKey,
        uint96 amount0,
        uint96 amount1,
        uint128 triggerPrice
    ) external returns (uint256 orderId) {
        // Validation: exactly one amount must be non-zero
        if ((amount0 == 0 && amount1 == 0) || (amount0 != 0 && amount1 != 0)) {
            revert InvalidAmount();
        }
        
        // Validation: trigger price must be positive
        if (triggerPrice == 0) {
            revert InvalidTriggerPrice();
        }

        // Get order ID and increment counter
        orderId = nextOrderId++;

        // Create order with packed storage (3 slots)
        orders[orderId] = LimitOrder({
            creator: msg.sender,
            amount0: amount0,
            amount1: amount1,
            token0: Currency.unwrap(poolKey.currency0),  // Unwrap Currency to address
            triggerPrice: triggerPrice,
            createdAt: uint64(block.timestamp),
            isFilled: false
        });

        // Track user orders
        userOrders[msg.sender].push(orderId);

        emit OrderCreated(orderId, msg.sender, amount0, amount1, triggerPrice);
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
                        HOOK LIFECYCLE
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Internal hook called after every swap
    /// @dev Override _afterSwap instead of afterSwap (BaseHook pattern)
    /// @dev Execution logic will be implemented on Day 5-7
    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // TODO: Implement order execution logic on Day 5-7
        // - Check current pool price
        // - Find matching orders in price bucket
        // - Execute eligible orders
        // - Emit OrderFilled events
        
        return (this.afterSwap.selector, 0);
    }
}
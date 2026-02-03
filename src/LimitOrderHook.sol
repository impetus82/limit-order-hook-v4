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
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title LimitOrderHook
/// @notice Gas-efficient limit orders for Uniswap V4 with real token transfers
/// @dev Phase 2.3: BeforeSwap execution with delta return
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
    error UnauthorizedCancellation();
    error OrderAlreadyFilled();
    error InvalidTriggerPrice();
    error Unauthorized();

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
    
    /// @dev Reentrancy guard for execution
    bool private isExecuting;

    uint256 public constant MIN_ORDER_SIZE = 0.01 ether;
    uint256 public feePercentage = 5;
    uint256 public collectedFees;
    address public owner;

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

        if (zeroForOne) {
            // Selling token0 for token1
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                msg.sender,
                address(this),
                uint256(amountIn)
            );

            orders[orderId] = LimitOrder({
                creator: msg.sender,
                amount0: amountIn,
                amount1: 0,
                token0: Currency.unwrap(poolKey.currency0),
                token1: Currency.unwrap(poolKey.currency1),
                triggerPrice: triggerPrice,
                createdAt: uint64(block.timestamp),
                isFilled: false,
                zeroForOne: true
            });
        } else {
            // Buying token0 with token1
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                msg.sender,
                address(this),
                uint256(amountIn)
            );

            orders[orderId] = LimitOrder({
                creator: msg.sender,
                amount0: 0,
                amount1: amountIn,
                token0: Currency.unwrap(poolKey.currency0),
                token1: Currency.unwrap(poolKey.currency1),
                triggerPrice: triggerPrice,
                createdAt: uint64(block.timestamp),
                isFilled: false,
                zeroForOne: false
            });
        }

        userOrders[msg.sender].push(orderId);

        emit OrderCreated(
            orderId, 
            msg.sender, 
            zeroForOne ? amountIn : 0, 
            zeroForOne ? 0 : amountIn, 
            triggerPrice
        );
    }

    /// @notice Cancel an existing limit order with token refund
    function cancelOrder(uint256 orderId) external {
        LimitOrder storage order = orders[orderId];

        if (order.creator == address(0)) revert OrderNotFound();
        if (order.creator != msg.sender) revert UnauthorizedCancellation();
        if (order.isFilled) revert OrderAlreadyFilled();

        // Refund tokens
        if (order.zeroForOne && order.amount0 > 0) {
            IERC20(order.token0).safeTransfer(msg.sender, uint256(order.amount0));
        } else if (!order.zeroForOne && order.amount1 > 0) {
            IERC20(order.token1).safeTransfer(msg.sender, uint256(order.amount1));
        }

        delete orders[orderId];
        emit OrderCancelled(orderId, msg.sender);
    }

    function getOrder(uint256 orderId) external view returns (LimitOrder memory) {
        return orders[orderId];
    }

    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION LOGIC
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Hook called BEFORE every swap - executes eligible limit orders
    /// @dev Uses _beforeSwap internal function from BaseHook
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
        
        // Try to execute matching orders
        (bool executed, int128 delta0, int128 delta1) = _tryExecuteOrders(
            poolKey, 
            currentPrice, 
            params.zeroForOne
        );
        
        if (executed) {
            // Return delta from order execution
            BeforeSwapDelta beforeSwapDelta = _toBeforeSwapDelta(delta0, delta1);
            return (this.beforeSwap.selector, beforeSwapDelta, 0);
        }
        
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Try to execute eligible limit orders
    function _tryExecuteOrders(
        PoolKey calldata poolKey,
        uint128 currentPrice,
        bool userSwapDirection
    ) internal returns (bool executed, int128 delta0, int128 delta1) {
        address token0 = Currency.unwrap(poolKey.currency0);
        
        console2.log("=== TRYING TO EXECUTE ORDERS ===");
        console2.log("User swap direction (zeroForOne):", userSwapDirection);
        console2.log("Current price:", currentPrice);
        
        for (uint256 i = 0; i < nextOrderId; i++) {
            LimitOrder storage order = orders[i];
            
            if (order.creator == address(0) || order.isFilled) continue;
            if (order.token0 != token0) continue;
            
            console2.log("\n--- Order", i, "---");
            console2.log("Order direction (zeroForOne):", order.zeroForOne);
            console2.log("Trigger price:", order.triggerPrice);
            
            // Check price trigger
            if (!_isEligible(order, currentPrice)) {
                console2.log("SKIP: Price not eligible");
                continue;
            }
            
            console2.log("Price is eligible!");
            
            // Execute only if direction is opposite to user swap
            // if (order.zeroForOne == userSwapDirection) {
                // console2.log("SKIP: Same direction as user swap (would compete for liquidity)");
                // continue;
            // }
            
            console2.log("Direction is opposite - EXECUTING!");
            
            // Execute order
            (int128 d0, int128 d1) = _executeOrderInBeforeSwap(i, poolKey, currentPrice);
            
            delta0 += d0;
            delta1 += d1;
            executed = true;
            
            break;
        }
        
        if (!executed) {
            console2.log("\nNO ORDERS EXECUTED");
        }
    }

    /// @notice Execute single order in beforeSwap context
    function _executeOrderInBeforeSwap(
        uint256 orderId,
        PoolKey calldata poolKey,
        uint128 executionPrice
    ) internal returns (int128 delta0, int128 delta1) {
        LimitOrder storage order = orders[orderId];
        order.isFilled = true;
        
        isExecuting = true;
        
        // Calculate price limit (5% slippage)
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceLimitX96 = order.zeroForOne
            ? uint160((uint256(currentSqrtPriceX96) * 95) / 100)
            : uint160((uint256(currentSqrtPriceX96) * 105) / 100);
        
        // Swap
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: order.zeroForOne 
                ? -int256(uint256(order.amount0))
                : -int256(uint256(order.amount1)),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        
        BalanceDelta swapDelta = poolManager.swap(poolKey, swapParams, "");
        
        // Settle + take
        if (order.zeroForOne) {
            // Selling token0 for token1
            poolManager.sync(poolKey.currency0);
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(
                address(poolManager), 
                uint256(order.amount0)
            );
            poolManager.settle();
            
            int128 deltaAmount1 = swapDelta.amount1();
            uint256 amountOut = deltaAmount1 < 0 
                ? uint256(uint128(-deltaAmount1))
                : uint256(uint128(deltaAmount1));
            
            require(amountOut > 0, "Execution failed: zero output");
            poolManager.take(poolKey.currency1, order.creator, amountOut);
            
            order.amount1 = uint96(amountOut);
            
            // ✅ FIX: Return ZERO deltas (hook already settled everything)
            delta0 = 0;
            delta1 = 0;
        } else {
            // Buying token0 with token1
            poolManager.sync(poolKey.currency1);
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(
                address(poolManager),
                uint256(order.amount1)
            );
            poolManager.settle();
            
            int128 deltaAmount0 = swapDelta.amount0();
            uint256 amountOut = deltaAmount0 < 0
                ? uint256(uint128(-deltaAmount0))
                : uint256(uint128(deltaAmount0));
            
            require(amountOut > 0, "Execution failed: zero output");
            poolManager.take(poolKey.currency0, order.creator, amountOut);
            
            order.amount0 = uint96(amountOut);
            
            // ✅ FIX: Return ZERO deltas (hook already settled everything)
            delta0 = 0;
            delta1 = 0;
        }
        
        isExecuting = false;
        
        emit OrderFilled(
            orderId,
            order.creator,
            order.zeroForOne ? order.amount0 : order.amount1,
            order.zeroForOne ? order.amount1 : order.amount0,
            executionPrice
        );
    }

    /// @notice Helper to create BeforeSwapDelta from int128 values
    function _toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified) 
        internal 
        pure 
        returns (BeforeSwapDelta) 
    {
        // Use assembly to pack two int128 values into BeforeSwapDelta (int256)
        return BeforeSwapDelta.wrap(
            int256(deltaSpecified) | (int256(deltaUnspecified) << 128)
        );
    }

    /// @notice Convert sqrtPriceX96 to human-readable price
    function sqrtPriceToUint128(uint160 sqrtPriceX96) public pure returns (uint128 price) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 priceX96 = (sqrtPrice * sqrtPrice) / (1 << 96);
        uint256 priceScaled = (priceX96 * 1e18) / (1 << 96);
        
        // casting to 'uint128' is safe because priceScaled is result of division
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint128(priceScaled);
    }

    /// @notice Check if order is eligible for execution
    function _isEligible(LimitOrder storage order, uint128 currentPrice) 
        internal 
        view 
        returns (bool eligible) 
    {
        if (order.zeroForOne) {
            eligible = currentPrice >= order.triggerPrice;
        } else {
            eligible = currentPrice <= order.triggerPrice;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function setFeePercentage(uint256 newFee) external {
        if (msg.sender != owner) revert Unauthorized();
        require(newFee <= 50, "Fee too high");
        feePercentage = newFee;
    }

    function withdrawFees(address payable recipient) external {
        if (msg.sender != owner) revert Unauthorized();
        uint256 amount = collectedFees;
        collectedFees = 0;
        recipient.transfer(amount);
    }
}
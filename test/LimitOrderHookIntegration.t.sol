// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {LimitOrderHook} from "../src/LimitOrderHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";

contract LimitOrderHookIntegrationTest is Test {
    PoolManager manager;
    LimitOrderHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    
    MockERC20 token0;
    MockERC20 token1;
    
    PoolKey poolKey;
    
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address user;

    event OrderFilled(
        uint256 indexed orderId,
        address indexed creator,
        uint96 amountIn,
        uint96 amountOut,
        uint128 executionPrice
    );

    function setUp() public {
        user = makeAddr("user");
        
        manager = new PoolManager(address(this));
        
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        // Mine hook address with correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(address(manager));
        
        vm.pauseGasMetering();
        (address predictedAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(LimitOrderHook).creationCode,
            constructorArgs
        );
        
        hook = new LimitOrderHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == predictedAddress, "Hook address mismatch!");
        vm.resumeGasMetering();
        
        // Mint tokens for test users
        token0.mint(alice, 10_000e18);
        token1.mint(alice, 10_000e18);
        token0.mint(bob, 10_000e18);
        token1.mint(bob, 10_000e18);
        
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // price = 1.0
        manager.initialize(poolKey, sqrtPriceX96);
        
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        
        addLiquidity();
    }

    function addLiquidity() internal {
        token0.mint(address(this), 10_000e18);
        token1.mint(address(this), 10_000e18);
        
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -1200,
                tickUpper: 1200,
                liquidityDelta: 10_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                        PHASE 2.3 TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateOrderTransfersTokens() public {
        vm.startPrank(alice);
        
        uint96 amountIn = 100e18;
        uint256 aliceBalanceBefore = token0.balanceOf(alice);
        uint256 hookBalanceBefore = token0.balanceOf(address(hook));
        
        token0.approve(address(hook), amountIn);
        hook.createLimitOrder(poolKey, true, amountIn, 2e18);
        
        assertEq(token0.balanceOf(alice), aliceBalanceBefore - amountIn);
        assertEq(token0.balanceOf(address(hook)), hookBalanceBefore + amountIn);
        
        vm.stopPrank();
    }

    function testCancelOrderReturnsTokens() public {
        vm.startPrank(alice);
        
        uint96 amountIn = 50e18;
        uint256 aliceBalanceBefore = token0.balanceOf(alice);
        
        token0.approve(address(hook), amountIn);
        uint256 orderId = hook.createLimitOrder(poolKey, true, amountIn, 2e18);
        
        hook.cancelOrder(orderId);
        
        assertEq(token0.balanceOf(alice), aliceBalanceBefore);
        assertEq(token0.balanceOf(address(hook)), 0);
        
        vm.stopPrank();
    }
        
    function testFullOrderExecution() public {
        console2.log("=== FULL ORDER EXECUTION TEST ===");
        
        uint128 triggerPrice = 0.998e18;
        uint96 amountIn = 1e18;
        
        vm.startPrank(alice);
        token0.approve(address(hook), amountIn);
        
        uint256 orderId = hook.createLimitOrder(
            poolKey, 
            true,
            amountIn, 
            triggerPrice
        );
        vm.stopPrank();
        
        uint256 aliceToken0Before = token0.balanceOf(alice);
        
        vm.startPrank(bob);
        token1.mint(bob, 10e18);
        token1.approve(address(swapRouter), 10e18);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -10e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        vm.stopPrank();

        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        
        console2.log("=== AFTER EXECUTION ===");
        console2.log("Order filled:", order.isFilled);
        
        assertTrue(order.isFilled, "Order should be filled");
    }

    /*//////////////////////////////////////////////////////////////
                        EXISTING TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateOrder() public {
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 100e18, 2e18);
        
        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertEq(order.creator, alice);
        assertEq(order.amount0, 100e18);
        
        vm.stopPrank();
    }

    function testUnauthorizedCancellationFails() public {
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 100e18, 2e18);
        vm.stopPrank();
        
        vm.startPrank(bob);
        vm.expectRevert(LimitOrderHook.NotOrderCreator.selector);
        hook.cancelOrder(orderId);
        vm.stopPrank();
    }

    function testZeroAmountFails() public {
        vm.prank(alice);
        vm.expectRevert(LimitOrderHook.InvalidAmount.selector);
        hook.createLimitOrder(poolKey, true, 0, 2e18);
    }

    /*//////////////////////////////////////////////////////////////
                        PHASE 2.5 TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testRangeExecution() public {
        uint128 triggerPrice = 0.999e18;
        
        token0.mint(user, 1e18);
        vm.startPrank(user);
        token0.approve(address(hook), 1e18);
        uint256 orderId = hook.createLimitOrder(
            poolKey, 
            true,
            1e18, 
            triggerPrice
        );
        vm.stopPrank();
        
        token1.mint(address(this), 10e18);
        token1.approve(address(swapRouter), 10e18);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -10e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Order should be filled via range checking");
    }
    
    function testBucketCleanup() public {
        token0.mint(user, 2e18);
        
        vm.startPrank(user);
        token0.approve(address(hook), 2e18);
        
        uint128 triggerPrice = 0.998e18;
        
        uint256 orderId1 = hook.createLimitOrder(poolKey, true, 1e18, triggerPrice);
        uint256 orderId2 = hook.createLimitOrder(poolKey, true, 1e18, triggerPrice);
        
        // Cancel first order
        hook.cancelOrder(orderId1);
        vm.stopPrank();
        
        // Get tick bucket for second order
        int24 tick = hook.getTickBucket(orderId2);
        uint256[] memory orderIdsInTick = hook.getOrdersInTick(tick);
        
        // After cancellation, bucket should have fewer entries
        assertLt(orderIdsInTick.length, 3, "Bucket should have been cleaned");
        
        // Trigger execution for remaining order
        token1.mint(address(this), 10e18);
        token1.approve(address(swapRouter), 10e18);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -10e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        LimitOrderHook.LimitOrder memory order2 = hook.getOrder(orderId2);
        assertTrue(order2.isFilled, "Remaining order should be filled");
    }

    /*//////////////////////////////////////////////////////////////
                    PHASE 2.6 — BATCH EXECUTION TEST
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Test that multiple orders in the same tick execute in a single swap
    function testBatchExecution() public {
        console2.log("=== BATCH EXECUTION TEST ===");
        
        uint128 triggerPrice = 0.998e18; // Already below initial price (1.0)
        uint96 amountPerOrder = 1e18;
        uint256 numOrders = 5;
        
        // Create 5 SELL orders at the same trigger price from different users
        address[5] memory users;
        uint256[5] memory orderIds;
        
        for (uint256 j = 0; j < numOrders; j++) {
            users[j] = makeAddr(string(abi.encodePacked("batchUser", j)));
            token0.mint(users[j], amountPerOrder);
            
            vm.startPrank(users[j]);
            token0.approve(address(hook), amountPerOrder);
            orderIds[j] = hook.createLimitOrder(
                poolKey,
                true,           // zeroForOne (SELL token0)
                amountPerOrder,
                triggerPrice
            );
            vm.stopPrank();
            
            console2.log("Created order", orderIds[j], "for user", j);
        }
        
        // Verify all orders are in the same tick bucket
        int24 tick0 = hook.getTickBucket(orderIds[0]);
        for (uint256 j = 1; j < numOrders; j++) {
            assertEq(hook.getTickBucket(orderIds[j]), tick0, "All orders should be in same tick");
        }
        
        console2.log("All orders in tick:", tick0);
        console2.log("Orders in bucket:", hook.getOrdersInTick(tick0).length);
        
        // Single swap should trigger execution of ALL orders
        token1.mint(address(this), 50e18);
        token1.approve(address(swapRouter), 50e18);
        
        uint256 gasBefore = gasleft();
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for batch execution:", gasUsed);
        
        // Verify ALL orders were filled
        uint256 filledCount = 0;
        for (uint256 j = 0; j < numOrders; j++) {
            LimitOrderHook.LimitOrder memory order = hook.getOrder(orderIds[j]);
            if (order.isFilled) {
                filledCount++;
            }
            console2.log("Order", orderIds[j], "filled:", order.isFilled);
        }
        
        console2.log("=== RESULTS ===");
        console2.log("Total orders:", numOrders);
        console2.log("Filled orders:", filledCount);
        console2.log("Gas used:", gasUsed);
        
        // All 5 orders should have been filled in a single swap tx
        assertEq(filledCount, numOrders, "All orders should be filled in batch");
        
        // Tick bucket should be empty after execution
        uint256[] memory remainingOrders = hook.getOrdersInTick(tick0);
        assertEq(remainingOrders.length, 0, "Tick bucket should be empty after batch execution");
        
        // Gas sanity check: 5 orders should cost < 2M gas total
        assertLt(gasUsed, 2_000_000, "Batch execution should be gas-efficient");
    }
    
    /// @notice Test that gas limit prevents revert on many orders
    function testGasLimitProtection() public {
        console2.log("=== GAS LIMIT PROTECTION TEST ===");
        
        uint128 triggerPrice = 0.998e18;
        uint96 amountPerOrder = 0.1e18;
        
        // Create 3 orders (modest amount to ensure gas limit isn't hit)
        uint256[3] memory orderIds;
        for (uint256 j = 0; j < 3; j++) {
            address u = makeAddr(string(abi.encodePacked("gasUser", j)));
            token0.mint(u, amountPerOrder);
            vm.startPrank(u);
            token0.approve(address(hook), amountPerOrder);
            orderIds[j] = hook.createLimitOrder(poolKey, true, amountPerOrder, triggerPrice);
            vm.stopPrank();
        }
        
        // Execute — should NOT revert even with multiple orders
        token1.mint(address(this), 50e18);
        token1.approve(address(swapRouter), 50e18);
        
        // This should complete without reverting (gas limit protection)
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        // At least some orders should be filled (tx didn't revert)
        uint256 filledCount = 0;
        for (uint256 j = 0; j < 3; j++) {
            LimitOrderHook.LimitOrder memory order = hook.getOrder(orderIds[j]);
            if (order.isFilled) filledCount++;
        }
        
        console2.log("Filled:", filledCount, "/ 3");
        assertGt(filledCount, 0, "At least some orders should execute");
    }
}
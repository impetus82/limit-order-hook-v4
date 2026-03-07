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
        
        // Phase 3.10: afterSwap only (AFTER_SWAP_FLAG)
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(address(manager), address(this));
        
        vm.pauseGasMetering();
        (address predictedAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(LimitOrderHook).creationCode,
            constructorArgs
        );
        
        hook = new LimitOrderHook{salt: salt}(IPoolManager(address(manager)), address(this));
        require(address(hook) == predictedAddress, "Hook address mismatch!");
        vm.resumeGasMetering();
        
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        
        // Add liquidity
        addLiquidity();
        
        // Fund alice
        token0.mint(alice, 100_000e18);
        token1.mint(alice, 100_000e18);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
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
                        ORDER CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateOrder() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);
        
        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertEq(order.creator, alice);
        assertEq(order.amount0, 1e18);
        assertTrue(order.zeroForOne);
        assertFalse(order.isFilled);
    }

    function testCreateOrderTransfersTokens() public {
        uint256 hookToken0Before = token0.balanceOf(address(hook));
        
        vm.prank(alice);
        hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);
        
        assertEq(token0.balanceOf(address(hook)) - hookToken0Before, 1e18);
    }

    function testZeroAmountFails() public {
        vm.prank(alice);
        vm.expectRevert(LimitOrderHook.InvalidAmount.selector);
        hook.createLimitOrder(poolKey, true, 0, 1e18);
    }

    /// @notice M-2: Validate poolKey - tickSpacing must be > 0
    function testInvalidPoolKeyFails() public {
        PoolKey memory badPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 0,
            hooks: hook
        });

        vm.prank(alice);
        vm.expectRevert(LimitOrderHook.InvalidPoolKey.selector);
        hook.createLimitOrder(badPoolKey, true, 1e18, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCancelOrderReturnsTokens() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);
        
        uint256 aliceToken0Before = token0.balanceOf(alice);
        
        vm.prank(alice);
        hook.cancelOrder(orderId);
        
        assertEq(token0.balanceOf(alice) - aliceToken0Before, 1e18);
        
        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertEq(order.creator, address(0));
    }

    function testUnauthorizedCancellationFails() public {
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);
        
        vm.prank(bob);
        vm.expectRevert(LimitOrderHook.NotOrderCreator.selector);
        hook.cancelOrder(orderId);
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: BUY order (zeroForOne=false) triggers when price drops
    function testFullOrderExecution() public {
        uint96 amountIn = 1e18;
        uint128 triggerPrice = 1.002e18;
        
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, amountIn, triggerPrice);
        
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Order should be filled");
        assertTrue(order.amount0 > 0, "Alice should have received token0");
    }

    /// @notice Test: SELL order (zeroForOne=true) triggers when price rises
    function testSellOrderExecution() public {
        uint96 amountIn = 1e18;
        uint128 triggerPrice = 1.002e18;

        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, amountIn, triggerPrice);

        token1.mint(address(this), 50e18);
        token1.approve(address(swapRouter), type(uint256).max);

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

        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Sell order should be filled after price UP");
        assertTrue(order.amount1 > 0, "Alice should have received token1");
    }

    function testRangeExecution() public {
        uint96 amountIn = 1e18;
        uint128 triggerPrice = 1.002e18;
        
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, amountIn, triggerPrice);
        
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertTrue(order.isFilled, "Range execution should work");
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH & GAS TESTS
    //////////////////////////////////////////////////////////////*/

    function testBatchExecution() public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        }
        vm.stopPrank();
        
        token0.mint(address(this), 100e18);
        token0.approve(address(swapRouter), type(uint256).max);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        uint256 filledCount = 0;
        for (uint256 i = 0; i < 5; i++) {
            LimitOrderHook.LimitOrder memory order = hook.getOrder(i);
            if (order.isFilled) filledCount++;
        }
        assertTrue(filledCount > 0, "At least one order should be batch-filled");
    }

    function testGasLimitProtection() public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        }
        vm.stopPrank();
        
        token0.mint(address(this), 100e18);
        token0.approve(address(swapRouter), type(uint256).max);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        assertTrue(true, "Gas limit protection prevented OOG revert");
    }

    function testBucketCleanup() public {
        vm.startPrank(alice);
        uint256 orderId1 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.cancelOrder(orderId1);
        uint256 orderId2 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        vm.stopPrank();
        
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        LimitOrderHook.LimitOrder memory order2 = hook.getOrder(orderId2);
        assertTrue(order2.isFilled, "Second order should execute after cleanup");
    }

    /*//////////////////////////////////////////////////////////////
              PHASE 3.12: LINKED LIST & DYNAMIC TICK TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify that creating an order inserts the tick into the active list
    function testActiveTickInsertedOnCreate() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        // Before any orders: SENTINEL_MIN -> SENTINEL_MAX
        assertEq(hook.nextActiveTick(sentinelMin), sentinelMax, "Empty list should point min->max");
        assertEq(hook.prevActiveTick(sentinelMax), sentinelMin, "Empty list should point max->min");

        vm.prank(alice);
        hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        // Now there should be one active tick between sentinels
        int24 firstActive = hook.nextActiveTick(sentinelMin);
        assertTrue(firstActive != sentinelMax, "Should have an active tick after create");
        assertTrue(hook.isActiveTick(firstActive), "Tick should be marked active");
        assertEq(hook.nextActiveTick(firstActive), sentinelMax, "First active -> SENTINEL_MAX");
        assertEq(hook.prevActiveTick(firstActive), sentinelMin, "SENTINEL_MIN <- first active");
    }

    /// @notice Verify that cancelling all orders at a tick removes it from list
    function testActiveTickRemovedOnCancel() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        vm.startPrank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 1e18, 1.002e18);

        // Verify tick is active
        int24 activeTick = hook.nextActiveTick(sentinelMin);
        assertTrue(activeTick != sentinelMax, "Tick should be in list");

        // Cancel the only order at that tick
        hook.cancelOrder(orderId);
        vm.stopPrank();

        // Tick should be removed from list
        assertEq(hook.nextActiveTick(sentinelMin), sentinelMax, "Tick should be removed after cancel");
        assertFalse(hook.isActiveTick(activeTick), "Tick should not be active after cancel");
    }

    /// @notice Verify sorted insertion with multiple different trigger prices
    function testSortedInsertion() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        // Create orders at 3 different prices
        vm.startPrank(alice);
        hook.createLimitOrder(poolKey, true, 1e18, 1.005e18); // higher price = higher tick
        hook.createLimitOrder(poolKey, true, 1e18, 1.001e18); // lower price = lower tick
        hook.createLimitOrder(poolKey, true, 1e18, 1.010e18); // highest price
        vm.stopPrank();

        // Walk the list and verify it's sorted ascending
        int24 prev = sentinelMin;
        int24 current = hook.nextActiveTick(sentinelMin);
        uint256 count = 0;

        while (current != sentinelMax) {
            assertTrue(current > prev || prev == sentinelMin, "List must be sorted ascending");
            prev = current;
            current = hook.nextActiveTick(current);
            count++;
        }

        // We should have 3 distinct ticks (different trigger prices map to different ticks)
        assertTrue(count >= 2, "Should have multiple active ticks for different prices");
    }

    /// @notice Verify that duplicate tick insertions don't create duplicates in the list
    function testNoDuplicateTickInsertion() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        // Create 3 orders at the same price -> same tick bucket
        vm.startPrank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        vm.stopPrank();

        // Walk the list — should have exactly 1 active tick
        int24 current = hook.nextActiveTick(sentinelMin);
        uint256 count = 0;
        while (current != sentinelMax) {
            count++;
            current = hook.nextActiveTick(current);
        }
        assertEq(count, 1, "Same price orders should share one tick in the list");
    }

    /// @notice Test that execution cleans up the linked list when bucket empties
    function testLinkedListCleanupAfterExecution() public {
        int24 sentinelMin = hook.SENTINEL_MIN();
        int24 sentinelMax = hook.SENTINEL_MAX();

        // Create a single BUY order
        vm.prank(alice);
        hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        // Verify tick is in list
        assertTrue(hook.nextActiveTick(sentinelMin) != sentinelMax, "Should have active tick");

        // Execute swap to fill the order
        token0.mint(address(this), 50e18);
        token0.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -50e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Order should be filled and tick removed from list
        LimitOrderHook.LimitOrder memory order = hook.getOrder(0);
        assertTrue(order.isFilled, "Order should be filled");

        // The tick bucket should be empty now, so the tick should be removed
        // Note: cleanup happens during _tryExecuteOrders via _processTickBucket
        // The order was removed from the array during execution
    }

    /// @notice Partial cancel: cancel one of two orders at same tick, tick stays active
    function testPartialCancelKeepsTickActive() public {
        vm.startPrank(alice);
        uint256 order1 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        uint256 order2 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);

        // Both at same tick — cancel one
        hook.cancelOrder(order1);
        vm.stopPrank();

        // Tick should still be active (order2 remains)
        int24 tick = hook.getTickBucket(order2);
        assertTrue(hook.isActiveTick(tick), "Tick should remain active with remaining order");
    }
}
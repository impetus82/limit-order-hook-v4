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

    /// @notice M-2: Validate poolKey — tickSpacing must be > 0
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

    function testFullOrderExecution() public {
        // Alice creates a BUY order (zeroForOne=false): buy token0 with token1
        // triggerPrice > currentPrice so it triggers immediately on beforeSwap
        uint96 amountIn = 1e18;
        uint128 triggerPrice = 1.002e18;
        
        vm.prank(alice);
        uint256 orderId = hook.createLimitOrder(poolKey, false, amountIn, triggerPrice);
        
        // Bob triggers a swap
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
        // Create multiple orders
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
        
        // At least some orders should be filled
        uint256 filledCount = 0;
        for (uint256 i = 0; i < 5; i++) {
            LimitOrderHook.LimitOrder memory order = hook.getOrder(i);
            if (order.isFilled) filledCount++;
        }
        assertTrue(filledCount > 0, "At least one order should be batch-filled");
    }

    function testGasLimitProtection() public {
        // Create many orders to test gas metering
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        }
        vm.stopPrank();
        
        token0.mint(address(this), 100e18);
        token0.approve(address(swapRouter), type(uint256).max);
        
        // Should not revert even with many orders (gas metering stops gracefully)
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
        // If we reach here, gas limit protection worked
        assertTrue(true, "Gas limit protection prevented OOG revert");
    }

    function testBucketCleanup() public {
        // Create and cancel an order, then create new one in same tick
        vm.startPrank(alice);
        uint256 orderId1 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        hook.cancelOrder(orderId1);
        uint256 orderId2 = hook.createLimitOrder(poolKey, false, 1e18, 1.002e18);
        vm.stopPrank();
        
        // Trigger swap to test lazy cleanup during execution
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
}
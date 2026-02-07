// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {LimitOrderHook} from "../src/LimitOrderHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LimitOrderHook} from "../src/LimitOrderHook.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) 
        ERC20(name, symbol, 18) 
    {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LimitOrderHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager manager;
    LimitOrderHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    
    address user;
    address alice = address(0xABCD);
    address bob = address(0x1234);

    event OrderFilled(
        uint256 indexed orderId,
        address indexed creator,
        uint96 amountIn,
        uint96 amountOut,
        uint128 executionPrice
    );

    function setUp() public {
        manager = new PoolManager(address(this));
        
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        // (создание тестового пользователя)
        user = makeAddr("user");
        
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        token0.mint(alice, 10_000e18);
        token1.mint(alice, 10_000e18);
        token0.mint(bob, 10_000e18);
        token1.mint(bob, 10_000e18);
        
        // 🔥 FIX: Correct flags for beforeSwap + beforeSwapReturnDelta
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
        
        vm.resumeGasMetering();
        
        require(address(hook) == predictedAddress, "Hook address mismatch!");
        
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        
        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        manager.initialize(poolKey, sqrtPriceX96);
        
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        
        addLiquidity();
    }

    function addLiquidity() internal {
        // Moderate liquidity for predictable price movement
        token0.mint(address(this), 10_000e18);
        token1.mint(address(this), 10_000e18);
        
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        
        // 🔥 REDUCED liquidity for better test sensitivity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -1200,  // ✅ Wider range
                tickUpper: 1200,
                liquidityDelta: 10_000e18,  // ✅ 10x less liquidity
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
        
        console2.log("Alice token0 before:", aliceToken0Before);
        console2.log("Trigger price:", triggerPrice);
        
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
        console2.log("Alice token0:", token0.balanceOf(alice));
        console2.log("Alice token1:", token1.balanceOf(alice));
        
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
        vm.expectRevert("Not order creator");
        hook.cancelOrder(orderId);
        vm.stopPrank();
    }

    function testZeroAmountFails() public {
        vm.prank(alice);
        vm.expectRevert(LimitOrderHook.InvalidAmount.selector);
        hook.createLimitOrder(poolKey, true, 0, 2e18);
    }

    
    
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
        token0.mint(user, 5e18);
        vm.startPrank(user);
        token0.approve(address(hook), 5e18);
        
        uint128 triggerPrice = 0.998e18;
        uint256[] memory orderIds = new uint256[](5);
        
        for (uint256 i = 0; i < 5; i++) {
            orderIds[i] = hook.createLimitOrder(poolKey, true, 1e18, triggerPrice);
        }
        vm.stopPrank();
        
        // Get the ALIGNED tick to query the bucket
        uint160 sqrtPrice = hook.uint128ToSqrtPrice(triggerPrice);
        int24 rawTick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        // Align to tickSpacing=60 (same logic as contract)
        int24 tick = (rawTick / 60) * 60;
        if (rawTick < 0 && rawTick % 60 != 0) {
            tick -= 60;
        }
        
        uint256[] memory bucketBefore = hook.getTickBucket(tick);
        assertEq(bucketBefore.length, 5, "Should have 5 orders in bucket");
        
        vm.startPrank(user);
        hook.cancelOrder(orderIds[1]);
        hook.cancelOrder(orderIds[3]);
        vm.stopPrank();
        
        uint256[] memory bucketAfterCancel = hook.getTickBucket(tick);
        assertEq(bucketAfterCancel.length, 3, "Should have 3 orders after 2 cancels");
        
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
        
        uint256[] memory bucketAfterExec = hook.getTickBucket(tick);
        assertLt(
            bucketAfterExec.length, 
            bucketAfterCancel.length, 
            "Bucket should shrink after execution"
        );
    }

    function testBatchExecution() public {
        // TODO Phase 2.6: Test gas limits for executing multiple orders
        // Currently MVP executes 1 order per swap for safety
        vm.skip(true); // Skip for now
    }
}
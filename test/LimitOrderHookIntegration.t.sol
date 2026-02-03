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
    
    address alice = address(0xABCD);
    address bob = address(0x1234);

    function setUp() public {
        manager = new PoolManager(address(this));
        
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        
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
        vm.startPrank(alice);
        
        uint96 amountIn = 1e18;
        
        // ✅ FIX: Alice хочет КУПИТЬ token0 за token1 (zeroForOne: false)
        token1.approve(address(hook), amountIn);  // ✅ Approve token1
        
        // ✅ Trigger price ВЫШЕ текущей (Alice ждёт, пока цена вырастет)
        uint256 orderId = hook.createLimitOrder(poolKey, false, amountIn, 1.05e18);
        
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        
        console2.log("=== BEFORE TRIGGER SWAP ===");
        console2.log("Alice token0:", aliceToken0Before);
        console2.log("Alice token1:", aliceToken1Before);
        
        vm.stopPrank();

        vm.startPrank(bob);
        
        token1.approve(address(swapRouter), 500e18);
        
        console2.log("=== BOB TRIGGERS SWAP ===");
        console2.log("Bob buying token0 with token1...");
        
        // Bob покупает token0 → цена растёт → достигается 1.05
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -500e18,
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
        assertGt(token0.balanceOf(alice), aliceToken0Before, "Alice should receive token0");
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
        vm.expectRevert(LimitOrderHook.UnauthorizedCancellation.selector);
        hook.cancelOrder(orderId);
        vm.stopPrank();
    }

    function testZeroAmountFails() public {
        vm.prank(alice);
        vm.expectRevert(LimitOrderHook.InvalidAmount.selector);
        hook.createLimitOrder(poolKey, true, 0, 2e18);
    }
}
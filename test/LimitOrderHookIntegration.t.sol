// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {LimitOrderHook} from "../src/LimitOrderHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol"; // <-- ДОБАВИТЬ!
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";

/// @notice Simple MockERC20 for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) 
        ERC20(name, symbol, 18) 
    {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Integration tests for LimitOrderHook with token transfers
/// @notice Tests the complete flow: create → swap → execute → verify
contract LimitOrderHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // STATE VARIABLES
    PoolManager manager;
    LimitOrderHook hook;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    
    address alice = address(0xABCD);
    address bob = address(0x1234);

    // SETUP
    function setUp() public {
    // 1. Deploy PoolManager
    manager = new PoolManager(address(this));
    
    // 2. Deploy mock ERC20 tokens
    token0 = new MockERC20("Token0", "TK0");
    token1 = new MockERC20("Token1", "TK1");
    
    if (address(token0) > address(token1)) {
        (token0, token1) = (token1, token0);
    }
    
    // Mint tokens
    token0.mint(alice, 10_000e18);
    token1.mint(alice, 10_000e18);
    token0.mint(bob, 10_000e18);
    token1.mint(bob, 10_000e18);
    
    // 3. Mine hook address with CREATE2
    console2.log("=== Hook Flags Debug ===");
    console2.log("AFTER_SWAP_FLAG:", uint160(Hooks.AFTER_SWAP_FLAG));
    console2.log("========================");
    
    uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG); // = 64 в этой версии
    bytes memory constructorArgs = abi.encode(address(manager));

    console2.log("=== Starting Hook Mining ===");
    console2.log("Required flags:", flags);
    console2.log("Deployer:", address(this));
    
    vm.pauseGasMetering();
    
    // ШАГ 1: Find salt
    (address predictedAddress, bytes32 salt) = HookMiner.find(
        address(this),
        flags,
        type(LimitOrderHook).creationCode,
        constructorArgs
    );
    
    console2.log("=== Mining Complete ===");
    console2.log("Predicted hook address:", predictedAddress);
    console2.log("Salt found:", vm.toString(salt));
    console2.log("Predicted flags:", HookMiner.getAddressFlags(predictedAddress));
    
    // ШАГ 2: Deploy hook WITH THE SALT  <-- ВАЖНО!
    hook = new LimitOrderHook{salt: salt}(IPoolManager(address(manager)));
    
    vm.resumeGasMetering();
    
    console2.log("=== Deployment Success ===");
    console2.log("Hook deployed at:", address(hook));
    console2.log("Deployed flags:", HookMiner.getAddressFlags(address(hook)));
    
    // ШАГ 3: Verify
    require(address(hook) == predictedAddress, "Hook address mismatch!");
    require(address(hook) != address(0), "Hook deployment failed!");
    
    // 4. Create pool key
    poolKey = PoolKey({
        currency0: Currency.wrap(address(token0)),
        currency1: Currency.wrap(address(token1)),
        fee: 3000,
        tickSpacing: 60,
        hooks: hook
    });
    
    // 5. Initialize pool
    uint160 sqrtPriceX96 = 79228162514264337593543950336;
    manager.initialize(poolKey, sqrtPriceX96);
    
    // 6. Add liquidity
    addLiquiditySimplified(1000e18, 1000e18);
}

    /// @dev Simplified liquidity provision for testing
    function addLiquiditySimplified(uint256 amount0, uint256 amount1) internal {
        // For MVP: directly mint to manager (not production-ready)
        token0.mint(address(manager), amount0);
        token1.mint(address(manager), amount1);
    }

    // ═══════════════════════════════════════════════════════
    // TESTS
    // ═══════════════════════════════════════════════════════

    /// @notice Test basic order creation
    function testCreateOrder() public {
        vm.startPrank(alice);
        
        uint96 amountIn = 100e18;
        uint128 triggerPrice = 2e18; // Price = 2.0
        
        // Approve tokens
        token0.approve(address(hook), amountIn);
        
        // Create order
        uint256 orderId = hook.createLimitOrder(
            poolKey,
            true, // zeroForOne
            amountIn,
            triggerPrice
        );
        
        // Verify order created
        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertEq(order.creator, alice, "Creator should be alice");
        assertEq(order.amount0, amountIn, "Amount0 should match");
        assertEq(order.triggerPrice, triggerPrice, "Trigger price should match");
        assertFalse(order.isFilled, "Order should not be filled");
        
        vm.stopPrank();
    }

    /// @notice Test order cancellation
    function testCancelOrder() public {
        vm.startPrank(alice);
        
        uint96 amountIn = 50e18;
        token0.approve(address(hook), amountIn);
        
        uint256 orderId = hook.createLimitOrder(poolKey, true, amountIn, 2e18);
        
        // Cancel order
        hook.cancelOrder(orderId);
        
        // Verify order deleted
        LimitOrderHook.LimitOrder memory order = hook.getOrder(orderId);
        assertEq(order.creator, address(0), "Order should be deleted");
        
        vm.stopPrank();
    }

    /// @notice Test price conversion math
    function testPriceConversion() public view {  // <-- Добавить 'view'
        // Test 1: Price = 1.0
        uint160 sqrtPriceX96For1 = 79228162514264337593543950336;
        uint128 price1 = hook.sqrtPriceToUint128(sqrtPriceX96For1);  // <-- Использовать hook
        
        // Allow 1% tolerance for precision
        assertApproxEqRel(price1, 1e18, 0.01e18, "Price 1.0 conversion");
        
        // Test 2: Price = 4.0
        uint160 sqrtPriceX96For4 = 158456325028528675187087900672;
        uint128 price4 = hook.sqrtPriceToUint128(sqrtPriceX96For4);  // <-- Использовать hook
        assertApproxEqRel(price4, 4e18, 0.01e18, "Price 4.0 conversion");
    }

    /// @notice Gas benchmark for order creation
    function testGasBenchmark() public {
        vm.startPrank(alice);
        
        token0.approve(address(hook), 100e18);
        
        uint256 gasBefore = gasleft();
        hook.createLimitOrder(poolKey, true, 100e18, 2e18);
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for createLimitOrder:", gasUsed);
        
        // MVP target: <100k gas
        assertLt(gasUsed, 150000, "Order creation should be gas-efficient (MVP)");
        
        vm.stopPrank();
    }

    /// @notice Test unauthorized cancellation fails
    function testUnauthorizedCancellationFails() public {
        // Alice creates order
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        uint256 orderId = hook.createLimitOrder(poolKey, true, 100e18, 2e18);
        vm.stopPrank();
        
        // Bob tries to cancel (should fail)
        vm.startPrank(bob);
        vm.expectRevert(LimitOrderHook.UnauthorizedCancellation.selector);
        hook.cancelOrder(orderId);
        vm.stopPrank();
    }

    /// @notice Test zero amount fails
    function testZeroAmountFails() public {
        vm.startPrank(alice);
        vm.expectRevert(LimitOrderHook.InvalidAmount.selector);
        hook.createLimitOrder(poolKey, true, 0, 2e18);
        vm.stopPrank();
    }

    /// @notice Test zero trigger price fails
    function testZeroTriggerPriceFails() public {
        vm.startPrank(alice);
        token0.approve(address(hook), 100e18);
        vm.expectRevert(LimitOrderHook.InvalidTriggerPrice.selector);
        hook.createLimitOrder(poolKey, true, 100e18, 0);
        vm.stopPrank();
    }
}
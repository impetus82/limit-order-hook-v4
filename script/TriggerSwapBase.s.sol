// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title TriggerSwapBase - Execute a micro-swap on Base to trigger limit order fills
/// @notice Swaps USDC → WETH to push the WETH/USDC price UP, triggering sell orders.
/// @dev
///   Order #1: Sell 0.0001 WETH @ 3500 USDC/WETH (zeroForOne=true)
///   To trigger: price must reach ≥ 3500 → we BUY WETH with USDC (zeroForOne=false)
///
///   IMPORTANT: Pool must have liquidity BEFORE running this script.
///   Run AddLiquidityBase.s.sol first.
///
///   Usage:
///     source .env
///     forge script script/TriggerSwapBase.s.sol:TriggerSwapBase \
///       --rpc-url $BASE_RPC_URL --broadcast \
///       --with-gas-price 100000000 -vvvv
contract TriggerSwapBase is Script, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ── Addresses (Base Mainnet) ────────────────────────────
    IPoolManager constant POOL_MANAGER =
        IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant HOOK = 0x02C72A5E1125AD6f4B8D71E87af14BC8663b0040;

    // ── Pool parameters ─────────────────────────────────────
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // ── Swap amount ─────────────────────────────────────────
    // With micro-liquidity (~$10 total), even a tiny swap moves the price massively.
    // 5 USDC should be enough to push price well above 3500 in a near-empty pool.
    // Adjust if needed: increase for larger liquidity pools.
    uint256 constant SWAP_AMOUNT_USDC = 5e6; // 5 USDC (6 decimals)

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console2.log("=== Trigger Swap on Base WETH/USDC ===");
        console2.log("Deployer:", deployer);
        console2.log("Direction: Buy WETH with USDC (push price UP)");
        console2.log("Amount: 5 USDC");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        // Read current pool state
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceBefore, int24 tickBefore, , ) = POOL_MANAGER.getSlot0(poolId);
        uint128 liquidity = POOL_MANAGER.getLiquidity(poolId);

        console2.log("Current sqrtPriceX96:", uint256(sqrtPriceBefore));
        console2.log("Current tick:", tickBefore);
        console2.log("Liquidity:", uint256(liquidity));

        require(liquidity > 0, "Pool has 0 liquidity! Run AddLiquidityBase first.");

        // Check USDC balance
        uint256 usdcBal = IERC20(USDC).balanceOf(deployer);
        console2.log("USDC balance:", usdcBal);
        require(usdcBal >= SWAP_AMOUNT_USDC, "Need at least 5 USDC");

        vm.startBroadcast(deployerPk);

        // Approve PoolManager for USDC
        IERC20(USDC).approve(address(POOL_MANAGER), type(uint256).max);

        // Execute swap via unlock
        bytes memory callbackData = abi.encode(poolKey, deployer, SWAP_AMOUNT_USDC);
        POOL_MANAGER.unlock(callbackData);

        vm.stopBroadcast();

        // Read state after swap
        (uint160 sqrtPriceAfter, int24 tickAfter, , ) = POOL_MANAGER.getSlot0(poolId);
        console2.log("\n=== SWAP EXECUTED ===");
        console2.log("sqrtPriceX96 after:", uint256(sqrtPriceAfter));
        console2.log("tick after:", tickAfter);
        console2.log("Price should have moved UP. Check order status with cast.");
    }

    /// @notice Callback from PoolManager.unlock()
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "Only PoolManager");

        (PoolKey memory poolKey, address deployer, uint256 amountIn) =
            abi.decode(data, (PoolKey, address, uint256));

        // Swap: sell USDC (token1) for WETH (token0)
        // zeroForOne = false means: input is token1, output is token0
        // amountSpecified < 0 means: exact input
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,                            // sell token1 (USDC) → buy token0 (WETH)
            amountSpecified: -int256(amountIn),           // exact input: 5 USDC
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 // no upper limit
        });

        BalanceDelta delta = POOL_MANAGER.swap(poolKey, swapParams, "");

        console2.log("Swap delta amount0 (WETH received):", int256(delta.amount0()));
        console2.log("Swap delta amount1 (USDC spent):", int256(delta.amount1()));

        // Settle USDC (we owe it to the pool)
        // delta.amount1() is negative = we owe this amount
        if (delta.amount1() < 0) {
            uint256 owed = uint256(uint128(-delta.amount1()));
            POOL_MANAGER.sync(poolKey.currency1);
            IERC20(Currency.unwrap(poolKey.currency1)).transferFrom(
                deployer, address(POOL_MANAGER), owed
            );
            POOL_MANAGER.settle();
        }

        // Take WETH (pool owes us)
        // delta.amount0() is positive = pool owes us this amount
        if (delta.amount0() > 0) {
            POOL_MANAGER.take(
                poolKey.currency0,
                deployer,
                uint256(uint128(delta.amount0()))
            );
        }

        return "";
    }
}
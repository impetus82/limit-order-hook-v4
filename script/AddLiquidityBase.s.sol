// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @title AddLiquidityBase - Add micro liquidity to WETH/USDC pool on Base
/// @notice Adds a tiny position ($5-10 worth) across the widest possible tick range
/// @dev This script uses PoolManager.modifyLiquidity() directly via unlock callback.
///
/// Usage:
///   source .env
///   forge script script/AddLiquidityBase.s.sol:AddLiquidityBase \
///     --rpc-url $BASE_RPC_URL --broadcast \
///     --with-gas-price 100000000 -vvvv
contract AddLiquidityBase is Script, IUnlockCallback {
    // ── Addresses (Base Mainnet) ────────────────────────────
    IPoolManager constant POOL_MANAGER =
        IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant HOOK = 0x02C72A5E1125AD6f4B8D71E87af14BC8663b0040;

    // ── Pool parameters (must match pool initialization) ────
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    // ── Liquidity range: widest possible, aligned to tickSpacing=60 ──
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    // ── Liquidity amount ────────────────────────────────────
    // Very small: ~0.002 WETH ≈ $5-7 at ~$3000/ETH
    int256 constant LIQUIDITY_DELTA = 1e15;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        console2.log("=== Add Liquidity to Base WETH/USDC Pool ===");
        console2.log("Deployer:", deployer);

        // Build PoolKey (currency0 < currency1 by address sort)
        // WETH (0x4200...) < USDC (0x8335...) ✓
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        // Check balances before
        uint256 wethBal = IERC20(WETH).balanceOf(deployer);
        uint256 usdcBal = IERC20(USDC).balanceOf(deployer);
        console2.log("WETH balance:", wethBal);
        console2.log("USDC balance:", usdcBal);

        require(wethBal >= 0.003 ether, "Need at least 0.003 WETH");
        require(usdcBal >= 10e6, "Need at least 10 USDC");

        vm.startBroadcast(deployerPk);

        // Approve PoolManager to spend tokens
        IERC20(WETH).approve(address(POOL_MANAGER), type(uint256).max);
        IERC20(USDC).approve(address(POOL_MANAGER), type(uint256).max);

        // modifyLiquidity via unlock callback
        bytes memory callbackData = abi.encode(poolKey, deployer);
        POOL_MANAGER.unlock(callbackData);

        vm.stopBroadcast();

        // Check balances after
        uint256 wethAfter = IERC20(WETH).balanceOf(deployer);
        uint256 usdcAfter = IERC20(USDC).balanceOf(deployer);
        console2.log("\n=== LIQUIDITY ADDED ===");
        console2.log("WETH spent:", wethBal - wethAfter);
        console2.log("USDC spent:", usdcBal - usdcAfter);
    }

    /// @notice Callback from PoolManager.unlock()
    /// @dev Called by PoolManager; must settle token debts via sync+transfer+settle
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "Only PoolManager");

        (PoolKey memory poolKey, address deployer) = abi.decode(data, (PoolKey, address));

        // Add liquidity
        (BalanceDelta delta, ) = POOL_MANAGER.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQUIDITY_DELTA,
                salt: bytes32(0)
            }),
            ""
        );

        console2.log("Delta amount0 (WETH):", int256(delta.amount0()));
        console2.log("Delta amount1 (USDC):", int256(delta.amount1()));

        // Settle: pay tokens owed to PoolManager
        // amount0 and amount1 in delta are negative = we owe the pool
        if (delta.amount0() < 0) {
            uint256 owed0 = uint256(uint128(-delta.amount0()));
            POOL_MANAGER.sync(poolKey.currency0);
            IERC20(Currency.unwrap(poolKey.currency0)).transferFrom(
                deployer, address(POOL_MANAGER), owed0
            );
            POOL_MANAGER.settle();
        }
        if (delta.amount1() < 0) {
            uint256 owed1 = uint256(uint128(-delta.amount1()));
            POOL_MANAGER.sync(poolKey.currency1);
            IERC20(Currency.unwrap(poolKey.currency1)).transferFrom(
                deployer, address(POOL_MANAGER), owed1
            );
            POOL_MANAGER.settle();
        }

        // If any positive delta (shouldn't happen on add), take it
        if (delta.amount0() > 0) {
            POOL_MANAGER.take(poolKey.currency0, deployer, uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            POOL_MANAGER.take(poolKey.currency1, deployer, uint256(uint128(delta.amount1())));
        }

        return "";
    }
}
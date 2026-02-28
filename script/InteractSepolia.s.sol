// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LimitOrderHook} from "../src/LimitOrderHook.sol";

/// @title InteractSepolia — Live interaction with LimitOrderHook on Sepolia
/// @author Yuri (Crypto Side Hustle 2026)
/// @dev Phase 3.5: Create orders, execute swaps, cancel orders on testnet.
///
///   Usage (pick one action at a time):
///
///   # Action 1: Create a limit order
///   forge script script/InteractSepolia.s.sol:CreateOrder \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
///
///   # Action 2: Execute a swap (trigger order fills)
///   forge script script/InteractSepolia.s.sol:ExecuteSwap \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
///
///   # Action 3: Cancel an order
///   ORDER_ID=0 forge script script/InteractSepolia.s.sol:CancelOrder \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
///
///   Prerequisites:
///   - SetupSepolia.s.sol already executed (tokens deployed, pool initialized, liquidity added)
///   - .env configured with SEPOLIA_RPC_URL, PRIVATE_KEY

// ============================================================
//  SHARED CONFIGURATION
// ============================================================
abstract contract SepoliaConfig is Script {
    // --- Deployed addresses from Phase 3.3 + 3.4 ---
    address constant HOOK = 0xF1825a46608cadA9AFc3290397Ba7C77797E4040;
    address constant TOKEN0 = 0x7AfF4F1a79d86095A6E2eBEF1dcfF7c263e55970; // TTA (sorted)
    address constant TOKEN1 = 0xc1Fb22AE10BDB0545737825998BE99569b64E931; // TTB (sorted)
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // --- Pool parameters (must match SetupSepolia) ---
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;

    function _buildPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function _deployerKey() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    function _deployer() internal view returns (address) {
        return vm.addr(_deployerKey());
    }
}

// ============================================================
//  ACTION 1: CREATE LIMIT ORDER
// ============================================================
/// @notice Mints TTA, approves hook, creates a sell-token0 limit order.
///         Default: sell 10 TTA when price >= 1.01 (scaled 1e18).
contract CreateOrder is SepoliaConfig {
    uint96 constant ORDER_AMOUNT = 10 ether; // 10 TTA
    uint128 constant TRIGGER_PRICE = 1.01e18; // price >= 1.01 to fill

    function run() external {
        uint256 pk = _deployerKey();
        address deployer = _deployer();

        console2.log("=== Create Limit Order (Sepolia) ===");
        console2.log("Deployer:", deployer);
        console2.log("Hook:", HOOK);
        console2.log("Selling: TTA (token0), Amount:", uint256(ORDER_AMOUNT));
        console2.log("Trigger Price (1e18):", uint256(TRIGGER_PRICE));

        vm.startBroadcast(pk);

        // Step 1: Mint TTA to deployer (MockERC20 has public mint)
        MockERC20(TOKEN0).mint(deployer, uint256(ORDER_AMOUNT));
        console2.log("Minted TTA to deployer");

        // Step 2: Approve hook to pull TTA
        IERC20(TOKEN0).approve(HOOK, uint256(ORDER_AMOUNT));
        console2.log("Approved hook for TTA");

        // Step 3: Create the limit order
        PoolKey memory poolKey = _buildPoolKey();
        uint256 orderId = LimitOrderHook(HOOK).createLimitOrder(
            poolKey,
            true, // zeroForOne = sell token0 for token1
            ORDER_AMOUNT,
            TRIGGER_PRICE
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== ORDER CREATED ===");
        console2.log("Order ID:", orderId);
        console2.log("Direction: Sell TTA (token0) -> Receive TTB (token1)");
        console2.log("Amount:", uint256(ORDER_AMOUNT));
        console2.log("Trigger: price >= 1.01");
        console2.log("");
        console2.log("Next: Run ExecuteSwap to trigger this order");
    }
}

// ============================================================
//  ACTION 2: EXECUTE SWAP (move price to trigger orders)
// ============================================================
/// @notice Deploys a PoolSwapTest router, mints TTB, swaps TTB->TTA to push
///         the price UP (making token0 more expensive), which should trigger
///         zeroForOne sell orders.
contract ExecuteSwap is SepoliaConfig {
    uint256 constant SWAP_AMOUNT = 50000 ether; // 500 TTB — достаточно для ~1-2% движения цены

    function run() external {
        uint256 pk = _deployerKey();
        address deployer = _deployer();

        console2.log("=== Execute Swap (Sepolia) ===");
        console2.log("Deployer:", deployer);
        console2.log("Swap: 500 TTB -> TTA (push price UP ~1-2%)");

        vm.startBroadcast(pk);

        // Step 1: Deploy PoolSwapTest router
        // NOTE: No canonical PoolSwapTest on Sepolia, so we deploy our own.
        // This is a test helper from v4-core, safe for testnet use.
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        console2.log("SwapRouter deployed:", address(swapRouter));

        // Step 2: Mint TTB to deployer
        MockERC20(TOKEN1).mint(deployer, SWAP_AMOUNT);
        console2.log("Minted TTB to deployer");

        // Step 3: Approve router for TTB
        IERC20(TOKEN1).approve(address(swapRouter), SWAP_AMOUNT);
        console2.log("Approved SwapRouter for TTB");

        // Step 4: Execute swap — sell TTB (token1) for TTA (token0)
        // zeroForOne = false means: selling token1 for token0
        // amountSpecified < 0 means: exact input
        PoolKey memory poolKey = _buildPoolKey();

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false, // sell token1 -> buy token0
            amountSpecified: -int256(SWAP_AMOUNT), // exact input
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 // no price limit (buying token0 pushes price up)
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, swapParams, testSettings, "");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== SWAP EXECUTED ===");
        console2.log("Swapped 500 TTB -> TTA");
        console2.log("Price should have moved UP");
        console2.log("Any sell orders with triggerPrice <= new price should be filled");
        console2.log("");
        console2.log("Check order status with: cast call", HOOK);
        console2.log("  'getOrder(uint256)(address,uint96,uint96,address,address,uint128,uint64,bool,bool)' <ORDER_ID>");
    }
}

// ============================================================
//  ACTION 3: CANCEL ORDER
// ============================================================
/// @notice Cancels an existing order by ID. Set ORDER_ID env var before running.
contract CancelOrder is SepoliaConfig {
    function run() external {
        uint256 pk = _deployerKey();
        address deployer = _deployer();

        // Read ORDER_ID from environment (default 0 for testing)
        uint256 orderId = vm.envOr("ORDER_ID", uint256(0));

        console2.log("=== Cancel Order (Sepolia) ===");
        console2.log("Deployer:", deployer);
        console2.log("Order ID:", orderId);

        // Read order state before cancel
        LimitOrderHook hookContract = LimitOrderHook(HOOK);
        (
            address creator,
            uint96 amount0,
            uint96 amount1,
            , // token0
            , // token1
            uint128 triggerPrice,
            , // createdAt
            bool isFilled,
            bool zeroForOne
        ) = hookContract.orders(orderId);

        console2.log("Order creator:", creator);
        console2.log("Is filled:", isFilled);
        console2.log("zeroForOne:", zeroForOne);
        console2.log("amount0:", uint256(amount0));
        console2.log("amount1:", uint256(amount1));
        console2.log("triggerPrice:", uint256(triggerPrice));

        require(creator == deployer, "Not your order!");
        require(!isFilled, "Order already filled!");

        vm.startBroadcast(pk);

        hookContract.cancelOrder(orderId);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== ORDER CANCELLED ===");
        console2.log("Tokens refunded to:", deployer);
    }
}

// ============================================================
//  UTILITY: READ ORDER STATUS (no broadcast needed)
// ============================================================
/// @notice Read-only: check order status and pool price.
///   forge script script/InteractSepolia.s.sol:ReadStatus \
///     --rpc-url $SEPOLIA_RPC_URL -vvvv
contract ReadStatus is SepoliaConfig {
    function run() external view {
        address deployer = _deployer();
        LimitOrderHook hookContract = LimitOrderHook(HOOK);

        console2.log("=== Read Status (Sepolia) ===");
        console2.log("Hook:", HOOK);
        console2.log("Deployer:", deployer);

        // Next order ID (shows how many orders exist)
        uint256 nextId = hookContract.nextOrderId();
        console2.log("Total orders created:", nextId);

        // Read last few orders
        uint256 start = nextId > 5 ? nextId - 5 : 0;
        for (uint256 i = start; i < nextId; i++) {
            (
                address creator,
                uint96 amount0,
                uint96 amount1,
                , ,
                uint128 triggerPrice,
                ,
                bool isFilled,
                bool zeroForOne
            ) = hookContract.orders(i);

            console2.log("---");
            console2.log("Order", i, "creator:", creator);
            console2.log("  filled:", isFilled, "zeroForOne:", zeroForOne);
            console2.log("  amount0:", uint256(amount0), "amount1:", uint256(amount1));
            console2.log("  triggerPrice:", uint256(triggerPrice));
        }

        // Token balances
        console2.log("---");
        console2.log("TTA balance (deployer):", IERC20(TOKEN0).balanceOf(deployer));
        console2.log("TTB balance (deployer):", IERC20(TOKEN1).balanceOf(deployer));
        console2.log("TTA balance (hook):", IERC20(TOKEN0).balanceOf(HOOK));
        console2.log("TTB balance (hook):", IERC20(TOKEN1).balanceOf(HOOK));
    }
}
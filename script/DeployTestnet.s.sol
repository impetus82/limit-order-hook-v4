// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LimitOrderHook} from "../src/LimitOrderHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title DeployTestnet — Deploy LimitOrderHook to Sepolia via CREATE2
/// @notice Uses HookMiner to find a salt producing an address with the correct
///         permission flags (beforeSwap + beforeSwapReturnDelta).
///
/// @dev Usage:
///   1. Create `.env` with SEPOLIA_RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY
///   2. Run:
///      source .env
///      forge script script/DeployTestnet.s.sol:DeployTestnet \
///        --rpc-url $SEPOLIA_RPC_URL \
///        --broadcast \
///        --verify \
///        -vvvv
///
///   3. After deploy, verify on Etherscan:
///      forge verify-contract <HOOK_ADDRESS> src/LimitOrderHook.sol:LimitOrderHook \
///        --chain sepolia \
///        --constructor-args $(cast abi-encode "constructor(address)" <POOL_MANAGER>)
contract DeployTestnet is Script {
    // ========================================================================
    // Uniswap V4 PoolManager addresses per network
    // Update these when official deployments are confirmed.
    // Check: https://docs.uniswap.org/contracts/v4/deployments
    // ========================================================================

    /// @dev Sepolia PoolManager — replace with actual address once V4 is live
    ///      As of Feb 2026, check Uniswap docs for the latest deployment.
    ///      If V4 is not yet on Sepolia, deploy your own PoolManager first.
    address constant POOL_MANAGER_SEPOLIA = 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A;

    // ========================================================================
    // Hook permission flags
    // ========================================================================

    /// @dev beforeSwap (bit 7) + beforeSwapReturnDelta (bit 13)
    ///      = 0x0040 | 0x2000 = 0x2040
    ///      Verify with: uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        // ---- Load deployer key ----
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== LimitOrderHook Testnet Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", POOL_MANAGER_SEPOLIA);
        console2.log("Required flags:", uint256(HOOK_FLAGS));

        // ---- Mine salt for correct hook address ----
        console2.log("\nMining salt for CREATE2 address...");

        bytes memory creationCode = type(LimitOrderHook).creationCode;
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER_SEPOLIA));

        (address predictedAddr, bytes32 salt) = HookMiner.find(
            deployer,
            HOOK_FLAGS,
            creationCode,
            constructorArgs
        );

        console2.log("Predicted hook address:", predictedAddr);
        console2.log("Salt:", uint256(salt));
        console2.log("Address flags:", uint256(HookMiner.getAddressFlags(predictedAddr)));

        // ---- Deploy ----
        vm.startBroadcast(deployerPrivateKey);

        LimitOrderHook hook = new LimitOrderHook{salt: salt}(
            IPoolManager(POOL_MANAGER_SEPOLIA)
        );

        vm.stopBroadcast();

        // ---- Verify ----
        require(address(hook) == predictedAddr, "Deploy: address mismatch!");

        console2.log("\n=== DEPLOYMENT SUCCESSFUL ===");
        console2.log("Hook deployed at:", address(hook));
        console2.log("Owner:", hook.owner());
        console2.log("Gas limit per order:", hook.GAS_LIMIT_PER_ORDER());
        console2.log("Tick range width:", uint256(int256(hook.TICK_RANGE_WIDTH())));

        // ---- Log verification command ----
        console2.log("\n--- Next Steps ---");
        console2.log("1. Verify on Etherscan:");
        console2.log("   forge verify-contract", address(hook));
        console2.log("2. Initialize a pool with this hook");
        console2.log("3. Test createLimitOrder via cast send");
    }
}
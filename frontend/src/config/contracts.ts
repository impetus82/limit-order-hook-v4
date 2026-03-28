import abiJson from "./abi.json";

// ── Hook Contract (Base Mainnet) ────────────────────────
export const LIMIT_ORDER_HOOK = {
  address: "0x02C72A5E1125AD6f4B8D71E87af14BC8663b0040" as const,
  abi: abiJson.abi,
} as const;

// ── Uniswap V4 StateView (Base Mainnet) ─────────────────
// StateView is a dedicated offchain-read contract that wraps
// PoolManager's extsload calls via StateLibrary.
// Source: https://docs.uniswap.org/contracts/v4/deployments
export const STATE_VIEW = {
  address: "0xa3c0c9b65bad0b08107aa264b0f3db444b867a71" as const,
  abi: [
    {
      name: "getSlot0",
      type: "function",
      stateMutability: "view",
      inputs: [{ name: "poolId", type: "bytes32" }],
      outputs: [
        { name: "sqrtPriceX96", type: "uint160" },
        { name: "tick", type: "int24" },
        { name: "protocolFee", type: "uint24" },
        { name: "lpFee", type: "uint24" },
      ],
    },
    {
      name: "getLiquidity",
      type: "function",
      stateMutability: "view",
      inputs: [{ name: "poolId", type: "bytes32" }],
      outputs: [{ name: "liquidity", type: "uint128" }],
    },
  ] as const,
} as const;

// ── Pool ID ─────────────────────────────────────────────
// TODO: Replace with actual PoolId from SetupBase.s.sol output!
// Run the script, copy the logged bytes32 value here.
export const POOL_ID =
  "0x9ab80bf349a3a10edc42141e23d29ab0cbaf02e7d43c75a3b30ebf0088faaa60" as const;

// ── Base Mainnet Pool Parameters ────────────────────────
export const POOL_FEE = 3000;
export const TICK_SPACING = 60;

// ── Real Tokens (Base Mainnet) ──────────────────────────
// WETH: 0x4200... < USDC: 0x8335...  →  currency0 = WETH, currency1 = USDC
export const TOKEN_WETH = {
  address: "0x4200000000000000000000000000000000000006" as const,
  symbol: "WETH",
  name: "Wrapped Ether",
  decimals: 18,
} as const;

export const TOKEN_USDC = {
  address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as const,
  symbol: "USDC",
  name: "USD Coin",
  decimals: 6,
} as const;

// Aliases matching old TTA/TTB pattern (currency0 = WETH, currency1 = USDC)
export const TOKEN_0 = TOKEN_WETH;
export const TOKEN_1 = TOKEN_USDC;

// currency0 < currency1 (sorted by address for Uniswap V4 PoolKey)
// WETH (0x4200...) < USDC (0x8335...) ✅
export const POOL_KEY = {
  currency0: TOKEN_WETH.address,
  currency1: TOKEN_USDC.address,
  fee: POOL_FEE,
  tickSpacing: TICK_SPACING,
  hooks: LIMIT_ORDER_HOOK.address,
} as const;

// ── Minimal ERC20 ABI (approve + allowance + balanceOf) ─
export const ERC20_ABI = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "allowance",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "symbol",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    name: "decimals",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

// ── Legacy aliases for backward compatibility ───────────
// Components that import TOKEN_TTA/TOKEN_TTB will still work
export const TOKEN_TTA = TOKEN_WETH;
export const TOKEN_TTB = TOKEN_USDC;

// ── Block explorer base URL ─────────────────────────────
export const EXPLORER_URL = "https://basescan.org";
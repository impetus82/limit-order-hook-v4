import abiJson from "./abi.json";

// ── Hook Contract ───────────────────────────────────────
export const LIMIT_ORDER_HOOK = {
  address: "0x43BF7DA3d2e26D295a8965109505767e93B24040" as const,
  abi: abiJson.abi,
} as const;

// ── Uniswap V4 StateView (Sepolia) ─────────────────────
// StateView is a dedicated offchain-read contract that wraps
// PoolManager's extsload calls via StateLibrary.
// PoolManager itself does NOT expose getSlot0 in its ABI —
// StateLibrary is an internal Solidity library that uses extsload.
// For frontend reads, we MUST use StateView.
export const STATE_VIEW = {
  address: "0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c" as const,
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

// ── Pool ID (keccak256 of PoolKey, from Phase 3 deploy) ─
export const POOL_ID =
  "0xe3c209028461da8adcc98df49199e8b6c42b5051186c2d7c8ec1e97451955791" as const;

// ── Sepolia Pool Parameters ─────────────────────────────
export const POOL_FEE = 3000;
export const TICK_SPACING = 60;

// ── Test Tokens (Phase 3.15 deploy) ─────────────────────
export const TOKEN_TTA = {
  address: "0x5367BdE916282818fa3EE2c27ecbC79672D364ed" as const,
  symbol: "TTA",
  name: "Test Token A",
  decimals: 18,
} as const;

export const TOKEN_TTB = {
  address: "0xfa6b4B169D5BC4d12bD07B3f8230a619E3c1f20e" as const,
  symbol: "TTB",
  name: "Test Token B",
  decimals: 18,
} as const;

// currency0 < currency1 (sorted by address for Uniswap V4 PoolKey)
// TTA (0x9334...) < TTB (0xcD11...) ✅ so currency0 = TTA, currency1 = TTB
export const POOL_KEY = {
  currency0: TOKEN_TTA.address,
  currency1: TOKEN_TTB.address,
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
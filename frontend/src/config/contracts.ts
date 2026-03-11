import abiJson from "./abi.json";

// ── Hook Contract ───────────────────────────────────────
export const LIMIT_ORDER_HOOK = {
  address: "0x43BF7DA3d2e26D295a8965109505767e93B24040" as const,
  abi: abiJson.abi,
} as const;

// ── Sepolia Pool Parameters ─────────────────────────────
export const POOL_FEE = 3000;
export const TICK_SPACING = 60;

// ── Test Tokens (Phase 3.15 deploy) ─────────────────────
export const TOKEN_TTA = {
  address: "0x93345833027Ab2Ab863b812fA7cA9D5cfee883BC" as const,
  symbol: "TTA",
  name: "Test Token A",
  decimals: 18,
} as const;

export const TOKEN_TTB = {
  address: "0xcD11CC946B446088A987d3163E662C335C20d410" as const,
  symbol: "TTB",
  name: "Test Token B",
  decimals: 18,
} as const;

// currency0 < currency1 (sorted by address for Uniswap V4 PoolKey)
// TTA (0x9334...) > TTB (0xcD11...) — need to verify sorting!
// Actually: 0x9334... < 0xcD11... ✅ so currency0 = TTA, currency1 = TTB
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
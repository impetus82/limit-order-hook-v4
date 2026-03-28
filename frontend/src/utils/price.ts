/**
 * Uniswap V4 Price Utilities — WETH/USDC (Base Mainnet)
 *
 * Converts sqrtPriceX96 (Q64.96 fixed-point) to a human-readable decimal price.
 *
 * Formula:  price_raw = (sqrtPriceX96 / 2^96)^2
 *
 * CRITICAL: WETH has 18 decimals, USDC has 6 decimals.
 * currency0 = WETH (18), currency1 = USDC (6)
 *
 * price_raw represents "USDC raw units per WETH raw unit"
 * human_price = price_raw * 10^(decimals0 - decimals1) = price_raw * 10^12
 *
 * So: human_price = (sqrtPriceX96 / 2^96)^2 * 10^12
 */

const Q96 = BigInt(1) << BigInt(96); // 2^96
const PRICE_SCALE = BigInt(10) ** BigInt(18); // 1e18 for intermediate precision

// Decimal difference: WETH(18) - USDC(6) = 12
const DECIMAL_ADJUSTMENT = BigInt(10) ** BigInt(12); // 10^12

// Uniswap V4 tick boundaries
const MIN_TICK = -887272;
const MAX_TICK = 887272;

/**
 * Convert sqrtPriceX96 (BigInt) → human-readable price as a JS number.
 *
 * Returns the price of currency0 (WETH) denominated in currency1 (USDC).
 * e.g. returns ~3500.00 meaning 1 WETH = 3500 USDC.
 *
 * Strategy:
 *   price_scaled = (sqrtPriceX96^2 * DECIMAL_ADJUSTMENT * 1e18) / 2^192
 *   human_price = price_scaled / 1e18
 */
export function sqrtPriceX96ToPrice(sqrtPriceX96: bigint): number {
  if (sqrtPriceX96 === BigInt(0)) return 0;

  // price_raw_1e18 = (sqrtPriceX96^2 * 1e18) / 2^192
  // Then multiply by DECIMAL_ADJUSTMENT to get human price
  const numerator = sqrtPriceX96 * sqrtPriceX96 * PRICE_SCALE * DECIMAL_ADJUSTMENT;
  const denominator = Q96 * Q96; // 2^192
  const price1e18 = numerator / denominator;

  const integerPart = price1e18 / PRICE_SCALE;
  const fractionalPart = price1e18 % PRICE_SCALE;

  return Number(integerPart) + Number(fractionalPart) / 1e18;
}

/**
 * Check if a tick is at or near the Uniswap boundary (extreme price).
 * Threshold: within 100 ticks of min/max.
 */
export function isExtremeTick(tick: number): boolean {
  return tick >= MAX_TICK - 100 || tick <= MIN_TICK + 100;
}

/**
 * Format price for display with appropriate decimal places.
 * Optimized for USDC-denominated prices (typically $1000-$10000 range for ETH).
 */
export function formatPrice(price: number): string {
  if (price === 0) return "0.00";
  if (!Number.isFinite(price)) return "∞";
  if (price > 1e15) return "∞ (extreme)";
  if (price >= 100) return price.toFixed(2);    // 3500.12 USDC
  if (price >= 1) return price.toFixed(4);       // 1.0034
  if (price >= 0.0001) return price.toFixed(6);  // 0.000285
  if (price >= 1e-12) return price.toFixed(8);
  return "≈ 0";
}

/**
 * Inverse price: if price = USDC/WETH, then inverse = WETH/USDC.
 * For a price of 3500 USDC per WETH, inverse = 0.000285 WETH per USDC.
 */
export function invertPrice(price: number): number {
  if (price === 0 || !Number.isFinite(price) || price > 1e15) return 0;
  return 1 / price;
}
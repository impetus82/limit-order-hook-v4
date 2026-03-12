/**
 * Uniswap V4 Price Utilities
 *
 * Converts sqrtPriceX96 (Q64.96 fixed-point) to a human-readable decimal price.
 *
 * Formula:  price = (sqrtPriceX96 / 2^96)^2
 *
 * Both TTA and TTB have 18 decimals, so no decimal adjustment is needed.
 */

const Q96 = BigInt(1) << BigInt(96); // 2^96
const PRICE_SCALE = BigInt(10) ** BigInt(18); // 1e18

// Uniswap V4 tick boundaries
const MIN_TICK = -887272;
const MAX_TICK = 887272;

/**
 * Convert sqrtPriceX96 (BigInt) → price as a JS number.
 *
 * Strategy: compute price_scaled = (sqrtPriceX96^2 * 1e18) / 2^192
 * then divide by 1e18 in floating point for the final result.
 */
export function sqrtPriceX96ToPrice(sqrtPriceX96: bigint): number {
  if (sqrtPriceX96 === BigInt(0)) return 0;

  const numerator = sqrtPriceX96 * sqrtPriceX96 * PRICE_SCALE;
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
 * Returns "∞" for extreme values that overflow JS Number.
 */
export function formatPrice(price: number): string {
  if (price === 0) return "0.0000";
  if (!Number.isFinite(price)) return "∞";
  if (price > 1e18) return "∞ (extreme)";
  if (price >= 1) return price.toFixed(4);
  if (price >= 0.0001) return price.toFixed(6);
  if (price >= 1e-12) return price.toFixed(8);
  return "≈ 0";
}

/**
 * Inverse price: if price = TTB/TTA, then inverse = TTA/TTB.
 */
export function invertPrice(price: number): number {
  if (price === 0 || !Number.isFinite(price) || price > 1e18) return 0;
  return 1 / price;
}
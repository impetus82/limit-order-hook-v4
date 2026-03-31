"use client";

import { useEffect } from "react";
import {
  useAccount,
  useChainId,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { formatUnits, zeroAddress, type Address } from "viem";
import {
  getChainContracts,
  HOOK_ABI,
} from "@/config/contracts";
import { getTriggerPriceConfig } from "@/utils/price";

// ── Types ────────────────────────────────────────────────
interface OrderData {
  creator: Address;
  amount0: bigint;
  amount1: bigint;
  token0: Address;
  token1: Address;
  triggerPrice: bigint;
  createdAt: bigint;
  isFilled: boolean;
  zeroForOne: boolean;
}

type OrderStatus = "active" | "filled" | "cancelled";

// ── OrderList (parent) ──────────────────────────────────
export default function OrderList({
  refetchKey,
}: {
  /** Increment to trigger refetch after create/cancel */
  refetchKey: number;
}) {
  const { address } = useAccount();
  const chainId = useChainId();
  const chain = getChainContracts(chainId);

  const hookContract = { address: chain.hook, abi: HOOK_ABI } as const;

  const {
    data: orderIds,
    isLoading,
    refetch: refetchIds,
  } = useReadContract({
    ...hookContract,
    functionName: "getUserOrders",
    args: address ? [address] : undefined,
    query: {
      enabled: !!address,
      refetchInterval: 12_000,
    },
  });

  useEffect(() => {
    if (address) refetchIds();
  }, [refetchKey, address, refetchIds]);

  if (!address) return null;

  const ids = (orderIds as bigint[] | undefined) ?? [];

  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900 p-6">
      <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-5">
        Your Orders
      </h3>

      {isLoading ? (
        <div className="space-y-3">
          {[1, 2].map((i) => (
            <div
              key={i}
              className="h-24 rounded-lg bg-gray-800 animate-pulse"
            />
          ))}
        </div>
      ) : ids.length === 0 ? (
        <p className="text-sm text-gray-600 text-center py-6">
          No orders yet. Place your first limit order above.
        </p>
      ) : (
        <div className="space-y-3">
          {ids.map((id) => (
            <OrderItem
              key={id.toString()}
              orderId={id}
              chainId={chainId}
              refetchKey={refetchKey}
              onCancelled={() => refetchIds()}
            />
          ))}
        </div>
      )}
    </div>
  );
}

// ── OrderItem (child) ───────────────────────────────────
function OrderItem({
  orderId,
  chainId,
  refetchKey,
  onCancelled,
}: {
  orderId: bigint;
  chainId: number;
  refetchKey: number;
  onCancelled: () => void;
}) {
  const chain = getChainContracts(chainId);
  const hookContract = { address: chain.hook, abi: HOOK_ABI } as const;
  const triggerPriceConfig = getTriggerPriceConfig(chain.wethIsCurrency0);

  const {
    data: orderRaw,
    isLoading,
    refetch: refetchOrder,
  } = useReadContract({
    ...hookContract,
    functionName: "getOrder",
    args: [orderId],
    query: { refetchInterval: 12_000 },
  });

  useEffect(() => {
    refetchOrder();
  }, [refetchKey, refetchOrder]);

  const { data: cancelHash, writeContract: cancelOrder } = useWriteContract();
  const { isSuccess: cancelConfirmed } = useWaitForTransactionReceipt({
    hash: cancelHash,
  });

  useEffect(() => {
    if (cancelConfirmed) {
      refetchOrder().then(() => onCancelled());
    }
  }, [cancelConfirmed, refetchOrder, onCancelled]);

  if (isLoading) {
    return <div className="h-24 rounded-lg bg-gray-800 animate-pulse" />;
  }

  const order = orderRaw as OrderData | undefined;
  if (!order) return null;

  const status: OrderStatus =
    order.creator === zeroAddress
      ? "cancelled"
      : order.isFilled
        ? "filled"
        : "active";

  // ── Direction & amounts (always show as WETH/USDC semantic) ──
  // On Base (wethIsCurrency0=true):
  //   zeroForOne=true  → selling WETH (token0) → "Sell WETH → USDC"
  //   zeroForOne=false → buying WETH (selling token1=USDC) → "Buy WETH ← USDC"
  // On Unichain (wethIsCurrency0=false):
  //   zeroForOne=true  → selling USDC (token0) → "Buy WETH ← USDC"
  //   zeroForOne=false → selling WETH (token1) → "Sell WETH → USDC"
  const isSellWeth = chain.wethIsCurrency0
    ? order.zeroForOne    // Base: zeroForOne=true means sell WETH
    : !order.zeroForOne;  // Unichain: zeroForOne=false means sell WETH

  const directionLabel = isSellWeth
    ? `Sell ${chain.weth.symbol} → ${chain.usdc.symbol}`
    : `Buy ${chain.weth.symbol} ← ${chain.usdc.symbol}`;

  const inputToken = isSellWeth ? chain.weth : chain.usdc;
  const outputToken = isSellWeth ? chain.usdc : chain.weth;

  // Adjust for Unichain: if not wethIsCurrency0, amounts are swapped
  // amount0 is always in currency0 terms, amount1 in currency1 terms
  // On Unichain: currency0=USDC, currency1=WETH
  const displayInputAmount = chain.wethIsCurrency0
    ? (isSellWeth ? order.amount0 : order.amount1)
    : (isSellWeth ? order.amount1 : order.amount0);
  const displayOutputAmount = chain.wethIsCurrency0
    ? (isSellWeth ? order.amount1 : order.amount0)
    : (isSellWeth ? order.amount0 : order.amount1);

  // ── Trigger price display ─────────────────────────────
  // Always show as "USDC per WETH"
  let triggerDisplay: number;
  if (triggerPriceConfig.needsInversion) {
    // Unichain: stored as WETH/USDC, display as USDC/WETH
    const storedNum = Number(order.triggerPrice) / 10 ** triggerPriceConfig.decimals;
    triggerDisplay = storedNum > 0 ? 1 / storedNum : 0;
  } else {
    // Base: stored as USDC/WETH
    triggerDisplay = Number(order.triggerPrice) / 10 ** triggerPriceConfig.decimals;
  }

  const handleCancel = () => {
    cancelOrder({
      ...hookContract,
      functionName: "cancelOrder",
      args: [orderId],
    });
  };

  const explorerName = chain.chainLabel === "BASE" ? "BaseScan" : "Uniscan";

  return (
    <div className="rounded-lg border border-gray-700 bg-gray-800/50 p-4">
      {/* Header row */}
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <span className="text-xs text-gray-500 font-mono">
            #{orderId.toString()}
          </span>
          <StatusBadge status={status} />
        </div>
        <span className="text-xs text-gray-500">{directionLabel}</span>
      </div>

      {/* Details */}
      <div className="grid grid-cols-2 gap-y-2 text-sm">
        <span className="text-gray-500">Input</span>
        <span className="text-right text-white font-mono">
          {formatUnits(displayInputAmount, inputToken.decimals)} {inputToken.symbol}
        </span>

        {status === "filled" && displayOutputAmount > 0n && (
          <>
            <span className="text-gray-500">Received</span>
            <span className="text-right text-emerald-400 font-mono">
              {formatUnits(displayOutputAmount, outputToken.decimals)}{" "}
              {outputToken.symbol}
            </span>
          </>
        )}

        <span className="text-gray-500">Trigger</span>
        <span className="text-right text-gray-300 font-mono">
          ≥ {triggerDisplay.toFixed(2)} USDC/WETH
        </span>
      </div>

      {/* Cancel button */}
      {status === "active" && (
        <button
          onClick={handleCancel}
          disabled={!!cancelHash && !cancelConfirmed}
          className="mt-3 w-full rounded-lg bg-red-900/30 border border-red-800/50 py-2 text-sm text-red-400 hover:bg-red-900/50 transition-colors disabled:opacity-50"
        >
          {cancelHash && !cancelConfirmed ? "Cancelling…" : "Cancel Order"}
        </button>
      )}

      {/* Cancel tx link */}
      {cancelHash && (
        <p className="text-xs text-gray-500 text-center mt-2">
          <a
            href={`${chain.explorerUrl}/tx/${cancelHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-blue-400/70 hover:text-blue-400 underline"
          >
            View on {explorerName} ↗
          </a>
        </p>
      )}
    </div>
  );
}

// ── StatusBadge ─────────────────────────────────────────
function StatusBadge({ status }: { status: OrderStatus }) {
  const styles: Record<OrderStatus, string> = {
    active: "bg-blue-900/40 text-blue-400 border-blue-800/50",
    filled: "bg-emerald-900/40 text-emerald-400 border-emerald-800/50",
    cancelled: "bg-gray-800 text-gray-500 border-gray-700",
  };

  return (
    <span
      className={`text-[11px] font-medium px-2 py-0.5 rounded-full border ${styles[status]}`}
    >
      {status.charAt(0).toUpperCase() + status.slice(1)}
    </span>
  );
}
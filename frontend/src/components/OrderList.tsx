"use client";

import { useEffect } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { formatEther, zeroAddress, type Address } from "viem";
import { LIMIT_ORDER_HOOK, TOKEN_TTA, TOKEN_TTB } from "@/config/contracts";

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

  const {
    data: orderIds,
    isLoading,
    refetch: refetchIds,
  } = useReadContract({
    ...LIMIT_ORDER_HOOK,
    functionName: "getUserOrders",
    args: address ? [address] : undefined,
    query: {
      enabled: !!address,
      refetchInterval: 12_000,
    },
  });

  // Re-fetch when refetchKey changes (order created or cancelled)
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
  refetchKey,
  onCancelled,
}: {
  orderId: bigint;
  refetchKey: number;
  onCancelled: () => void;
}) {
  const {
    data: orderRaw,
    isLoading,
    refetch: refetchOrder,
  } = useReadContract({
    ...LIMIT_ORDER_HOOK,
    functionName: "getOrder",
    args: [orderId],
    query: { refetchInterval: 12_000 },
  });

  // Re-fetch individual order when parent key changes
  useEffect(() => {
    refetchOrder();
  }, [refetchKey, refetchOrder]);

  // ── Cancel TX flow ──────────────────────────────────
  const { data: cancelHash, writeContract: cancelOrder } = useWriteContract();
  const { isSuccess: cancelConfirmed } = useWaitForTransactionReceipt({
    hash: cancelHash,
  });

  useEffect(() => {
    if (cancelConfirmed) {
      // Refetch THIS order first, THEN notify parent
      refetchOrder().then(() => onCancelled());
    }
  }, [cancelConfirmed, refetchOrder, onCancelled]);

  if (isLoading) {
    return <div className="h-24 rounded-lg bg-gray-800 animate-pulse" />;
  }

  const order = orderRaw as OrderData | undefined;
  if (!order) return null;

  // Determine status
  const status: OrderStatus =
    order.creator === zeroAddress
      ? "cancelled"
      : order.isFilled
        ? "filled"
        : "active";

  // Direction & amounts
  const isSell = order.zeroForOne;
  const directionLabel = isSell ? "Sell TTA → TTB" : "Buy TTA ← TTB";
  const inputAmount = isSell ? order.amount0 : order.amount1;
  const outputAmount = isSell ? order.amount1 : order.amount0;
  const inputSymbol = isSell ? TOKEN_TTA.symbol : TOKEN_TTB.symbol;
  const outputSymbol = isSell ? TOKEN_TTB.symbol : TOKEN_TTA.symbol;

  // Trigger price (stored as 1e18-scaled)
  const triggerNum = Number(order.triggerPrice) / 1e18;

  const handleCancel = () => {
    cancelOrder({
      ...LIMIT_ORDER_HOOK,
      functionName: "cancelOrder",
      args: [orderId],
    });
  };

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
        <span className="text-xs text-gray-500">
          {directionLabel}
        </span>
      </div>

      {/* Details */}
      <div className="grid grid-cols-2 gap-y-1.5 sm:gap-y-2 text-xs sm:text-sm">
        <span className="text-gray-500">Input</span>
        <span className="text-right text-white font-mono">
          {formatEther(inputAmount)} {inputSymbol}
        </span>

        {status === "filled" && outputAmount > 0n && (
          <>
            <span className="text-gray-500">Received</span>
            <span className="text-right text-emerald-400 font-mono">
              {formatEther(outputAmount)} {outputSymbol}
            </span>
          </>
        )}

        <span className="text-gray-500">Trigger</span>
        <span className="text-right text-gray-300 font-mono">
          ≥ {triggerNum.toFixed(4)}
        </span>
      </div>

      {/* Cancel button */}
      {status === "active" && (
        <button
          onClick={handleCancel}
          disabled={!!cancelHash && !cancelConfirmed}
          className="mt-3 w-full rounded-lg bg-red-900/30 border border-red-800/50 py-2.5 sm:py-2 text-sm text-red-400 hover:bg-red-900/50 transition-colors disabled:opacity-50"
        >
          {cancelHash && !cancelConfirmed ? "Cancelling…" : "Cancel Order"}
        </button>
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
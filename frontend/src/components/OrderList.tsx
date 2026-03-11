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
    query: { enabled: !!address },
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
          {[...ids].reverse().map((id) => (
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
    data: rawOrder,
    isLoading,
    refetch: refetchOrder,
  } = useReadContract({
    ...LIMIT_ORDER_HOOK,
    functionName: "getOrder",
    args: [orderId],
  });

  // Re-fetch order details when parent key changes
  useEffect(() => {
    refetchOrder();
  }, [refetchKey, refetchOrder]);

  // ── Cancel logic ──────────────────────────────────────
  const {
    data: cancelTxHash,
    writeContract: writeCancel,
    error: cancelError,
    reset: resetCancel,
  } = useWriteContract();

  const { isSuccess: cancelConfirmed, isLoading: cancelMining } =
    useWaitForTransactionReceipt({ hash: cancelTxHash });

  useEffect(() => {
    if (cancelConfirmed) {
      refetchOrder().then(() => onCancelled());
    }
  }, [cancelConfirmed, onCancelled, refetchOrder]);

  function handleCancel() {
    resetCancel();
    writeCancel({
      ...LIMIT_ORDER_HOOK,
      functionName: "cancelOrder",
      args: [orderId],
    });
  }

  // ── Loading skeleton ──────────────────────────────────
  if (isLoading) {
    return (
      <div className="h-24 rounded-lg bg-gray-800 animate-pulse" />
    );
  }

  const order = rawOrder as OrderData | undefined;
  if (!order) return null;

  // ── Determine status ──────────────────────────────────
  const status: OrderStatus =
    order.creator === zeroAddress
      ? "cancelled"
      : order.isFilled
        ? "filled"
        : "active";

  const direction = order.zeroForOne ? "Sell" : "Buy";
  const dirColor = order.zeroForOne ? "text-red-400" : "text-emerald-400";

  const spendSymbol = order.zeroForOne ? TOKEN_TTA.symbol : TOKEN_TTB.symbol;
  const amountIn = order.zeroForOne ? order.amount0 : order.amount1;

  const timestamp = Number(order.createdAt);
  const dateStr =
    timestamp > 0
      ? new Date(timestamp * 1000).toLocaleDateString("en-US", {
          month: "short",
          day: "numeric",
          hour: "2-digit",
          minute: "2-digit",
        })
      : "—";

  const cancelErrMsg = cancelError
    ? cancelError.message.includes("User rejected") ||
      cancelError.message.includes("user rejected")
      ? "Rejected in wallet"
      : "Cancel failed"
    : null;

  // ── Render ────────────────────────────────────────────
  return (
    <div className="rounded-lg border border-gray-800 bg-gray-800/50 p-4 flex items-center justify-between gap-4">
      {/* Left: Order info */}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2 mb-1.5">
          <span className="text-xs font-mono text-gray-500">#{orderId.toString()}</span>
          <StatusBadge status={status} />
          <span className={`text-xs font-medium ${dirColor}`}>{direction}</span>
        </div>

        <div className="flex items-baseline gap-3 text-sm">
          <span className="text-white font-mono">
            {Number(formatEther(amountIn)).toFixed(4)}{" "}
            <span className="text-gray-400">{spendSymbol}</span>
          </span>
          <span className="text-gray-600">@</span>
          <span className="text-white font-mono">
            {Number(formatEther(order.triggerPrice)).toFixed(4)}
          </span>
        </div>

        <p className="text-xs text-gray-600 mt-1">{dateStr}</p>

        {cancelErrMsg && (
          <p className="text-xs text-red-400 mt-1">{cancelErrMsg}</p>
        )}
      </div>

      {/* Right: Cancel button (only for active orders) */}
      {status === "active" && (
        <button
          onClick={handleCancel}
          disabled={!!cancelTxHash && !cancelConfirmed}
          className="shrink-0 px-3 py-1.5 rounded-md text-xs font-medium
                     border border-gray-700 text-gray-400
                     hover:border-red-500/50 hover:text-red-400 hover:bg-red-500/10
                     disabled:opacity-50 disabled:cursor-not-allowed
                     transition-colors"
        >
          {cancelMining ? (
            <span className="inline-flex items-center gap-1.5">
              <Spinner />
              Cancelling…
            </span>
          ) : cancelConfirmed ? (
            "Cancelled"
          ) : (
            "Cancel"
          )}
        </button>
      )}
    </div>
  );
}

// ── Status Badge ─────────────────────────────────────────
function StatusBadge({ status }: { status: OrderStatus }) {
  const styles: Record<OrderStatus, string> = {
    active: "bg-yellow-500/15 text-yellow-400 border-yellow-500/30",
    filled: "bg-emerald-500/15 text-emerald-400 border-emerald-500/30",
    cancelled: "bg-gray-700/50 text-gray-500 border-gray-600/30",
  };

  return (
    <span
      className={`inline-block px-1.5 py-0.5 rounded text-[10px] font-medium uppercase tracking-wider border ${styles[status]}`}
    >
      {status}
    </span>
  );
}

// ── Tiny spinner ─────────────────────────────────────────
function Spinner() {
  return (
    <svg className="animate-spin h-3 w-3" viewBox="0 0 24 24" fill="none">
      <circle
        cx="12" cy="12" r="10"
        stroke="currentColor" strokeWidth="3"
        className="opacity-25"
      />
      <path
        d="M4 12a8 8 0 018-8"
        stroke="currentColor" strokeWidth="3" strokeLinecap="round"
        className="opacity-75"
      />
    </svg>
  );
}
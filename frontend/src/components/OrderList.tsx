"use client";

import { useEffect } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { formatUnits, zeroAddress, type Address } from "viem";
import {
  LIMIT_ORDER_HOOK,
  TOKEN_0,
  TOKEN_1,
  EXPLORER_URL,
} from "@/config/contracts";

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

// Trigger price decimals: 18 + quote_decimals - base_decimals
const TRIGGER_PRICE_DECIMALS = 18 + TOKEN_1.decimals - TOKEN_0.decimals; // 6

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

  // Direction & amounts — use real token configs
  const isSell = order.zeroForOne;
  const directionLabel = isSell
    ? `Sell ${TOKEN_0.symbol} → ${TOKEN_1.symbol}`
    : `Buy ${TOKEN_0.symbol} ← ${TOKEN_1.symbol}`;
  const inputToken = isSell ? TOKEN_0 : TOKEN_1;
  const outputToken = isSell ? TOKEN_1 : TOKEN_0;
  const inputAmount = isSell ? order.amount0 : order.amount1;
  const outputAmount = isSell ? order.amount1 : order.amount0;

  // Trigger price: stored as raw_price * 1e18, display as "USDC per WETH"
  const triggerNum =
    Number(order.triggerPrice) / 10 ** TRIGGER_PRICE_DECIMALS;

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
        <span className="text-xs text-gray-500">{directionLabel}</span>
      </div>

      {/* Details */}
      <div className="grid grid-cols-2 gap-y-2 text-sm">
        <span className="text-gray-500">Input</span>
        <span className="text-right text-white font-mono">
          {formatUnits(inputAmount, inputToken.decimals)} {inputToken.symbol}
        </span>

        {status === "filled" && outputAmount > 0n && (
          <>
            <span className="text-gray-500">Received</span>
            <span className="text-right text-emerald-400 font-mono">
              {formatUnits(outputAmount, outputToken.decimals)}{" "}
              {outputToken.symbol}
            </span>
          </>
        )}

        <span className="text-gray-500">Trigger</span>
        <span className="text-right text-gray-300 font-mono">
          ≥ {triggerNum.toFixed(2)} {TOKEN_1.symbol}/{TOKEN_0.symbol}
        </span>
      </div>

      {/* Cancel button + explorer link */}
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
            href={`${EXPLORER_URL}/tx/${cancelHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-blue-400/70 hover:text-blue-400 underline"
          >
            View on BaseScan ↗
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
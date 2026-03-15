"use client";

import { useState, useMemo, useEffect } from "react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { parseEther, formatEther, type Address } from "viem";
import {
  LIMIT_ORDER_HOOK,
  ERC20_ABI,
  TOKEN_TTA,
  TOKEN_TTB,
  POOL_KEY,
} from "@/config/contracts";

// ── Types ───────────────────────────────────────────────
type OrderDirection = "sell" | "buy";
type TxStep = "idle" | "approving" | "waitApprove" | "placing" | "waitPlace" | "done";

// uint96 max = 2^96 - 1
const UINT96_MAX = (1n << 96n) - 1n;

// ── Component ───────────────────────────────────────────
export default function CreateOrderForm({
  onOrderCreated,
}: {
  /** Called after an order is successfully mined */
  onOrderCreated?: () => void;
}) {
  const { address, isConnected } = useAccount();

  // Form state
  const [direction, setDirection] = useState<OrderDirection>("sell");
  const [amountIn, setAmountIn] = useState("");
  const [triggerPrice, setTriggerPrice] = useState("");
  const [txStep, setTxStep] = useState<TxStep>("idle");
  const [error, setError] = useState<string | null>(null);

  // Derived: which token are we spending?
  const spendToken = direction === "sell" ? TOKEN_TTA : TOKEN_TTB;
  const receiveToken = direction === "sell" ? TOKEN_TTB : TOKEN_TTA;
  const zeroForOne = direction === "sell"; // sell TTA (currency0) for TTB (currency1)

  // ── Read: user balance ────────────────────────────────
  const { data: userBalance } = useReadContract({
    address: spendToken.address,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // ── Read: current allowance ───────────────────────────
  const { data: currentAllowance, refetch: refetchAllowance } = useReadContract({
    address: spendToken.address,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, LIMIT_ORDER_HOOK.address] : undefined,
    query: { enabled: !!address },
  });

  // ── Write: approve ────────────────────────────────────
  const {
    data: approveTxHash,
    writeContract: writeApprove,
    error: approveError,
    reset: resetApprove,
  } = useWriteContract();

  const { isSuccess: approveConfirmed, isLoading: approveLoading } =
    useWaitForTransactionReceipt({
      hash: approveTxHash,
    });

  // ── Write: createLimitOrder ───────────────────────────
  const {
    data: createTxHash,
    writeContract: writeCreate,
    error: createError,
    reset: resetCreate,
  } = useWriteContract();

  const { isSuccess: createConfirmed, isLoading: createLoading } =
    useWaitForTransactionReceipt({
      hash: createTxHash,
    });

  // ── Parsed amounts ────────────────────────────────────
  const parsedAmount = useMemo(() => {
    try {
      if (!amountIn || parseFloat(amountIn) <= 0) return null;
      return parseEther(amountIn);
    } catch {
      return null;
    }
  }, [amountIn]);

  const parsedTriggerPrice = useMemo(() => {
    try {
      if (!triggerPrice || parseFloat(triggerPrice) <= 0) return null;
      return parseEther(triggerPrice);
    } catch {
      return null;
    }
  }, [triggerPrice]);

  // Check if amount fits in uint96
  const amountExceedsUint96 = parsedAmount !== null && parsedAmount > UINT96_MAX;

  // Do we already have sufficient allowance?
  const needsApproval =
    parsedAmount !== null &&
    currentAllowance !== undefined &&
    (currentAllowance as bigint) < parsedAmount;

  // ── Effect: after approve confirmed → place order ─────
  useEffect(() => {
    if (approveConfirmed && txStep === "waitApprove") {
      refetchAllowance();
      handlePlaceOrder();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [approveConfirmed]);

  // ── Effect: after create confirmed → done + callback ──
  useEffect(() => {
    if (createConfirmed && txStep === "waitPlace") {
      setTxStep("done");
      onOrderCreated?.();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [createConfirmed]);

  // ── Effect: handle wallet rejections ──────────────────
  useEffect(() => {
    if (approveError) {
      const msg = extractUserMessage(approveError);
      setError(msg);
      setTxStep("idle");
    }
  }, [approveError]);

  useEffect(() => {
    if (createError) {
      const msg = extractUserMessage(createError);
      setError(msg);
      setTxStep("idle");
    }
  }, [createError]);

  // ── Handlers ──────────────────────────────────────────
  function handleSubmit() {
    setError(null);
    resetApprove();
    resetCreate();

    if (!parsedAmount || !parsedTriggerPrice) {
      setError("Enter valid amount and trigger price");
      return;
    }

    if (amountExceedsUint96) {
      setError("Amount exceeds max uint96 (~79B tokens)");
      return;
    }

    if (needsApproval) {
      // Step 1: Approve
      setTxStep("approving");
      writeApprove(
        {
          address: spendToken.address,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [LIMIT_ORDER_HOOK.address, parsedAmount],
        },
        {
          onSuccess: () => setTxStep("waitApprove"),
          onError: () => setTxStep("idle"),
        }
      );
    } else {
      // Already approved — skip to create
      handlePlaceOrder();
    }
  }

  function handlePlaceOrder() {
    if (!parsedAmount || !parsedTriggerPrice) return;

    setTxStep("placing");

    const poolKeyTuple = {
      currency0: POOL_KEY.currency0 as Address,
      currency1: POOL_KEY.currency1 as Address,
      fee: POOL_KEY.fee,
      tickSpacing: POOL_KEY.tickSpacing,
      hooks: POOL_KEY.hooks as Address,
    };

    writeCreate(
      {
        ...LIMIT_ORDER_HOOK,
        functionName: "createLimitOrder",
        args: [poolKeyTuple, zeroForOne, parsedAmount, parsedTriggerPrice],
      },
      {
        onSuccess: () => setTxStep("waitPlace"),
        onError: () => setTxStep("idle"),
      }
    );
  }

  function handleReset() {
    setTxStep("idle");
    setAmountIn("");
    setTriggerPrice("");
    setError(null);
    resetApprove();
    resetCreate();
  }

  // ── Validation ────────────────────────────────────────
  const canSubmit =
    isConnected &&
    parsedAmount !== null &&
    parsedTriggerPrice !== null &&
    !amountExceedsUint96 &&
    txStep === "idle";

  // ── Render ────────────────────────────────────────────
  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900 p-6">
      <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-5">
        Create Limit Order
      </h3>

      {/* Direction Toggle */}
      <div className="flex gap-2 mb-4 sm:mb-5">
        <button
          onClick={() => setDirection("sell")}
          className={`flex-1 py-2.5 sm:py-2 rounded-lg text-xs sm:text-sm font-medium transition-colors ${
            direction === "sell"
              ? "bg-red-500/20 text-red-400 border border-red-500/40"
              : "bg-gray-800 text-gray-400 border border-gray-700 hover:border-gray-600"
          }`}
        >
          Sell TTA → TTB
        </button>
        <button
          onClick={() => setDirection("buy")}
          className={`flex-1 py-2.5 sm:py-2 rounded-lg text-xs sm:text-sm font-medium transition-colors ${
            direction === "buy"
              ? "bg-emerald-500/20 text-emerald-400 border border-emerald-500/40"
              : "bg-gray-800 text-gray-400 border border-gray-700 hover:border-gray-600"
          }`}
        >
          Buy TTA ← TTB
        </button>
      </div>

      {/* Amount Input */}
      <div className="mb-4">
        <label className="block text-xs text-gray-500 mb-1.5">
          Amount ({spendToken.symbol})
        </label>
        <div className="relative">
          <input
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            value={amountIn}
            onChange={(e) => {
              // Allow only numbers and a single dot
              const val = e.target.value;
              if (/^[0-9]*\.?[0-9]*$/.test(val)) {
                setAmountIn(val);
                setError(null);
              }
            }}
            disabled={txStep !== "idle"}
            className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 sm:px-4 py-3 text-sm sm:text-base text-white
                       placeholder-gray-600 focus:outline-none focus:border-gray-500
                       disabled:opacity-50 font-mono"
          />
          {address && userBalance !== undefined && (
            <button
              onClick={() => setAmountIn(formatEther(userBalance as bigint))}
              className="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-gray-500
                         hover:text-gray-300 transition-colors"
            >
              MAX: {Number(formatEther(userBalance as bigint)).toFixed(2)}
            </button>
          )}
        </div>
        {amountExceedsUint96 && (
          <p className="text-xs text-red-400 mt-1">
            Exceeds uint96 max (~79B tokens)
          </p>
        )}
      </div>

      {/* Trigger Price Input */}
      <div className="mb-5">
        <label className="block text-xs text-gray-500 mb-1.5">
          Trigger Price ({receiveToken.symbol} per {spendToken.symbol})
        </label>
        <input
          type="text"
          inputMode="decimal"
          placeholder="1.01"
          value={triggerPrice}
          onChange={(e) => {
            const val = e.target.value;
            if (/^[0-9]*\.?[0-9]*$/.test(val)) {
              setTriggerPrice(val);
              setError(null);
            }
          }}
          disabled={txStep !== "idle"}
          className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 sm:px-4 py-3 text-sm sm:text-base text-white
                     placeholder-gray-600 focus:outline-none focus:border-gray-500
                     disabled:opacity-50 font-mono"
        />
      </div>

      {/* Error Message */}
      {error && (
        <div className="mb-4 p-3 rounded-lg bg-red-500/10 border border-red-500/30">
          <p className="text-sm text-red-400">{error}</p>
        </div>
      )}

      {/* Submit / Status Button */}
      {txStep === "done" ? (
        <div className="space-y-3">
          <div className="p-3 rounded-lg bg-emerald-500/10 border border-emerald-500/30 text-center">
            <p className="text-sm text-emerald-400 font-medium">
              Order created successfully!
            </p>
            {createTxHash && (
              <a
                href={`https://sepolia.etherscan.io/tx/${createTxHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-emerald-500/70 hover:text-emerald-400 underline mt-1 inline-block"
              >
                View on Etherscan ↗
              </a>
            )}
          </div>
          <button
            onClick={handleReset}
            className="w-full py-3 rounded-lg bg-gray-800 text-gray-300
                       hover:bg-gray-700 transition-colors text-sm font-medium"
          >
            Place Another Order
          </button>
        </div>
      ) : (
        <button
          onClick={handleSubmit}
          disabled={!canSubmit}
          className="w-full py-3 rounded-lg font-medium text-sm transition-all
                     disabled:opacity-40 disabled:cursor-not-allowed
                     bg-blue-600 hover:bg-blue-500 text-white"
        >
          <ButtonLabel
            step={txStep}
            needsApproval={needsApproval}
            approveLoading={approveLoading}
            createLoading={createLoading}
          />
        </button>
      )}

      {/* Tx Hash Links (intermediate) */}
      {approveTxHash && txStep === "waitApprove" && (
        <p className="text-xs text-gray-500 text-center mt-2">
          Approve tx:{" "}
          <a
            href={`https://sepolia.etherscan.io/tx/${approveTxHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-blue-400/70 hover:text-blue-400 underline"
          >
            {approveTxHash.slice(0, 10)}…
          </a>
        </p>
      )}
    </div>
  );
}

// ── Helpers ─────────────────────────────────────────────

function ButtonLabel({
  step,
  needsApproval,
  approveLoading,
  createLoading,
}: {
  step: TxStep;
  needsApproval: boolean;
  approveLoading: boolean;
  createLoading: boolean;
}) {
  switch (step) {
    case "approving":
      return <SpinnerText text="Confirm approval in wallet…" />;
    case "waitApprove":
      return <SpinnerText text={approveLoading ? "Waiting for approval…" : "Approve confirmed"} />;
    case "placing":
      return <SpinnerText text="Confirm order in wallet…" />;
    case "waitPlace":
      return <SpinnerText text={createLoading ? "Mining order tx…" : "Almost there…"} />;
    default:
      return <>{needsApproval ? "Approve & Place Order" : "Place Order"}</>;
  }
}

function SpinnerText({ text }: { text: string }) {
  return (
    <span className="inline-flex items-center gap-2">
      <svg className="animate-spin h-4 w-4" viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" className="opacity-25" />
        <path
          d="M4 12a8 8 0 018-8"
          stroke="currentColor"
          strokeWidth="3"
          strokeLinecap="round"
          className="opacity-75"
        />
      </svg>
      {text}
    </span>
  );
}

/** Extract a human-readable message from a wagmi/viem error */
function extractUserMessage(err: Error): string {
  const msg = err.message || "";

  // User rejected in wallet
  if (msg.includes("User rejected") || msg.includes("user rejected")) {
    return "Transaction rejected in wallet";
  }
  // Insufficient funds for gas
  if (msg.includes("insufficient funds")) {
    return "Insufficient ETH for gas fees";
  }
  // Contract revert
  if (msg.includes("reverted")) {
    // Try to extract revert reason
    const match = msg.match(/reason:\s*(.+?)(?:\n|$)/);
    return match ? `Contract reverted: ${match[1]}` : "Transaction reverted by contract";
  }
  // Generic
  if (msg.length > 120) {
    return msg.slice(0, 120) + "…";
  }
  return msg || "Unknown error";
}
"use client";

import { useState, useCallback } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useReadContract, useAccount } from "wagmi";
import { LIMIT_ORDER_HOOK } from "@/config/contracts";
import CreateOrderForm from "@/components/CreateOrderForm";
import OrderList from "@/components/OrderList";
import PoolInfo from "@/components/PoolInfo";

function Skeleton() {
  return (
    <span className="inline-block w-12 h-5 bg-gray-800 rounded animate-pulse" />
  );
}

export default function Home() {
  const { isConnected } = useAccount();

  // Global refetch counter — increment to trigger all data refreshes
  const [refetchKey, setRefetchKey] = useState(0);

  const { data: feeBps, isLoading: feeLoading, refetch: refetchFee } = useReadContract({
    ...LIMIT_ORDER_HOOK,
    functionName: "feeBps",
  });

  const { data: nextOrderId, isLoading: orderLoading, refetch: refetchOrderCount } = useReadContract({
    ...LIMIT_ORDER_HOOK,
    functionName: "nextOrderId",
  });

  const handleDataChanged = useCallback(() => {
    setRefetchKey((k) => k + 1);
    refetchFee();
    refetchOrderCount();
  }, [refetchFee, refetchOrderCount]);

  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <header className="flex items-center justify-between px-6 py-4 border-b border-gray-800">
        <h1 className="text-xl font-bold tracking-tight">
          Limit Order Hook
          <span className="ml-2 text-xs font-normal text-gray-500">
            Uniswap V4
          </span>
        </h1>
        <ConnectButton />
      </header>

      <div className="max-w-2xl mx-auto mt-12 px-6 space-y-6">
        <div className="text-center mb-8">
          <h2 className="text-3xl font-bold mb-3">On-chain Limit Orders</h2>
          <p className="text-gray-400">
            Place limit orders directly on Uniswap V4 pools. No off-chain
            relayers, no trust assumptions.
          </p>
        </div>

        {/* Live Pool Price — always visible (read-only, no wallet needed) */}
        <PoolInfo />

        {/* Contract Status Card */}
        <div className="rounded-xl border border-gray-800 bg-gray-900 p-6">
          <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-4">
            Contract Status — Sepolia
          </h3>

          <div className="space-y-4">
            <div className="flex justify-between items-center">
              <span className="text-gray-400">Hook Address</span>
              <code className="text-sm text-emerald-400 bg-gray-800 px-2 py-1 rounded">
                0x43BF...4040
              </code>
            </div>

            <div className="flex justify-between items-center">
              <span className="text-gray-400">Fee</span>
              <span className="text-white font-mono">
                {feeLoading ? (
                  <Skeleton />
                ) : (
                  `${feeBps?.toString() ?? "—"} bps (${Number(feeBps ?? 0) / 100}%)`
                )}
              </span>
            </div>

            <div className="flex justify-between items-center">
              <span className="text-gray-400">Total Orders</span>
              <span className="text-white font-mono">
                {orderLoading ? <Skeleton /> : nextOrderId?.toString() ?? "—"}
              </span>
            </div>

            <div className="flex justify-between items-center">
              <span className="text-gray-400">Wallet</span>
              <span
                className={`font-mono ${isConnected ? "text-emerald-400" : "text-yellow-500"}`}
              >
                {isConnected ? "Connected" : "Not connected"}
              </span>
            </div>
          </div>
        </div>

        {/* Create Order Form (only when connected) */}
        {isConnected ? (
          <CreateOrderForm onOrderCreated={handleDataChanged} />
        ) : (
          <div className="rounded-xl border border-dashed border-gray-700 p-8 text-center">
            <p className="text-gray-500 text-sm">
              Connect your wallet to place limit orders
            </p>
          </div>
        )}

        {/* Order List */}
        {isConnected && <OrderList refetchKey={refetchKey} />}

        {isConnected && (
          <p className="text-center text-xs text-gray-600">
            Make sure you are on Sepolia testnet
          </p>
        )}
      </div>
    </main>
  );
}
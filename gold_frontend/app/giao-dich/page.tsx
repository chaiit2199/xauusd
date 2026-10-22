import type { Metadata } from "next";
import { Dashboard } from "../components/dashboard";

export const metadata: Metadata = { title: "Giao dịch" };

export default async function TradingPage({ searchParams }: { searchParams: Promise<{ side?: string }> }) {
  const { side } = await searchParams;
  return <Dashboard key={side === "sell" ? "sell" : "buy"} page="trading" initialSide={side === "sell" ? "sell" : "buy"} />;
}

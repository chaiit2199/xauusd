// The browser always uses same-origin /api. Caddy routes it in production;
// Next.js uses its server-only API_BASE_URL rewrite in local/dev.
export const apiBase = "";

export function money(value: string | number): string {
  const amount = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(amount)) return "—";

  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(amount);
}

export function num(value: number, digits = 2): string {
  if (!Number.isFinite(value)) return "—";

  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}

export function when(iso: string | null): string {
  if (!iso) return "—";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "—";

  return new Intl.DateTimeFormat("vi-VN", {
    hour: "2-digit",
    minute: "2-digit",
    day: "2-digit",
    month: "2-digit",
  }).format(date);
}

export function originLabel(origin: string): string {
  switch (origin) {
    case "gold_api_ohlc":
      return "Gold API · Đóng nến M15";
    case "gold_api":
      return "Gold API";
    case "metals_dev":
      return "metals.dev";
    case "synthetic":
      return "Giá mô phỏng";
    case "seed":
      return "Giá khởi tạo";
    default:
      return origin;
  }
}

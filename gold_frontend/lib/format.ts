// Empty = same origin (production: reverse proxy /api → backend).
// Local: set NEXT_PUBLIC_API_URL in .env.local (build-time for Next).
export const apiBase = (process.env.NEXT_PUBLIC_API_URL ?? "").replace(/\/$/, "");

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
    case "gold_api":
      return "Gold API";
    case "metals_dev":
      return "metals.dev";
    case "synthetic":
      return "Giá nội bộ";
    case "seed":
      return "Giá khởi tạo";
    default:
      return origin;
  }
}

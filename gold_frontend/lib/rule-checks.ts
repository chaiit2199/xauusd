import type { RuleCheck } from "./types";

export const ruleLabels: Record<string, string> = {
  data: "Dữ liệu OHLC", bias: "Hướng H1", m15_data: "Dữ liệu M15", zoi: "Vùng giá của setup",
  trigger: "Xác nhận M15", direction: "Đồng hướng H1", setup_lifetime: "Thời hạn setup",
  structure: "Điểm vô hiệu", calendar_data: "Dữ liệu lịch tin", calendar_window: "Cửa sổ tin",
  session: "Khung giờ ưu tiên", market_open: "Hoạt động thị trường", quote: "Độ mới báo giá", entry_drift: "Lệch entry",
  levels: "SL / TP", barrier_room: "Khoảng trống tới vùng cản", reward_risk: "R:R ước tính và vùng cản",
  setup_invalidation: "Setup đã vô hiệu", setup_target: "Mục tiêu chưa bị chạm", target_structure: "Mục tiêu TP",
};

export function checkState(check: RuleCheck): RuleCheck["status"] {
  if (check.required === false && check.status !== "pass") return "warning";
  return check.status;
}

export function checkCounts(checks: RuleCheck[]) {
  return checks.reduce((counts, check) => {
    counts[checkState(check)] += 1;
    return counts;
  }, { pass: 0, blocked: 0, unknown: 0, warning: 0 });
}

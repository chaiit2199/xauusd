import type { MarketBoard } from "./types";

export function expireAnalysis(board: MarketBoard, now: number): MarketBoard {
  const calendarExpiry = board.calendar_valid_until ? Date.parse(board.calendar_valid_until) : null;
  const expiredCalendar = calendarExpiry !== null && (!Number.isFinite(calendarExpiry) || now >= calendarExpiry);
  const quoteExpiry = board.signal_valid_until ? Date.parse(board.signal_valid_until) : null;
  const staleQuote = quoteExpiry !== null && (!Number.isFinite(quoteExpiry) || now >= quoteExpiry);
  const expiry = board.ai_next_analysis_at === undefined ? Infinity : Date.parse(board.ai_next_analysis_at);
  const setupExpiry = board.cfd_plan.setup_expires_at ? Date.parse(board.cfd_plan.setup_expires_at) : Infinity;
  const expiredSetup = Number.isFinite(setupExpiry) && now >= setupExpiry;
  if (!expiredCalendar && !staleQuote && !expiredSetup && now < expiry) return board;

  const expiredAnalysis = !(now < expiry);
  const onlyQuote = staleQuote && !expiredSetup && !expiredCalendar && !expiredAnalysis;
  const plan = board.cfd_plan;
  const terminal = plan.setup_status === "invalidated" || plan.setup_status === "expired";
  const status = terminal || expiredSetup ? "blocked" : "unchecked";
  const reason = expiredSetup ? "Setup đã hết hạn; chờ xác nhận mới." : expiredAnalysis ? "Nhận định đã hết chu kỳ M15; chờ kết quả cho nến vừa đóng." : expiredCalendar ? "Lịch tin đã hết hiệu lực; chờ xác minh lại." : staleQuote ? "Báo giá đã quá hạn; chờ kiểm tra giá mới." : "Nhận định đã hết chu kỳ M15; chờ kết quả cho nến vừa đóng.";
  return {
    ...board,
    rule_action: "wait",
    ai_action: null,
    ai_insight: null,
    ai_error: reason,
    cfd_plan: {
      ...board.cfd_plan,
      action: "wait",
      action_label: "Đứng ngoài",
      setup_status: terminal ? plan.setup_status : expiredSetup ? "expired" : onlyQuote && plan.planning_action && plan.planning_action !== "wait" && plan.setup_status !== "paused" && plan.setup_status !== "news_window" ? "awaiting_quote" : "paused",
      current_entry_status: status,
      entry_admission: null,
      entry_guard: { blocked: true, reasons: [reason] },
      blocking_reasons: [reason],
      price_basis: "m15_close",
      quote_at: null,
      entry: plan.reference_entry ?? plan.entry,
      entry_adverse: null,
      entry_limit: null,
      reward_risk_after_spread: null,
      decision_plan: plan.decision_plan ? { ...plan.decision_plan, current_entry_status: status,
        current_entry: null, current_quote_at: null, reward_risk: null, cost_sensitivity: null,
        confirmation: reason, reward_risk_basis: "Chưa kiểm tra entry hiện tại; đối chiếu báo giá mới trước khi sử dụng." } : undefined,
      execution_ready: false,
      block_reason: reason,
      summary: reason,
      checks: board.cfd_plan.checks?.map((check) => {
        if (check.code === "quote" && staleQuote) return { ...check, status: "warning", required: false, scope: "advisory", reason: "Báo giá đã quá hạn; kế hoạch vẫn dùng entry tham chiếu. Chưa kiểm tra entry hiện tại." };
        if ((check.code === "setup_lifetime" && expiredSetup) || (check.code === "calendar_data" && expiredCalendar) || (check.code === "m15_data" && expiredAnalysis)) return { ...check, status: "blocked", required: true, reason };
        const currentDependent = ["current_entry", "market_open", "entry_drift", "levels", "reward_risk", "barrier_room", "structure", "setup_target"].includes(check.code);
        if (currentDependent || (!onlyQuote && ["direction", "trigger"].includes(check.code)) || (expiredCalendar && check.code === "calendar_window")) {
          if (check.code === "market_open" && check.status === "blocked") return check;
          return { ...check, status: "unknown", scope: "current_entry", reason: "Chờ đánh giá lại với dữ liệu mới." };
        }
        return check;
      }),
    },
  };
}

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

  const reason = expiredSetup ? "Setup đã hết hạn; chờ xác nhận mới." : expiredCalendar ? "Lịch tin đã hết hiệu lực; chờ xác minh lại." : staleQuote ? "Báo giá đã quá hạn; chờ kiểm tra giá mới." : "Nhận định đã hết chu kỳ M15; chờ kết quả cho nến vừa đóng.";
  return {
    ...board,
    ai_action: null,
    ai_insight: null,
    ai_error: reason,
    cfd_plan: {
      ...board.cfd_plan,
      action: "wait",
      action_label: "Đứng ngoài",
      setup_status: board.cfd_plan.setup_status === "invalidated" || board.cfd_plan.setup_status === "expired" ? board.cfd_plan.setup_status : expiredSetup ? "expired" : "paused",
      execution_ready: false,
      block_reason: reason,
      summary: reason,
      checks: board.cfd_plan.checks?.map((check) => {
        const code = expiredSetup ? "setup_lifetime" : expiredCalendar ? "calendar_data" : staleQuote ? "quote" : "m15_data";
        if (check.code === code) return { ...check, status: "blocked", required: true, reason };
        if (check.required !== false && (["direction", "trigger", "entry_drift", "levels", "reward_risk", "barrier_room", "structure", "setup_target"].includes(check.code) || (expiredCalendar && check.code === "calendar_window"))) {
          return { ...check, status: "unknown", reason: "Chờ đánh giá lại với dữ liệu mới." };
        }
        return check;
      }),
    },
  };
}

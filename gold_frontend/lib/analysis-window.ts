import type { MarketBoard } from "./types";

export function expireAnalysis(board: MarketBoard, now: number): MarketBoard {
  if (board.ai_next_analysis_at === undefined) return board;
  const expiry = Date.parse(board.ai_next_analysis_at);
  if (Number.isFinite(expiry) && now < expiry) return board;

  const reason = "Nhận định đã hết chu kỳ M15; chờ kết quả cho nến vừa đóng.";
  return {
    ...board,
    ai_action: null,
    ai_insight: null,
    ai_error: reason,
    cfd_plan: {
      ...board.cfd_plan,
      action: "wait",
      action_label: "Đứng ngoài",
      block_reason: reason,
      summary: reason,
    },
  };
}

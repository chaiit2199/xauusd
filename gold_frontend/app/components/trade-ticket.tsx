import type { CfdPlan } from "../../lib/types";
import { money, when } from "../../lib/format";
import { DecisionPlan } from "./decision-plan";

type TradeTicketProps = {
  plan: CfdPlan;
  aiAction?: CfdPlan["action"] | null;
};

export function TradeTicket({ plan }: TradeTicketProps) {
  // Keep the API's calculation assumptions out of the displayed warnings.
  const visibleFlags = plan.soft_flags?.filter(
    (flag) => flag !== "Spread 0,40 USD là giả định; nguồn hiện tại chưa cung cấp bid/ask của sàn." &&
      flag !== "Có headline tác động mạnh; kiểm tra nguồn và điều kiện khớp lệnh.",
  );
  const states: Record<string, string> = {
    watching: "Theo dõi vùng giá", wait_confirmation: "Có setup · Chờ xác nhận M15",
    wait_pullback: "Chờ hồi về vùng vào", signal_ready: "Đủ điều kiện phát tín hiệu",
    expired: "Setup đã hết hạn", invalidated: "Setup đã vô hiệu",
    paused: "Tạm dừng · Chờ dữ liệu hợp lệ", news_window: "Tạm dừng quanh tin quan trọng",
    wait_target: "Chờ vùng cản để xác định TP",
  };

  return (
    <section className={`ticket action-${plan.action}`} aria-labelledby="decision-title">
      <div className="panel-head">
        <h2 id="decision-title">Kế hoạch BUY / SELL</h2>
        <p>{plan.timeframe ?? "H1"} · {plan.market_state}</p>
      </div>
      {plan.setup_status ? <div className="signal-status" aria-live="polite">
        <div><span className="eyebrow">Hướng ưu tiên H1</span><strong>{plan.lean_label}</strong></div>
        <div><span className="eyebrow">Trạng thái setup</span><strong>{states[plan.setup_status]}</strong></div>
        <div><span className="eyebrow">Thực thi</span><strong>Chỉ phát tín hiệu</strong><span>Không ghi nhận lệnh khớp hoặc vị thế.</span></div>
      </div> : null}
      <div className="decision" role="group" aria-label={`Tín hiệu: ${actionLabel(plan.action)}`}>
        {(["buy", "sell", "wait"] as const).map((action) => (
          <div key={action} className={`choice${plan.action === action ? ` on ${action}` : ""}`} aria-current={plan.action === action ? "true" : undefined}>
            {actionLabel(action)}
          </div>
        ))}
      </div>
      {!plan.setup_status ? <p className="basis">Hướng H1: {plan.lean_label}</p> : null}
      {plan.setup_label ? <p className="basis">Setup: {plan.setup_label}</p> : null}
      {!plan.decision_plan && plan.action !== "wait" ? <p className="ticket-summary">Entry {plan.entry} · SL {plan.stop_loss} · TP {plan.take_profit} · {plan.spread_source === "observed" ? "R:R sau spread" : "R:R ước tính sau spread"} {plan.reward_risk_after_spread}</p> : null}
      <p className="ticket-summary">{plan.block_reason || plan.summary}</p>
      {plan.decision_plan ? <DecisionPlan plan={plan.decision_plan} confirmation={plan.action === "wait" ? plan.block_reason || plan.setup_label : undefined} /> : null}
      {!plan.decision_plan && plan.setup_id ? <details className="analysis-details">
        <summary>Thông số setup · Hết hạn {when(plan.setup_expires_at ?? null)}</summary>
        <dl className="setup-facts">
          <div><dt>Xác nhận lúc</dt><dd>{when(plan.setup_formed_at ?? null)}</dd></div>
          <div><dt>Giá tham chiếu ban đầu</dt><dd>{money(plan.reference_entry ?? 0)}</dd></div>
          <div><dt>ATR M15 tại xác nhận</dt><dd>{money(plan.reference_atr ?? 0)}</dd></div>
          <div><dt>Lệch bất lợi / tối đa</dt><dd>{plan.entry_adverse != null && plan.entry_limit != null ? `${money(plan.entry_adverse)} / ${money(plan.entry_limit)}` : "Chưa đánh giá"}</dd></div>
          <div><dt>SL / TP cố định</dt><dd>{money(plan.stop_loss)} / {money(plan.take_profit)}</dd></div>
          {plan.barrier ? <div><dt>Vùng cản phía trước</dt><dd>{money(plan.barrier.low)} – {money(plan.barrier.high)}</dd></div> : null}
        </dl>
      </details> : null}
      {visibleFlags?.map((flag) => <p className="banner warn" key={flag}>{flag}</p>)}
      {plan.mode === "signals_only" ? <p className="basis">Cấu hình thử nghiệm · Entry ≤ 0,30 ATR M15 · SL ≤ 5 ATR · R:R ước tính ≥ 1,5. Mỗi setup chỉ phát tín hiệu một lần.</p> : null}
      {plan.checks ? <details className="analysis-details">
        <summary>Kiểm tra điều kiện · {plan.checks.filter((c) => c.status !== "pass").length} chưa đạt hoặc chưa xác định</summary>
        <ul className="ticket-notes">{plan.checks.map((c) => <li key={c.code}>{c.status === "pass" ? "Đạt" : c.status === "unknown" ? "Chưa xác định" : "Chưa đạt"}: {c.reason}</li>)}</ul>
      </details> : null}
      {!plan.checks && plan.entry_guard?.blocked ? (
        <details className="analysis-details">
          <summary>Điều kiện chưa đạt · {plan.entry_guard.reasons.length}</summary>
          <ul className="ticket-notes">{plan.entry_guard.reasons.map((reason) => <li key={reason}>{reason}</li>)}</ul>
        </details>
      ) : null}
    </section>
  );
}

function actionLabel(action: CfdPlan["action"]) {
  return action === "buy" ? "Mua" : action === "sell" ? "Bán" : "Đứng ngoài";
}

import type { CfdPlan } from "../../lib/types";

type TradeTicketProps = {
  plan: CfdPlan;
  aiAction?: CfdPlan["action"] | null;
};

export function TradeTicket({ plan }: TradeTicketProps) {

  return (
    <section className={`ticket action-${plan.action}`} aria-labelledby="decision-title">
      <div className="panel-head">
        <h2 id="decision-title">Tín hiệu giao dịch</h2>
        <p>{plan.timeframe ?? "H1"} · {plan.market_state}</p>
      </div>
      <div className="decision" role="group" aria-label={`Khuyến nghị: ${actionLabel(plan.action)}`}>
        {(["buy", "sell", "wait"] as const).map((action) => (
          <div key={action} className={`choice${plan.action === action ? ` on ${action}` : ""}`} aria-current={plan.action === action ? "true" : undefined}>
            {actionLabel(action)}
          </div>
        ))}
      </div>
      <p className="basis">Hướng H1: {plan.lean_label}</p>
      {plan.setup_label ? <p className="basis">Setup: {plan.setup_label}</p> : null}
      {plan.action !== "wait" ? <p className="ticket-summary">Entry {plan.entry} · SL {plan.stop_loss} · TP {plan.take_profit} · R:R sau spread {plan.reward_risk_after_spread}</p> : null}
      <p className="ticket-summary">{plan.block_reason || plan.summary}</p>
      {plan.soft_flags?.map((flag) => <p className="banner warn" key={flag}>{flag}</p>)}
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

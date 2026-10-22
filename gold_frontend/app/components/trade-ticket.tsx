import type { CfdPlan } from "../../lib/types";

type TradeTicketProps = {
  plan: CfdPlan;
  aiAction?: CfdPlan["action"] | null;
};

export function TradeTicket({ plan, aiAction }: TradeTicketProps) {
  const adjusted = aiAction && aiAction !== plan.action;

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
      <p className="ticket-summary">{plan.block_reason || plan.summary}</p>
      {adjusted ? <p className="basis">Đề xuất AI: {actionLabel(aiAction)} · Quyết định sau kiểm tra: {actionLabel(plan.action)}.</p> : null}
      {plan.entry_guard?.blocked ? (
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

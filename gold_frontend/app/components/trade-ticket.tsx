import type { CfdPlan } from "../../lib/types";
import { money } from "../../lib/format";

type TradeTicketProps = {
  plan: CfdPlan;
  aiAction?: CfdPlan["action"] | null;
};

export function TradeTicket({ plan, aiAction }: TradeTicketProps) {
  const tone = plan.risk_score >= 7 ? "high" : plan.risk_score >= 4 ? "mid" : "low";

  const order = plan.action !== "wait";

  return (
    <section className={`ticket action-${plan.action}`}>
      <p className="eyebrow">Quyết định · H1 · {plan.market_state}</p>
      <div className="decision" role="group" aria-label="Quyết định giao dịch">
        <div className={plan.action === "buy" ? "choice on buy" : "choice"}>Mua</div>
        <div className={plan.action === "sell" ? "choice on sell" : "choice"}>Bán</div>
        <div className={plan.action === "wait" ? "choice on wait" : "choice"}>Không giao dịch</div>
      </div>
      <p className="ticket-summary">AI đề xuất: {aiAction ? actionLabel(aiAction) : "Chưa có quyết định AI hợp lệ"}{aiAction && aiAction !== plan.action ? ` · Đã chuyển sang ${actionLabel(plan.action)}: ${plan.block_reason}` : ""}</p>
      {plan.news_tone ? <p className="ticket-news">{plan.news_tone}</p> : null}
      <div className="ticket-top">
        <p className="ticket-summary">{plan.summary}</p>
        <div className={`risk risk-${tone}`}>
          <p>Rủi ro</p>
          <strong>
            {plan.risk_score}
            <span>/10</span>
          </strong>
          <p>{plan.risk_label}</p>
        </div>
      </div>

      {order ? <div className="levels">
        <article className="level level-entry">
          <p>Điểm vào</p>
          <strong>{money(plan.entry)}</strong>
          <span>Giá vào lệnh</span>
        </article>
        <article className="level level-sl">
          <p>Cắt lỗ · SL</p>
          <strong>{money(plan.stop_loss)}</strong>
          <span>Cách giá {money(plan.stop_distance)}</span>
        </article>
        <article className="level level-tp">
          <p>Chốt lời · TP</p>
          <strong>{money(plan.take_profit)}</strong>
          <span>Cách giá {money(plan.take_distance)}</span>
        </article>
      </div> : null}

      {order ? <dl className="ticket-stats">
        <div>
          <dt>Hướng giá</dt>
          <dd>{plan.lean_label}</dd>
        </div>
        <div>
          <dt>Lời so với lỗ</dt>
          <dd>{times(plan.reward_risk_after_spread)}</dd>
        </div>
        <div>
          <dt>Cắt lỗ cách giá</dt>
          <dd>{money(plan.stop_distance)}</dd>
        </div>
        <div>
          <dt>Chốt lời cách giá</dt>
          <dd>{money(plan.take_distance)}</dd>
        </div>
      </dl> : null}

      {order ? <ul className="ticket-notes">
        {plan.notes.map((note) => (
          <li key={note}>{note}</li>
        ))}
      </ul> : null}

      {plan.watchlist && plan.watchlist.length > 0 ? (
        <section className="watchlist" aria-label="Kịch bản chờ xác nhận">
          <div className="watchlist-head">
            <div>
              <p className="eyebrow">Liquidity sweep · H1</p>
              <h3>Kịch bản chờ xác nhận</h3>
            </div>
            <span>Chưa phải lệnh</span>
          </div>
          <div className="watchlist-grid">
            {plan.watchlist.map((zone) => (
              <article className={`watch-zone ${zone.side}`} key={zone.id}>
                <p className="watch-priority">{zone.priority}</p>
                <h4>{zone.title}</h4>
                <p className="watch-condition">{zone.condition}</p>
                <dl>
                  <div><dt>Vùng theo dõi</dt><dd>{money(zone.entry_low)} – {money(zone.entry_high)}</dd></div>
                  <div><dt>SL tham chiếu</dt><dd>{money(zone.stop_loss)}</dd></div>
                  <div><dt>TP tham chiếu</dt><dd>{money(zone.take_profit)}</dd></div>
                  <div><dt>R:R ước tính</dt><dd>1 : {zone.reward_risk.toFixed(2)}</dd></div>
                </dl>
              </article>
            ))}
          </div>
        </section>
      ) : null}
    </section>
  );
}

function times(value: number) {
  return `${value.toFixed(2).replace(".", ",")} lần`;
}

function actionLabel(action: CfdPlan["action"]) {
  return action === "buy" ? "Mua" : action === "sell" ? "Bán" : "Không giao dịch";
}

import type { DecisionPlan as Plan } from "../../lib/types";
import { money, when } from "../../lib/format";
import { RuleIcon } from "./rule-checklist";

export function DecisionPlan({ plan, confirmation }: { plan: Plan; confirmation?: string }) {
  const context = plan.technical_context;
  return <div className="decision-plan">
    <div className="plan-evidence"><h3>Lý do ưu tiên {plan.side === "neutral" ? "đứng ngoài" : plan.side.toUpperCase()}</h3>
      <ul>{plan.evidence.map((reason, i) => <li key={i}>{reason}</li>)}</ul>
    </div>
    {plan.branches?.length ? <div className="plan-branches">
      <h3>Các nhánh tìm entry</h3>
      <p className="basis">Đánh giá độc lập tại nến đóng {when(plan.branches_at ?? null)}. Có xác nhận ở một nhánh vẫn cần qua các điều kiện dữ liệu và rủi ro để phát tín hiệu.</p>
      <ul className="rule-cards">{plan.branches.map((branch) => <li className={`rule-card rule-card-${branch.status}`} key={`${branch.kind}-${branch.side}`}>
        <RuleIcon status={branch.status} /><div><strong>{branch.side.toUpperCase()} · {branch.kind === "trend_pullback" ? "Hồi theo xu hướng" : "Breakout–retest"}</strong><p>{branch.reason}</p></div>
      </li>)}</ul>
    </div> : null}
    {context ? <details className="analysis-details">
      <summary>Bằng chứng hỗ trợ · EMA, cấu trúc và Fibonacci</summary>
      <p className="basis">Bối cảnh H1 trước nến xác nhận · {when(context.as_of)}. Các yếu tố này hỗ trợ so sánh setup, không bắt buộc cùng đạt và không phải xác suất thắng.</p>
      {(plan.candidate_count ?? 0) > 1 ? <p className="basis">Đã so sánh {plan.candidate_count} vùng có xác nhận; ưu tiên setup đáp ứng điều kiện entry và R:R.</p> : null}
      <ul>{plan.supporting_evidence?.map((item) => <li key={item.code}>{item.supports ? "Hỗ trợ: " : "Bối cảnh: "}{item.reason}</li>)}</ul>
      <dl className="setup-facts">
        {context.ribbon.values.map((ema) => <div key={ema.period}><dt>EMA{ema.period} H1</dt><dd>{money(ema.value)}</dd></div>)}
        {[context.structure.high, context.structure.low].map((pivot, index) => pivot ? <div key={`pivot-${index}`}><dt>{pivot.label} · {when(pivot.pivot_at)}</dt><dd>{money(pivot.price)}</dd><span>Xác nhận {when(pivot.confirmed_at)}</span></div> : null)}
        {context.aoi.map((zone) => <div key={zone.id}><dt>{zone.id === "aoi_high_h1" ? "AOI trên H1" : "AOI dưới H1"}</dt><dd>{money(zone.low)} – {money(zone.high)}</dd></div>)}
        {context.rolling_4h ? <div><dt>Đáy / đỉnh 4 giờ đã đóng</dt><dd>{money(context.rolling_4h.low)} / {money(context.rolling_4h.high)}</dd></div> : null}
        {context.rolling_24h ? <div><dt>Đáy / đỉnh 24 giờ đã đóng</dt><dd>{money(context.rolling_24h.low)} / {money(context.rolling_24h.high)}</dd></div> : null}
      </dl>
      {context.fibonacci ? <>
        <p className="basis">Fibonacci nhịp {context.fibonacci.side === "buy" ? "tăng" : "giảm"}: đáy {money(context.fibonacci.low.price)} ({when(context.fibonacci.low.pivot_at)}) · đỉnh {money(context.fibonacci.high.price)} ({when(context.fibonacci.high.pivot_at)}). Hai điểm neo đã được xác nhận.</p>
        <dl className="setup-facts">{context.fibonacci.levels.map((level) => <div key={level.ratio}><dt>Fib {level.ratio}</dt><dd>{money(level.price)}</dd></div>)}</dl>
      </> : null}
    </details> : null}
    <dl className="plan-levels">
      <div><dt>{plan.entry_zone_kind === "watch" ? "Vùng theo dõi · chưa xác nhận" : "Vùng vào tham chiếu"}</dt>
        <dd>{plan.entry_zone ? `${money(plan.entry_zone.low)} – ${money(plan.entry_zone.high)}` : "Chưa có vùng entry đủ điều kiện"}</dd>
        <p>{plan.entry_zone_kind === "watch" ? "Chờ giá phản ứng và nến M15 xác nhận tại vùng." : plan.entry_policy === "rr_constrained" ? "Khoảng giá đáp ứng cấu trúc, SL ≤ 5 ATR và R:R tới TP/cản đầu tiên ≥ 1,5. Lệch quá 0,30 ATR chỉ cảnh báo; vẫn cần dữ liệu mới." : "Khoảng entry theo chính sách tại thời điểm lưu kế hoạch; vẫn cần kiểm tra hiệu lực và dữ liệu mới."}</p>
      </div>
      <div><dt>SL · Điểm vô hiệu</dt><dd>{plan.stop_loss != null ? money(plan.stop_loss) : "Chờ xác nhận"}</dd><p>{plan.stop_reason}</p></div>
      <div><dt>TP · Mục tiêu theo cấu trúc</dt><dd>{plan.take_profit != null ? money(plan.take_profit) : "Chưa xác định"}</dd><p>{plan.target_reason}</p></div>
      {plan.reference_entry != null ? <div><dt>Entry tham chiếu · nến xác nhận</dt><dd>{money(plan.reference_entry)}</dd><p>Nến M15 đóng lúc {when(plan.reference_at ?? null)}.</p><p>R:R tại entry tham chiếu: {plan.reference_reward_risk != null ? `1 : ${plan.reference_reward_risk}` : "Chưa đủ căn cứ tính"}. {plan.cost.description}</p></div> : null}
      <div><dt>R:R tại báo giá hiện tại · sau chi phí ước tính</dt><dd>{plan.reward_risk != null ? `1 : ${plan.reward_risk}` : "Chưa kiểm tra entry hiện tại"}</dd>
        {plan.current_entry != null ? <p>Giá nguồn {money(plan.current_entry)} · {when(plan.current_quote_at ?? null)}.</p> : null}
        <p>{plan.reward_risk_basis}</p>{plan.reward_risk != null || (plan.entry_zone_kind === "eligible" && plan.entry_zone) ? <p>{plan.cost.description}</p> : null}
        {plan.cost_sensitivity ? <p>Kịch bản chi phí gấp đôi spread ({money(plan.cost_sensitivity.stress_cost)} USD/oz): R:R {plan.cost_sensitivity.stress_reward_risk}, tại {plan.current_entry != null ? "báo giá mới" : "entry tham chiếu"}. Đây là phép thử độ nhạy, không phải điều kiện chặn thêm.</p> : null}
      </div>
    </dl>
    <div className="plan-confirmation"><h3>Điều kiện xác nhận</h3><p>{confirmation ?? plan.confirmation}</p><p className="basis">{plan.trigger}</p></div>
    <div className="plan-validity"><h3>Hiệu lực và điều kiện hủy</h3>
      <p>{plan.expires_at ? `Xác nhận ${when(plan.formed_at)} · Hết hạn ${when(plan.expires_at)}` : "Chưa phát tín hiệu. Thời hạn 30 phút bắt đầu khi M15 xác nhận setup."}</p>
      <ul>{plan.cancellation.map((reason) => <li key={reason}>{reason}</li>)}</ul>
    </div>
    <p className="basis">Nguồn mức giá: {plan.source}. Đây là kế hoạch tham khảo, không xác nhận lệnh đã khớp.</p>
  </div>;
}

import type { RuleCheck } from "../../lib/types";
import { checkCounts, checkState, ruleLabels } from "../../lib/rule-checks";

const labels = { pass: "Đạt", blocked: "Chưa đạt", unknown: "Chờ xác nhận", warning: "Khuyến nghị" };

export function RuleIcon({ status }: { status: RuleCheck["status"] }) {
  return <svg className={`rule-icon rule-${status}`} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {status === "warning" ? <><path d="M12 3 22 21H2L12 3Z"/><path d="M12 9v5m0 3v.1"/></> : <>
      <circle cx="12" cy="12" r="9"/>
      {status === "pass" ? <path d="m8 12 3 3 5-6"/> : status === "blocked" ? <path d="m9 9 6 6m0-6-6 6"/> : <path d="M12 7v5l3 2"/>}
    </>}
  </svg>;
}

export function RuleChecklist({ checks }: { checks: RuleCheck[] }) {
  const counts = checkCounts(checks);
  return <section className="rule-checklist" aria-label="Kiểm tra điều kiện phát tín hiệu">
    <h3>Kiểm tra điều kiện</h3>
    <div className="rule-legend">{(Object.keys(labels) as RuleCheck["status"][]).map((status) =>
      <span key={status}><RuleIcon status={status}/>{labels[status]} <strong>{counts[status]}</strong></span>
    )}</div>
    <p className="basis">Điều kiện bắt buộc phải đạt trước khi phát tín hiệu. Khuyến nghị không tự chặn BUY/SELL; điều kiện theo setup chỉ áp dụng cho nhánh đang xét.</p>
    <ul className="rule-cards">{checks.map((check) => {
      const status = checkState(check);
      const scope = check.required === false ? "Không bắt buộc" : check.scope === "setup" ? "Theo setup" : "Bắt buộc";
      return <li key={check.code} className={`rule-card rule-card-${status}`}>
        <RuleIcon status={status}/><div><div className="rule-card-heading"><strong>{ruleLabels[check.code] ?? check.code}</strong><span>{scope}</span></div>
        <p><span className={`rule-state rule-${status}`}>{labels[status]}</span> · {check.reason}</p></div>
      </li>;
    })}</ul>
  </section>;
}

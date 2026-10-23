import type { RuleStatistics as Statistics } from "../../lib/types";

import { ruleLabels } from "../../lib/rule-checks";
import { RuleIcon } from "./rule-checklist";

export function RuleStatistics({ data }: { data: Statistics }) {
  return <details className="panel analysis-details">
    <summary>Thống kê điều kiện · {data.evaluations} lần đánh giá / {data.days} ngày</summary>
    <p className="basis">“Chặn duy nhất” chỉ đếm khi mọi điều kiện bắt buộc khác đều đạt; bỏ qua các khuyến nghị. Đây là thống kê bộ lọc, chưa phải kết quả lời/lỗ.</p>
    {data.checks.length ? <div className="rule-table-scroll">
      <table className="rule-table">
        <caption>Bộ rule {data.version}</caption>
        <thead><tr><th scope="col">Điều kiện</th><th scope="col">Đánh giá</th><th scope="col"><span className="rule-column"><RuleIcon status="pass"/>Đạt</span></th><th scope="col"><span className="rule-column"><RuleIcon status="blocked"/>Chặn</span></th><th scope="col"><span className="rule-column"><RuleIcon status="unknown"/>Chờ</span></th><th scope="col"><span className="rule-column"><RuleIcon status="warning"/>Khuyến nghị</span></th><th scope="col">Chặn duy nhất</th></tr></thead>
        <tbody>{data.checks.map((row) => <tr key={row.code}>
          <th scope="row">{ruleLabels[row.code] || row.code}</th><td>{row.evaluated}</td><td>{row.pass}</td><td>{row.blocked}</td><td>{row.unknown}</td><td>{row.warning ?? 0}</td><td>{row.sole_blocker}</td>
        </tr>)}</tbody>
      </table>
    </div> : <p className="empty">Chưa có đánh giá được lưu cho bộ rule này.</p>}
  </details>;
}

"use client";
import { useEffect, useState } from "react";
import { fetchSignalHistory } from "../../lib/api";
import { money, when } from "../../lib/format";
import type { SignalHistoryData } from "../../lib/types";
import { DecisionPlan } from "./decision-plan";

const outcomes: Record<string, string> = {
  pending_entry: "Đang chờ chạm entry", entry_touched: "Đã chạm entry · đang theo dõi",
  tp_first: "Chạm TP trước", sl_first: "Chạm SL trước", ambiguous: "Không xác định thứ tự",
  expired_without_entry: "Hết hạn · chưa thấy chạm entry", expired_after_entry: "Hết theo dõi · chưa chạm TP/SL",
  invalidated_before_entry: "Vô hiệu trước entry", cancelled_without_entry: "Đã hủy trước entry",
  data_gap: "Thiếu dữ liệu · chưa kết luận", legacy: "Tín hiệu cũ · không có mô phỏng",
};
const validity = { active: "Còn hiệu lực", expired: "Hết hạn", invalidated: "Bị vô hiệu", unknown: "Chưa xác định hiệu lực" };
const admissionLabel = (value?: string) => value === "late_entry" ? "Nhận thêm · entry muộn" : value === "reference_band" ? "Trong ngưỡng 0,30 ATR" : "Chưa phân nhóm";
const branchLabel = (value?: string) => value === "trend_pullback" ? "Hồi theo xu hướng" : value === "breakout_retest" ? "Breakout–retest" : "Chưa phân nhánh";

export function SignalHistory() {
  const [data, setData] = useState<SignalHistoryData | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    async function load() {
      try { const next = await fetchSignalHistory(); if (!cancelled) { setData(next); setError(null); } }
      catch (e) { if (!cancelled) setError(e instanceof Error ? e.message : "Không tải được lịch sử."); }
    }
    void load();
    const timer = window.setInterval(() => void load(), 60_000);
    return () => { cancelled = true; window.clearInterval(timer); };
  }, []);
  return <section className="panel signal-history" aria-labelledby="history-title">
    <div className="panel-head"><h2 id="history-title">Lịch sử tín hiệu và mô phỏng</h2><p>{data ? `${data.items.length} tín hiệu gần nhất` : "Đang tải lịch sử…"}</p></div>
    <p className="basis">Theo dõi chạm giá bằng nến M15 trọn vẹn kế tiếp sau lúc phát tín hiệu, tối đa 2 giờ. Bỏ qua phần nến trước thời điểm theo dõi. Chạm entry không chứng minh khớp lệnh; kết quả không phải lợi nhuận thực tế.</p>
    <p className="basis">Cùng nến chạm TP và SL, hoặc không biết entry có xảy ra trước mức thoát: ghi “không xác định”. Thiếu nến: chưa kết luận.</p>
    {error ? <p className="banner bad" role="alert">{data ? "Lịch sử chưa cập nhật. " : ""}{error}</p> : null}
    {data && data.items.length > 0 ? <>
      <div className="history-summary"><span>TP trước: <strong>{data.summary.tp_first ?? 0}</strong></span><span>SL trước: <strong>{data.summary.sl_first ?? 0}</strong></span><span>Không xác định: <strong>{data.summary.ambiguous ?? 0}</strong></span></div>
      {data.groups?.length ? <details className="analysis-details">
        <summary>So sánh nhóm entry · {data.items.length} tín hiệu gần nhất</summary>
        <p className="basis">Phân nhóm theo giá lúc phát tín hiệu, không đổi khi giá chạy tiếp. R mô phỏng trừ spread đã lưu; chỉ tính các mẫu biết TP/SL chạm trước. Không gồm phí, trượt giá hoặc kết quả chưa xác định.</p>
        <p className="basis">Sụt giảm R là mức giảm từ đỉnh của tổng R mẫu đã kết thúc, xếp theo thời điểm phát; không phải sụt giảm tài khoản. Bảng chỉ dùng các tín hiệu đang tải, chưa phải kiểm thử ngoài mẫu.</p>
        <div className="rule-table-scroll"><table className="rule-table">
          <thead><tr><th>Phiên bản / nhánh</th><th>Nhóm</th><th>Tín hiệu</th><th>TP / SL</th><th>Đủ dữ liệu tính R</th><th>Tổng R ước tính</th><th>Sụt giảm R</th></tr></thead>
          <tbody>{data.groups.map((group) => <tr key={`${group.version}-${group.side}-${group.setup_kind}-${group.entry_admission}`}>
            <th scope="row">{group.side.toUpperCase()} · {branchLabel(group.setup_kind)}<br />{group.version}</th>
            <td>{admissionLabel(group.entry_admission)}</td><td>{group.signals}</td><td>{group.outcomes.tp_first ?? 0} / {group.outcomes.sl_first ?? 0}</td><td>{group.settled}</td><td>{group.estimated_net_r ?? "Chưa có"}</td><td>{group.settled_drawdown_r ?? "Chưa có"}</td>
          </tr>)}</tbody>
        </table></div>
      </details> : null}
      {data.items.map((item) => <details className="history-item" key={item.setup_id}>
        <summary><strong>{item.side.toUpperCase()}</strong><span>{when(item.published_at)}</span><span>{validity[item.validity === "active" && item.expires_at && Date.now() >= Date.parse(item.expires_at) ? "expired" : item.validity]}</span><strong>{outcomes[item.result.status] ?? "Chưa đánh giá"}</strong></summary>
        {item.validity_reason ? <p className="basis">{item.validity_reason}</p> : null}
        <dl className="setup-facts">
          <div><dt>Phiên bản rule</dt><dd>{item.version}</dd></div>
          <div><dt>Nhánh / nhóm lúc phát</dt><dd>{branchLabel(item.setup_kind)} · {admissionLabel(item.entry_admission)}</dd></div>
          <div><dt>Kết quả sau spread mô phỏng</dt><dd>{item.estimated_net_r != null ? `${item.estimated_net_r.toFixed(2)} R` : "Chưa đủ dữ liệu"}</dd></div>
          <div><dt>Quan sát từ</dt><dd>{when(item.result.observed_from ?? null)}</dd></div>
          <div><dt>Đã kiểm tra tới</dt><dd>{when(item.result.observed_through ?? null)}</dd></div>
          <div><dt>Chạm vùng entry</dt><dd>{item.result.entry_touched ? `Có${item.result.entry_price != null ? ` · ${money(item.result.entry_price)}` : ""}` : "Chưa ghi nhận"}</dd></div>
          <div><dt>Nến chạm entry · giờ mở nến</dt><dd>{when(item.result.entry_bar_at ?? null)}</dd></div>
          <div><dt>Nến chạm mức thoát · giờ mở nến</dt><dd>{when(item.result.exit_bar_at ?? null)}</dd></div>
          <div><dt>Kết thúc cửa sổ theo dõi</dt><dd>{when(item.horizon_at)}</dd></div>
        </dl>
        {item.result.detail ? <p className="basis">{item.result.detail}</p> : null}
        {item.plan ? <><h3>Kế hoạch tại lúc phát tín hiệu</h3><DecisionPlan plan={item.plan} /></> : null}
      </details>)}
    </> : data ? <p className="empty">Chưa có tín hiệu được lưu. Lịch sử sẽ xuất hiện khi có setup mới đủ điều kiện.</p> : null}
  </section>;
}

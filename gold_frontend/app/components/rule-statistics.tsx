import type { RuleStatistics as Statistics } from "../../lib/types";

const labels: Record<string, string> = {
  data: "Dữ liệu OHLC", bias: "Hướng H1", m15_data: "Dữ liệu M15", zoi: "Vùng giá",
  trigger: "Xác nhận M15", direction: "Đồng hướng H1", setup_lifetime: "Thời hạn setup",
  structure: "Cấu trúc giá", calendar_data: "Dữ liệu lịch tin", calendar_window: "Cửa sổ tin",
  session: "Phiên giao dịch", quote: "Độ mới báo giá", entry_drift: "Lệch entry",
  levels: "SL / TP", barrier_room: "Khoảng trống tới vùng cản", reward_risk: "R:R sau chi phí",
  setup_invalidation: "Setup đã vô hiệu", setup_target: "Mục tiêu chưa bị chạm", target_structure: "TP theo cấu trúc",
};

export function RuleStatistics({ data }: { data: Statistics }) {
  return <details className="panel analysis-details">
    <summary>Điều kiện đang chặn tín hiệu · {data.evaluations} lần đánh giá / {data.days} ngày</summary>
    <p className="basis">“Chặn duy nhất” chỉ đếm khi mọi điều kiện khác đều đạt. Đây là thống kê bộ lọc, chưa phải kết quả lời/lỗ.</p>
    {data.checks.length ? <div className="rule-table-scroll">
      <table className="rule-table">
        <caption>Bộ rule {data.version}</caption>
        <thead><tr><th scope="col">Điều kiện</th><th scope="col">Đánh giá</th><th scope="col">Đạt</th><th scope="col">Chặn</th><th scope="col">Chưa xác định</th><th scope="col">Chặn duy nhất</th></tr></thead>
        <tbody>{data.checks.map((row) => <tr key={row.code}>
          <th scope="row">{labels[row.code] || row.code}</th><td>{row.evaluated}</td><td>{row.pass}</td><td>{row.blocked}</td><td>{row.unknown}</td><td>{row.sole_blocker}</td>
        </tr>)}</tbody>
      </table>
    </div> : <p className="empty">Chưa có đánh giá được lưu cho bộ rule này.</p>}
  </details>;
}

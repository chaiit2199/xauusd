import { when } from "../../lib/format";

function renderInsight(text: string) {
  return text.split(/(\*\*[^*]+\*\*)/g).map((part, index) => {
    if (part.startsWith("**") && part.endsWith("**")) {
      return <strong key={index}>{part.slice(2, -2)}</strong>;
    }

    return <span key={index}>{part}</span>;
  });
}

type AiReportProps = {
  insight: string | null;
  error: string | null;
  pending: boolean;
  elapsed: number;
  cachedAt?: string | null;
};

export function AiReport({
  insight,
  error,
  pending,
  elapsed,
  cachedAt,
}: AiReportProps) {
  return (
    <section className="panel ai-panel">
      <div className="panel-head">
        <h2>Phân tích H1</h2>
        <p>
          {cachedAt
            ? `Cập nhật lúc ${when(cachedAt)}`
            : "Giải thích ngắn theo phiếu lệnh"}
        </p>
      </div>

      {pending ? (
        <p className="empty">Đang soạn diễn giải. Đã {elapsed} giây.</p>
      ) : null}

      {error ? <p className="ai-error">{error}</p> : null}

      {insight ? <div className="ai-body">{renderInsight(insight)}</div> : null}

      {!pending && !error && !insight ? (
        <p className="empty">
          Bấm «Nhận định H1» để đọc giải thích. Phiếu lệnh phía trên là quyết
          định.
        </p>
      ) : null}
    </section>
  );
}

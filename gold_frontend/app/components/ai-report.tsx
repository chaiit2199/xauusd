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
  newsTone?: string | null;
  nextInSeconds?: number | null;
  intervalSeconds?: number;
};

export function AiReport({
  insight,
  error,
  pending,
  elapsed,
  cachedAt,
  newsTone,
  nextInSeconds,
  intervalSeconds = 300,
}: AiReportProps) {
  const cadence = Math.round(intervalSeconds / 60);

  return (
    <section className="panel ai-panel">
      <div className="panel-head">
        <h2>Nhận định H1 · {cadence} phút</h2>
        <p>
          {pending
            ? `Đang soạn từ giá + chỉ báo + tin… ${elapsed}s`
            : cachedAt
              ? `Cập nhật lúc ${when(cachedAt)}${
                  nextInSeconds != null && nextInSeconds > 0
                    ? ` · lần sau ~${formatCountdown(nextInSeconds)}`
                    : ""
                }`
              : `Tự chạy mỗi ${cadence} phút theo data và tin hiện có`}
        </p>
      </div>

      {newsTone ? <p className="ai-meta">{newsTone}</p> : null}

      {pending ? (
        <p className="empty">Đang soạn diễn giải. Đã {elapsed} giây.</p>
      ) : null}

      {error ? <p className="ai-error">{error}</p> : null}

      {insight ? <div className="ai-body">{renderInsight(insight)}</div> : null}

      {!pending && !error && !insight ? (
        <p className="empty">
          Đang chờ chu kỳ nhận định đầu tiên (backend tự chạy sau vài giây).
          Phiếu lệnh phía trên là quyết định; phần này giải thích bằng số liệu
          và tin.
        </p>
      ) : null}
    </section>
  );
}

function formatCountdown(seconds: number) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  if (m <= 0) return `${s}s`;
  return `${m}m${s.toString().padStart(2, "0")}s`;
}

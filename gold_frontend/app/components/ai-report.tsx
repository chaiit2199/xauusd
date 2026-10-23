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
  ruleCommentary?: string;
  aiStatus?: string;
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
  ruleCommentary,
  aiStatus,
  error,
  pending,
  elapsed,
  cachedAt,
  newsTone,
  nextInSeconds,
  intervalSeconds = 900,
}: AiReportProps) {
  const cadence = Math.round(intervalSeconds / 60);

  return (
    <section className="panel ai-panel">
      <div className="panel-head">
        <h2>Phân tích thị trường · H1 → M15 · {cadence} phút</h2>
        <p>
          {pending
            ? `Đang phân tích giá, chỉ báo và tin tức… ${elapsed} giây`
            : cachedAt
              ? `Cập nhật lúc ${when(cachedAt)}${
                  nextInSeconds != null && nextInSeconds > 0
                    ? ` · cập nhật sau khoảng ${formatCountdown(nextInSeconds)}`
                    : " · đang chờ kết quả chu kỳ mới"
                }`
              : `Tự động cập nhật mỗi ${cadence} phút theo dữ liệu thị trường`}
        </p>
      </div>

      {ruleCommentary ? <div className="ai-body"><strong>Phân tích theo rule</strong><p>{ruleCommentary}</p></div> : null}
      {newsTone ? <p className="ai-meta">{newsTone}</p> : null}

      {pending ? (
        <p className="empty">Đang tổng hợp nhận định thị trường · {elapsed} giây.</p>
      ) : null}

      {error ? <p className="ai-error">{error}</p> : null}

      {insight ? <div className="ai-body"><strong>Bình luận AI</strong><p>{renderInsight(insight)}</p></div> : null}

      {!pending && !error && !insight ? (
        <p className="empty">
          {aiStatus === "pending" ? "Rule đã phát phiếu; AI đang bổ sung bình luận." : "AI được gọi khi rule có phiếu BUY/SELL. Phân tích rule vẫn cập nhật khi đứng ngoài."}
        </p>
      ) : null}
    </section>
  );
}

function formatCountdown(seconds: number) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  if (m <= 0) return `${s} giây`;
  return `${m} phút ${s.toString().padStart(2, "0")} giây`;
}

import type { Indicators } from "../../lib/types";
import { num } from "../../lib/format";

type Tone = "up" | "down" | "warn" | "neutral";

type IndicatorGridProps = {
  indicators: Indicators;
  alerts: string[];
};

export function IndicatorGrid({ indicators, alerts }: IndicatorGridProps) {
  const price = indicators.current_price;
  const cards: { label: string; value: string; note: string; tone: Tone }[] = [
    {
      label: "SMA 20",
      value: num(indicators.sma_20),
      note: "Trung bình 20 giờ",
      tone: price > indicators.sma_20 ? "up" : price < indicators.sma_20 ? "down" : "neutral",
    },
    {
      label: "EMA 50",
      value: num(indicators.ema_50),
      note: "Trung bình mũ 50 giờ",
      tone: price > indicators.ema_50 ? "up" : price < indicators.ema_50 ? "down" : "neutral",
    },
    {
      label: "RSI 14",
      value: num(indicators.rsi_14),
      note: "Chặn SELL < 35 · BUY > 65",
      tone: indicators.rsi_14 > 65 || indicators.rsi_14 < 35 ? "warn" : "neutral",
    },
    {
      label: "MACD",
      value: num(indicators.macd, 4),
      note: "EMA 12 trừ EMA 26",
      tone: indicators.macd > 0 ? "up" : indicators.macd < 0 ? "down" : "neutral",
    },
    {
      label: "Bollinger",
      value: `${num(indicators.bollinger_bands.upper)} / ${num(indicators.bollinger_bands.lower)}`,
      note: "Biên trên / biên dưới",
      tone:
        price > indicators.bollinger_bands.upper || price < indicators.bollinger_bands.lower
          ? "warn"
          : "neutral",
    },
    {
      label: "ATR 14",
      value: num(indicators.atr_14),
      note: "Biên độ đóng cửa theo giờ",
      tone: "neutral",
    },
    {
      label: "Stochastic %K",
      value: num(indicators.stochastic_k),
      note: "Chặn SELL < 30 · BUY > 75",
      tone: indicators.stochastic_k > 75 || indicators.stochastic_k < 30 ? "warn" : "neutral",
    },
    {
      label: "Pivot",
      value: num(indicators.pivot_level.p),
      note: `Kháng cự R1 ${num(indicators.pivot_level.r1)} · Hỗ trợ S1 ${num(indicators.pivot_level.s1)}`,
      tone: "neutral",
    },
    {
      label: "ROC 10",
      value: `${num(indicators.roc_10)}%`,
      note: "Đà 10 giờ",
      tone: indicators.roc_10 > 0 ? "up" : indicators.roc_10 < 0 ? "down" : "neutral",
    },
    {
      label: "Độ lệch chuẩn",
      value: num(indicators.volatility_std, 4),
      note: "Cửa sổ 20 giờ",
      tone: "neutral",
    },
  ];

  return (
    <section className="panel">
      <div className="panel-head">
        <h2>Chỉ báo kỹ thuật · H1</h2>
        <p>Tính trên giá đóng cửa từng giờ.</p>
      </div>
      <div className="indicator-grid">
        {cards.map((card) => (
          <article key={card.label} className={`indicator tone-${card.tone}`}>
            <p className="indicator-label">{card.label}</p>
            <p className="indicator-value">{card.value}</p>
            <p className="indicator-note">{card.note}</p>
          </article>
        ))}
      </div>
      <ul className="alerts">
        {alerts.length === 0 ? (
          <li>Không có cảnh báo nổi bật trên cửa sổ này.</li>
        ) : (
          alerts.map((alert) => <li key={alert}>{alert}</li>)
        )}
      </ul>
    </section>
  );
}

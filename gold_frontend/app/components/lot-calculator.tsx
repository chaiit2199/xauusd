"use client";

import { useState } from "react";
import { money, num } from "../../lib/format";
import { positionSize } from "../../lib/position-size";

const fields = [
  { key: "capital", label: "Vốn tính rủi ro (USD)", value: "", placeholder: "10.000 USD" },
  { key: "riskPercent", label: "Rủi ro (%)", value: "1", placeholder: "1" },
  { key: "entry", label: "Giá vào (USD / oz)", value: "", placeholder: "Nhập giá dự kiến" },
  { key: "stop", label: "Cắt lỗ · SL (USD / oz)", value: "", placeholder: "Nhập mức cắt lỗ" },
  { key: "contractSize", label: "Quy mô hợp đồng (oz / lot)", value: "100", placeholder: "100" },
  { key: "leverage", label: "Đòn bẩy (1 : x)", value: "20", placeholder: "20" },
  { key: "lotStep", label: "Bước khối lượng (lot)", value: "0.01", placeholder: "0,01" },
  { key: "minLot", label: "Khối lượng tối thiểu (lot)", value: "0.01", placeholder: "0,01" },
] as const;

type FieldKey = typeof fields[number]["key"];

export function LotCalculator({ currentPrice, initialSide = "buy" }: { currentPrice?: string; initialSide?: "buy" | "sell" }) {
  const [side, setSide] = useState(initialSide);
  const [values, setValues] = useState<Record<FieldKey, string>>(
    () => Object.fromEntries(fields.map((field) => [field.key, field.value])) as Record<FieldKey, string>,
  );
  const [submitted, setSubmitted] = useState(false);
  const result = positionSize({ side, ...Object.fromEntries(fields.map(({ key }) => [key, Number(values[key])])) } as Parameters<typeof positionSize>[0]);
  const validQuote = currentPrice && Number.isFinite(Number(currentPrice)) && Number(currentPrice) > 0;

  return (
    <section className="panel calculator" aria-labelledby="calculator-title">
      <div className="panel-head"><h2 id="calculator-title">Tính khối lượng lệnh</h2><span className="connection-label">Ước tính · Tài khoản USD</span></div>
      <p className="empty">Chọn chiều giao dịch và mức cắt lỗ để tính lot, rủi ro và ký quỹ.</p>
      <form onSubmit={(event) => { event.preventDefault(); setSubmitted(true); }}>
        <div className="side-picker" role="group" aria-label="Chiều giao dịch dự kiến">
          <button type="button" className="side-buy" aria-pressed={side === "buy"} onClick={() => setSide("buy")}>Mua</button>
          <button type="button" className="side-sell" aria-pressed={side === "sell"} onClick={() => setSide("sell")}>Bán</button>
        </div>
        <div className="calculator-fields">
          {fields.map((field) => <label key={field.key} htmlFor={`lot-${field.key}`}>
            <span>{field.label}</span>
            <input id={`lot-${field.key}`} type="number" inputMode="decimal" min="0.000001" step="any" required
              max={field.key === "riskPercent" ? 100 : undefined}
              placeholder={field.placeholder} value={values[field.key]}
              onChange={(event) => setValues((previous) => ({ ...previous, [field.key]: event.target.value }))} />
          </label>)}
        </div>
        <div className="calculator-actions">
          <button className="primary" type="submit">Tính khối lượng</button>
          {validQuote ? <button type="button" onClick={() => setValues((previous) => ({ ...previous, entry: currentPrice! }))}>Dùng báo giá {money(currentPrice!)}</button> : null}
        </div>
      </form>
      {submitted ? <div aria-live="polite" className="calculator-result">
        {result.error ? <p className="banner warn">{result.error}</p> : <>
          <dl className="quote-stats">
            <div><dt>Khối lượng</dt><dd>{num(result.lots, 6).replace(/\.?0+$/, "")} lot</dd><span>Đã làm tròn xuống theo bước lot</span></div>
            <div><dt>Rủi ro tại SL</dt><dd>{money(result.risk)}</dd><span>Ngân sách {money(result.riskBudget)}</span></div>
            <div><dt>Ký quỹ ước tính</dt><dd>{money(result.margin)}</dd><span>Đòn bẩy 1 : {num(Number(values.leverage), 0)}</span></div>
            <div><dt>Giá trị vị thế</dt><dd>{money(result.notional)}</dd><span>Giá vào × số oz</span></div>
          </dl>
          {result.margin > Number(values.capital) ? <p className="banner warn">Ký quỹ ước tính vượt vốn đã nhập. Kiểm tra ký quỹ khả dụng tại broker.</p> : null}
        </>}
      </div> : null}
      <details className="calculator-notes">
        <summary>Giả định & công thức</summary>
        <p>Lot = ngân sách rủi ro ÷ (khoảng cách SL × oz/lot). Ký quỹ = giá vào × lot × oz/lot ÷ đòn bẩy.</p>
        <p>Thông số mặc định chỉ để tính thử; chỉnh quy mô hợp đồng, bước lot và đòn bẩy theo broker. Chưa bao gồm spread, phí, trượt giá hoặc ký quỹ theo bậc. Công cụ không gửi lệnh.</p>
        <a href="https://help.oanda.com/bvi/en/faqs/margin-rules-bvi.htm" target="_blank" rel="noreferrer">Tham khảo cách tính ký quỹ · OANDA ↗</a>
      </details>
    </section>
  );
}

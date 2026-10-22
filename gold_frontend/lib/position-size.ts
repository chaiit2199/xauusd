export type PositionInputs = {
  side: "buy" | "sell";
  capital: number;
  riskPercent: number;
  entry: number;
  stop: number;
  contractSize: number;
  leverage: number;
  lotStep: number;
  minLot: number;
};

// USD account; linear XAUUSD CFD. Contract specifications are user inputs.
export function positionSize(input: PositionInputs) {
  const { side, capital, riskPercent, entry, stop, contractSize, leverage, lotStep, minLot } = input;
  if (![capital, riskPercent, entry, stop, contractSize, leverage, lotStep, minLot].every((n) => Number.isFinite(n) && n > 0)) {
    return { error: "Nhập đầy đủ các giá trị lớn hơn 0." } as const;
  }
  if (riskPercent > 100 || leverage < 1 || lotStep < 0.000001) {
    return { error: "Rủi ro tối đa 100%, đòn bẩy từ 1 và bước lot từ 0,000001." } as const;
  }
  if ((side === "buy" && stop >= entry) || (side === "sell" && stop <= entry)) {
    return { error: side === "buy" ? "Lệnh Mua cần SL thấp hơn giá vào." : "Lệnh Bán cần SL cao hơn giá vào." } as const;
  }
  const riskBudget = capital * riskPercent / 100;
  const riskPerLot = Math.abs(entry - stop) * contractSize;
  const rawLots = riskBudget / riskPerLot;
  // Round down to broker's lot increment; never round a risk budget up.
  let lots = Number((Math.floor(rawLots / lotStep) * lotStep).toFixed(6));
  if (lots * riskPerLot > riskBudget) lots = Number((lots - lotStep).toFixed(6));
  if (lots < minLot) return { error: "Ngân sách rủi ro không đủ cho khối lượng tối thiểu." } as const;
  const notional = lots * contractSize * entry;
  const margin = notional / leverage;
  const risk = lots * riskPerLot;
  if (![lots, notional, margin, risk].every(Number.isFinite)) return { error: "Giá trị vượt phạm vi tính toán." } as const;
  return { lots, riskBudget, risk, notional, margin } as const;
}

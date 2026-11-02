import assert from "node:assert/strict";
import { test } from "node:test";
import {
  indicators,
  normalizeCandles,
  recentNews,
  observed,
  simulatedR,
  fmt,
} from "../lib/template-data.ts";
const bars = (n) =>
  Array.from({ length: n }, (_, i) => ({
    t: i * 900000,
    o: 100 + i,
    h: 102 + i,
    l: 99 + i,
    c: 101 + i,
  }));
test("indicators handle empty, flat, rising and gapped real series without NaN", () => {
  assert.equal(indicators([]).atr, null);
  assert.equal(indicators(bars(5)).rsi[4], null);
  assert.equal(indicators(bars(160)).rsi[159], 100);
  const flat = bars(160).map((c) => ({ ...c, o: 100, h: 100, l: 100, c: 100 }));
  assert.equal(indicators(flat).rsi[159], 50);
  assert.equal(indicators(flat).atr, 0);
  const missing = bars(160).filter((_, i) => i !== 150),
    v = indicators(missing);
  assert.equal(v.continuous, 9);
  assert.equal(v.atr, null);
  assert.equal(v.e20[149], null);
  assert.equal(fmt(NaN), "—");
  assert.equal(fmt(undefined), "—");
});
test("normalization sorts and deduplicates, rejecting impossible candles", () => {
  const b = bars(3);
  assert.deepEqual(
    normalizeCandles([b[2], b[0], b[0], b[1], { ...b[0], t: 3000000, h: 0 }]),
    b,
  );
});
test("news uses UTC day boundaries and excludes future and unknown publication times", () => {
  const now = Date.parse("2026-11-02T01:00:00Z");
  const times = [
    "2026-10-31T23:59:59Z",
    "2026-11-01T00:00:00Z",
    "2026-11-02T00:30:00Z",
    "2026-11-02T02:00:00Z",
    null,
  ];
  assert.deepEqual(
    recentNews(
      times.map((published_at) => ({ published_at })),
      now,
    ).map((a) => a.published_at),
    [times[2], times[1]],
  );
});
test("R uses stored simulator entry, and never changes ambiguous or expired results", () => {
  const s = {
    plan: { reference_entry: 100, take_profit: 110, stop_loss: 95 },
    result: { entry_price: 101, status: "tp_first" },
  };
  assert.equal(simulatedR(s), 1.5);
  assert.equal(
    simulatedR({ ...s, result: { ...s.result, status: "sl_first" } }),
    -1,
  );
  for (const status of [
    "ambiguous",
    "expired_after_entry",
    "data_gap",
    "pending_entry",
  ])
    assert.equal(simulatedR({ ...s, result: { status } }), 0);
  assert.equal(
    simulatedR({ plan: null, result: { status: "tp_first" } }),
    null,
  );
});
test("high/low requires complete observed candles, does not fabricate missing history", () => {
  const s = {
    result: {
      observed_from: new Date(0).toISOString(),
      observed_through: new Date(8 * 900000).toISOString(),
    },
  };
  assert.deepEqual(observed(s, bars(10)), { count: 8, hi: 109, lo: 99 });
  assert.deepEqual(observed(s, bars(7)), { count: 8, hi: null, lo: null });
});

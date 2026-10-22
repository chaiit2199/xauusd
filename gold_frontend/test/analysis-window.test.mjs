import assert from "node:assert/strict";
import { test } from "node:test";
import { expireAnalysis } from "../lib/analysis-window.ts";

const board = {
  ai_next_analysis_at: "2026-10-21T13:15:00Z",
  ai_action: "sell", ai_insight: "old analysis", ai_error: null,
  cfd_plan: { action: "sell", entry: 4100 },
};

test("valid analysis stays visible until the quarter-hour boundary", () => {
  assert.equal(expireAnalysis(board, Date.parse("2026-10-21T13:14:59Z")), board);
});

test("the browser clears an expired signal even without a successful refresh", () => {
  const result = expireAnalysis(board, Date.parse(board.ai_next_analysis_at));
  assert.equal(result.cfd_plan.action, "wait");
  assert.equal(result.cfd_plan.entry, 4100);
  assert.equal(result.ai_action, null);
  assert.equal(result.ai_insight, null);
  assert.ok(result.ai_error);
  assert.equal(board.cfd_plan.action, "sell");
});

test("malformed expiry does not keep an actionable signal", () => {
  assert.equal(expireAnalysis({ ...board, ai_next_analysis_at: "invalid" }, Date.now()).cfd_plan.action, "wait");
});

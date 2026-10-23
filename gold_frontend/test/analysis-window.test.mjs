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

test("stale quotes suspend the signal before the M15 boundary", () => {
  const current = { ...board, signal_valid_until: "2026-10-21T13:02:01Z",
    cfd_plan: { ...board.cfd_plan, setup_status: "signal_ready", execution_ready: false } };
  assert.equal(expireAnalysis(current, Date.parse("2026-10-21T13:02:00Z")), current);
  const stale = expireAnalysis(current, Date.parse("2026-10-21T13:02:01Z"));
  assert.equal(stale.cfd_plan.action, "wait");
  assert.equal(stale.cfd_plan.setup_status, "paused");
  assert.match(stale.ai_error, /Báo giá/);
});

test("refresh expiry cannot turn an invalidated setup into an active one", () => {
  const invalidated = { ...board, cfd_plan: { ...board.cfd_plan, setup_status: "invalidated" } };
  assert.equal(expireAnalysis(invalidated, Date.parse(board.ai_next_analysis_at)).cfd_plan.setup_status, "invalidated");
});

test("setup lifetime expires even when analysis metadata still says fresh", () => {
  const current = { ...board, cfd_plan: { ...board.cfd_plan, setup_status: "signal_ready", setup_expires_at: "2026-10-21T13:10:00Z" } };
  const expired = expireAnalysis(current, Date.parse("2026-10-21T13:10:00Z"));
  assert.equal(expired.cfd_plan.action, "wait");
  assert.equal(expired.cfd_plan.setup_status, "expired");
});

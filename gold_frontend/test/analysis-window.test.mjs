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

test("quote expiry preserves the reference plan but clears live RR and price checks", () => {
  const current = { ...board, signal_valid_until: "2026-10-21T13:02:01Z",
    cfd_plan: { ...board.cfd_plan, setup_status: "signal_ready", planning_action: "sell", reference_entry: 4000,
      current_entry_status: "eligible", decision_plan: { reference_entry: 4000, reference_reward_risk: 1.78,
        current_entry: 3999, reward_risk: 1.4, current_quote_at: "2026-10-21T13:00:00Z" },
      checks: [{ code: "quote", status: "pass", required: false }, { code: "trigger", status: "pass", required: true },
        { code: "entry_drift", status: "pass", required: false }, { code: "market_open", status: "pass", required: true }]
    } };
  const result = expireAnalysis(current, Date.parse(current.signal_valid_until)).cfd_plan;
  assert.equal(result.action, "wait");
  assert.equal(result.planning_action, "sell");
  assert.equal(result.setup_status, "awaiting_quote");
  assert.equal(result.current_entry_status, "unchecked");
  assert.equal(result.entry_guard.blocked, true);
  assert.equal(result.decision_plan.reference_reward_risk, 1.78);
  assert.equal(result.decision_plan.reward_risk, null);
  assert.equal(result.decision_plan.current_entry, null);
  const checks = Object.fromEntries(result.checks.map(c => [c.code, c.status]));
  assert.deepEqual(checks, { quote: "warning", trigger: "pass", entry_drift: "unknown", market_open: "pass" });
  const nextCandle = expireAnalysis(current, Date.parse(current.ai_next_analysis_at)).cfd_plan;
  assert.equal(nextCandle.setup_status, "paused");
  assert.equal(nextCandle.checks.find(c => c.code === "trigger").status, "unknown");
});

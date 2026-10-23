import assert from "node:assert/strict";
import { test } from "node:test";
import { checkCounts, checkState } from "../lib/rule-checks.ts";
import { expireAnalysis } from "../lib/analysis-window.ts";

test("advisory states never inflate blocked or waiting counts", () => {
  assert.deepEqual(checkCounts([
    { code: "bias", status: "unknown", required: false },
    { code: "session", status: "warning", required: false },
    { code: "quote", status: "blocked", required: true },
    { code: "trigger", status: "unknown", required: true },
    { code: "data", status: "pass", required: true },
  ]), { pass: 1, blocked: 1, unknown: 1, warning: 2 });
  // Old APIs without metadata must not have hard blocks silently downgraded.
  assert.equal(checkState({ code: "session", status: "blocked" }), "blocked");
});

test("expiry cannot leave green checks for a stale quote or calendar", () => {
  const board = {
    ai_next_analysis_at: "2026-10-23T08:15:00Z",
    signal_valid_until: "2026-10-23T08:12:00Z",
    calendar_valid_until: "2026-10-23T08:10:00Z",
    cfd_plan: { action: "buy", checks: [
      { code: "quote", status: "pass", required: true },
      { code: "calendar_data", status: "pass", required: true },
      { code: "calendar_window", status: "pass", required: true },
      { code: "reward_risk", status: "pass", required: true },
      { code: "session", status: "warning", required: false },
    ] },
  };
  const paused = expireAnalysis(board, Date.parse(board.calendar_valid_until));
  assert.equal(paused.cfd_plan.action, "wait");
  const checks = Object.fromEntries(paused.cfd_plan.checks.map(c => [c.code, c.status]));
  assert.equal(checks.calendar_data, "blocked");
  assert.equal(checks.calendar_window, "unknown");
  assert.equal(checks.reward_risk, "unknown");
  assert.equal(checks.session, "warning");
  assert.match(paused.ai_error, /Lịch tin/);
  const stale = expireAnalysis({ ...board, calendar_valid_until: null }, Date.parse(board.signal_valid_until));
  assert.equal(stale.cfd_plan.checks.find(c => c.code === "quote").status, "warning");
  assert.equal(board.cfd_plan.checks[0].status, "pass");
});

test("unverified advisory entry drift stays waiting instead of becoming a recommendation", () => {
  assert.equal(checkState({ code: "entry_drift", status: "unknown", required: false, scope: "current_entry" }), "unknown");
});

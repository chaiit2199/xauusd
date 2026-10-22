import assert from "node:assert/strict";
import { test } from "node:test";
import { positionSize } from "../lib/position-size.ts";

const input = {
  side: "buy", capital: 10000, riskPercent: 1, entry: 2500, stop: 2490,
  contractSize: 100, leverage: 20, lotStep: 0.01, minLot: 0.01,
};

test("USD gold contract computes position, SL risk and required margin", () => {
  assert.deepEqual(positionSize(input), {
    lots: 0.1, riskBudget: 100, risk: 100, notional: 25000, margin: 1250,
  });
  assert.deepEqual(positionSize({ ...input, side: "sell", stop: 2510 }), positionSize(input));
});

test("lot rounding stays within risk budget", () => {
  const result = positionSize({ ...input, stop: 2487 });
  assert.equal(result.lots, 0.07);
  assert.ok(Math.abs(result.risk - 91) < 1e-9);
  assert.ok(result.risk <= result.riskBudget);
});

test("leverage changes margin, not risk or position size", () => {
  const result = positionSize({ ...input, leverage: 100 });
  assert.equal(result.margin, 250);
  assert.equal(result.lots, 0.1);
  assert.equal(result.risk, 100);
});

test("broker contract size changes lot count but preserves exposure", () => {
  const result = positionSize({ ...input, contractSize: 10 });
  assert.equal(result.lots, 1);
  assert.equal(result.risk, 100);
  assert.equal(result.margin, 1250);
});

test("rejects SL on the wrong side or equal to entry", () => {
  for (const changes of [{ stop: 2500 }, { stop: 2510 }, { side: "sell", stop: 2490 }]) {
    assert.ok(positionSize({ ...input, ...changes }).error);
  }
});

test("does not increase lots to meet the broker minimum", () => {
  assert.ok(positionSize({ ...input, capital: 100 }).error);
  assert.ok(positionSize({ ...input, minLot: 1 }).error);
});

test("rejects missing, negative, non-finite and out-of-range inputs", () => {
  for (const changes of [
    { capital: 0 }, { capital: -100 }, { entry: NaN }, { leverage: Infinity },
    { leverage: 0.5 }, { riskPercent: 101 }, { contractSize: 0 },
    { lotStep: 0 }, { minLot: -1 }, { stop: 0 },
  ]) assert.ok(positionSize({ ...input, ...changes }).error);
});

test("never exceeds budget over a range of prices and lot steps", () => {
  for (const lotStep of [0.001, 0.01, 0.1]) {
    for (let distance = 1; distance <= 100; distance += 0.25) {
      const result = positionSize({ ...input, stop: input.entry - distance, lotStep });
      if (!result.error) assert.ok(result.risk <= result.riskBudget);
    }
  }
});

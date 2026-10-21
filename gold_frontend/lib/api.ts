import type { AnalyzeData, CrawlResponse, MarketBoard } from "./types";
import { apiBase } from "./format";

type ErrorBody = {
  message?: string;
  errors?: { detail?: string };
};

async function readBody<T>(
  response: Response,
): Promise<ErrorBody & Partial<CrawlResponse> & { data?: T }> {
  const text = await response.text();
  if (!text) return {};

  try {
    return JSON.parse(text) as ErrorBody & Partial<CrawlResponse> & { data?: T };
  } catch {
    return { message: text.slice(0, 240) };
  }
}

function networkError(error: unknown): Error {
  if (error instanceof TypeError) {
    const target = apiBase || "(same origin /api)";
    return new Error(`Không kết nối được máy chủ dữ liệu tại ${target}.`);
  }

  return error instanceof Error ? error : new Error("Yêu cầu thất bại.");
}

export async function crawlNews(): Promise<CrawlResponse> {
  try {
    const response = await fetch(`${apiBase}/api/trading/crawl-news`, {
      method: "POST",
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    const body = await readBody(response);

    if (!body.sources) {
      throw new Error(body.message || body.errors?.detail || `HTTP ${response.status}`);
    }

    return body as CrawlResponse;
  } catch (error) {
    throw networkError(error);
  }
}

export async function fetchOverview(): Promise<MarketBoard> {
  try {
    const response = await fetch(`${apiBase}/api/trading/overview`, {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    const body = await readBody<MarketBoard>(response);

    if (!response.ok || !body.data) {
      throw new Error(body.message || body.errors?.detail || `HTTP ${response.status}`);
    }

    return body.data;
  } catch (error) {
    throw networkError(error);
  }
}

export async function analyzeMarket(): Promise<AnalyzeData> {
  try {
    const response = await fetch(`${apiBase}/api/trading/analyze`, {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    const body = await readBody<AnalyzeData>(response);

    if (!response.ok || !body.data) {
      throw new Error(body.message || body.errors?.detail || `HTTP ${response.status}`);
    }

    return body.data;
  } catch (error) {
    throw networkError(error);
  }
}

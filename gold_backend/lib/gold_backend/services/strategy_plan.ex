defmodule GoldBackend.Services.StrategyPlan do
  @moduledoc "Deterministic trade decision and complete check matrix. No AI input controls this decision."
  def build(i, entry, opts) do
    bias = Keyword.fetch!(opts, :bias)
    setup = Keyword.fetch!(opts, :m15_setup)
    now = Keyword.fetch!(opts, :as_of)
    quote = Keyword.get(opts, :quote)
    ready = not setup.blocked and setup.action in ["buy", "sell"]
    stop = if ready, do: setup.stop_loss, else: entry
    target = if ready, do: setup.take_profit, else: entry
    risk = abs(entry - stop)
    reward = if setup.action == "buy", do: target - entry, else: entry - target
    # Provider currently supplies a reference price, not executable bid/ask.
    # Explicit spread option must be an observed, same-instrument spread supplied by an adapter.
    observed = Keyword.get(opts, :spread)
    observed? = is_number(observed) and observed >= 0
    spread = if observed?, do: observed, else: 0.4
    rr = if ready and risk > 0, do: (reward - spread) / (risk + spread), else: 0.0
    local = DateTime.add(now, 7 * 3600)

    session =
      local.hour >= 14 and local.hour < 22 and Date.day_of_week(DateTime.to_date(local)) <= 5

    event = Keyword.get(opts, :blocking_event)

    quote_ok =
      case quote do
        %{timestamp: %DateTime{} = at, price: p} when is_number(p) ->
          DateTime.diff(now, at) in -5..120

        _ ->
          false
      end

    levels_ok =
      ready and stop > 0 and target > 0 and risk > 0 and risk <= 5 * setup.atr and
        if setup.action == "buy",
          do: stop < entry and entry < target,
          else: target < entry and entry < stop

    checks = [
      check(
        "data",
        not Keyword.get(opts, :warmup, false),
        Keyword.get(opts, :warmup_detail) || "Dữ liệu OHLC đã sẵn sàng."
      ),
      check("bias", bias.side != "neutral", bias.reason),
      check(
        "m15_data",
        setup.state != "data_unavailable",
        "Cần OHLC M15 đã đóng, liên tục và đủ mới."
      ),
      check(
        "zoi",
        if(setup.state in ["data_unavailable", "idle"], do: nil, else: setup.state != "wait_zoi"),
        "Nến M15 phải chạm vùng ZOI đã có trước nến xác nhận."
      ),
      check(
        "trigger",
        if(setup.state in ["data_unavailable", "idle", "wait_zoi"], do: nil, else: ready),
        setup.reason
      ),
      check(
        "direction",
        if(ready, do: setup.action == bias.side, else: nil),
        "Xác nhận M15 phải cùng hướng H1."
      ),
      check(
        "calendar_data",
        Keyword.get(opts, :calendar_status) == "ok",
        "Lịch tin phải tải thành công trước khi phát phiếu."
      ),
      check(
        "calendar_window",
        if(Keyword.get(opts, :calendar_status) == "ok", do: is_nil(event), else: nil),
        if(event,
          do: "Khóa tin #{event.title}: 15 phút trước / 30 phút sau.",
          else: "Ngoài cửa sổ tin đỏ."
        )
      ),
      check("session", session, "Khung phát phiếu: 14:00–22:00 giờ Việt Nam, thứ Hai–thứ Sáu."),
      check("quote", quote_ok, "Cần báo giá mới trong 120 giây."),
      check(
        "entry_drift",
        if(ready, do: abs(entry - setup.entry) <= min(0.25 * setup.atr, 1.0), else: nil),
        "Giá vào phải cách điểm xác nhận tối đa min(0,25 ATR M15; 1 USD)."
      ),
      check(
        "levels",
        if(ready, do: levels_ok, else: nil),
        "Entry phải nằm giữa SL/TP; SL không vượt 5 ATR M15."
      ),
      check(
        "reward_risk",
        if(ready, do: rr >= 1.5, else: nil),
        "R:R sau spread phải đạt ít nhất 1,5."
      )
    ]

    reasons = checks |> Enum.reject(&(&1.status == "pass")) |> Enum.map(& &1.reason)
    action = if reasons == [], do: setup.action, else: "wait"

    warnings =
      []
      |> warn(
        not observed?,
        "Spread 0,40 USD là giả định; nguồn hiện tại chưa cung cấp bid/ask của sàn."
      )
      |> warn(ready and spread > risk * 0.2, "Spread vượt 20% khoảng SL; chi phí ăn mòn R:R.")
      |> warn(
        Keyword.get(opts, :news_bias, %{}) |> Map.get(:high_impact, false),
        "Có headline tác động mạnh; kiểm tra nguồn và điều kiện khớp lệnh."
      )

    label =
      case bias.side do
        "buy" -> "Nghiêng BUY"
        "sell" -> "Nghiêng SELL"
        _ -> "Trung lập"
      end

    %{
      instrument: "XAUUSD",
      market: "CFD",
      timeframe: "M15",
      trend_timeframe: "H1",
      strategy_version: "zoi-v1",
      bias: bias,
      lean: bias.side,
      lean_label: label,
      setup: setup.state,
      setup_label: setup.reason,
      m15_setup: setup,
      action: action,
      action_label: action_label(action),
      market_state: label,
      entry: entry,
      stop_loss: stop,
      take_profit: target,
      stop_distance: round2(risk),
      take_distance: round2(max(reward, 0)),
      stop_points: round(risk * 100),
      take_points: round(max(reward, 0) * 100),
      point_size: 0.01,
      spread: spread,
      spread_source: if(not observed?, do: "assumed", else: "observed"),
      reward_risk: if(risk > 0, do: round2(reward / risk), else: 0.0),
      reward_risk_after_spread: round2(rr),
      risk_score: if(action == "wait", do: 7, else: 5),
      risk_label: "Cần kiểm chứng",
      block_reason: List.first(reasons),
      blocking_reasons: reasons,
      checks: checks,
      soft_flags: warnings,
      entry_guard: %{blocked: reasons != [], reasons: reasons},
      summary: "#{label} · #{setup.reason}",
      notes: warnings,
      watchlist: [],
      session_key: "#{Date.to_iso8601(DateTime.to_date(local))}:14-22_VN",
      news_digest: Keyword.get(opts, :news_bias, %{}) |> Map.get(:digest),
      news_tone: Keyword.get(opts, :news_bias, %{}) |> Map.get(:tone_label),
      rule_commentary:
        "H1: #{label}. Giá đóng #{i.current_price}; SMA20 #{i.sma_20}; MACD #{i.macd}; RSI #{i.rsi_14}.\n#{bias.reason}\nM15: #{setup.reason}\n#{if reasons == [], do: "Rule đã đủ điều kiện phát phiếu.", else: "Chưa mở lệnh: " <> Enum.join(reasons, " ")}"
    }
  end

  defp check(code, value, reason),
    do: %{
      code: code,
      status:
        case value do
          true -> "pass"
          false -> "blocked"
          nil -> "unknown"
        end,
      reason: reason
    }

  defp warn(xs, true, message), do: xs ++ [message]
  defp warn(xs, _, _), do: xs
  defp round2(n), do: Float.round(n * 1.0, 2)
  defp action_label("buy"), do: "Mua"
  defp action_label("sell"), do: "Bán"
  defp action_label(_), do: "Đứng ngoài"
end

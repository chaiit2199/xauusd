defmodule GoldBackend.Services.StrategyPlan do
  @moduledoc "Deterministic trade decision and complete check matrix. No AI input controls this decision."
  alias GoldBackend.Services.{EntryQuality, StrategyPolicy}

  def build(i, entry, opts) do
    bias = Keyword.fetch!(opts, :bias)
    setup = Keyword.fetch!(opts, :m15_setup)
    now = Keyword.fetch!(opts, :as_of)
    quote = Keyword.get(opts, :quote)
    ready = not setup.blocked and setup.action in ["buy", "sell"]
    stop = setup.stop_loss || entry
    target = setup.take_profit || entry
    risk = abs(entry - stop)
    reward = if setup.action == "buy", do: target - entry, else: entry - target
    # Provider currently supplies a reference price, not executable bid/ask.
    # Explicit spread option must be an observed, same-instrument spread supplied by an adapter.
    observed = Keyword.get(opts, :spread)
    observed? = is_number(observed) and observed >= 0
    spread = if observed?, do: observed, else: StrategyPolicy.assumed_spread()

    quality =
      if ready and is_number(setup.take_profit),
        do: EntryQuality.assess(setup, entry, spread),
        else: nil

    rr = if quality, do: quality.reward_risk, else: 0.0
    local = DateTime.add(now, 7 * 3600)

    session =
      local.hour >= 14 and local.hour < 22 and Date.day_of_week(DateTime.to_date(local)) <= 5

    event = Keyword.get(opts, :blocking_event)

    quote_ok = EntryQuality.fresh_quote?(quote, now)

    lifetime_ok =
      case Map.get(setup, :expires_at) do
        nil ->
          nil

        value ->
          case DateTime.from_iso8601(value) do
            {:ok, expiry, _} -> DateTime.compare(now, expiry) == :lt
            _ -> false
          end
      end

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
        "target_structure",
        if(ready, do: is_number(setup.take_profit), else: nil),
        "Cần vùng hỗ trợ/kháng cự đã xác nhận để xác định TP; không tự đặt mục tiêu 2R."
      ),
      check(
        "setup_lifetime",
        lifetime_ok,
        "Setup có hiệu lực tối đa hai nến M15 từ lần xác nhận."
      ),
      check(
        "setup_target",
        if(quality, do: not quality.target_reached, else: nil),
        "Giá chưa chạm mục tiêu của setup trước khi phát tín hiệu."
      ),
      check(
        "structure",
        if(quality, do: quality.structure_ok, else: nil),
        "Cấu trúc và vùng giá của setup phải còn hiệu lực."
      ),
      check(
        "calendar_data",
        if(Keyword.get(opts, :calendar_status) == "ok", do: true, else: nil),
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
        if(quality, do: quality.drift_ok, else: nil),
        "Giá chỉ được lệch bất lợi tối đa 0,30 ATR M15 tại lúc xác nhận; chờ hồi nếu vượt ngưỡng."
      ),
      check(
        "levels",
        if(quality, do: quality.levels_ok, else: nil),
        "Entry phải nằm giữa SL/TP; SL không vượt 5 ATR M15."
      ),
      check(
        "barrier_room",
        if(quality, do: barrier_room?(setup, entry, spread), else: nil),
        "Khoảng trống tới vùng cản đã xác nhận phải đủ R:R 1,5 sau chi phí ước tính."
      ),
      check(
        "reward_risk",
        if(quality, do: quality.reward_risk_ok, else: nil),
        "R:R sau spread phải đạt ít nhất 1,5."
      )
    ]

    reasons = checks |> Enum.reject(&(&1.status == "pass")) |> Enum.map(& &1.reason)
    action = if reasons == [], do: setup.action, else: "wait"

    state =
      cond do
        setup.state in ["expired", "invalidated"] ->
          setup.state

        lifetime_ok == false ->
          "expired"

        not quote_ok or Keyword.get(opts, :warmup, false) or
            Keyword.get(opts, :calendar_status) != "ok" ->
          "paused"

        quality && (not quality.structure_ok or quality.target_reached) ->
          "invalidated"

        event ->
          "news_window"

        action != "wait" ->
          "signal_ready"

        ready and not is_number(setup.take_profit) ->
          "wait_target"

        quality &&
            (not quality.drift_ok or not quality.reward_risk_ok or
               not barrier_room?(setup, entry, spread)) ->
          "wait_pullback"

        setup.state == "wait_m15" ->
          "wait_confirmation"

        true ->
          "watching"
      end

    warnings =
      []
      |> warn(
        not observed?,
        "Spread 0,40 USD là giả định; nguồn hiện tại chưa cung cấp bid/ask của sàn."
      )
      |> warn(
        observed? and ready and spread > risk * 0.1,
        "Spread vượt 10% khoảng SL; cần kiểm tra chi phí thực thi."
      )
      |> warn(
        bias.side == "buy" and i.rsi_14 > 65,
        "RSI cao: lưu ý mua đuổi; chỉ báo này không tự chặn setup theo xu hướng."
      )
      |> warn(
        bias.side == "sell" and i.rsi_14 < 35,
        "RSI thấp: lưu ý bán đuổi; chỉ báo này không tự chặn setup theo xu hướng."
      )
      |> warn(
        bias.side == "buy" and Map.get(i, :stochastic_k, 50) > 75,
        "Stochastic cao: kiểm tra khoảng cách entry và cấu trúc trước khi mua."
      )
      |> warn(
        bias.side == "sell" and Map.get(i, :stochastic_k, 50) < 30,
        "Stochastic thấp: kiểm tra khoảng cách entry và cấu trúc trước khi bán."
      )

    label =
      case bias.side do
        "buy" -> "Ưu tiên BUY"
        "sell" -> "Ưu tiên SELL"
        _ -> "Trung lập"
      end

    plan = %{
      instrument: "XAUUSD",
      market: "CFD",
      timeframe: "M15",
      trend_timeframe: "H1",
      strategy_version: StrategyPolicy.version(),
      mode: "signals_only",
      setup_id: Map.get(setup, :id),
      setup_status: state,
      setup_formed_at: Map.get(setup, :formed_at),
      setup_expires_at: Map.get(setup, :expires_at),
      reference_entry: setup.entry,
      reference_atr: setup.atr,
      entry_adverse: if(quality, do: round2(quality.adverse), else: nil),
      entry_limit: if(quality, do: round2(quality.limit), else: nil),
      barrier: Map.get(setup, :barrier),
      execution_status: "not_tracked",
      execution_ready: false,
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
      spread_stop_ratio: if(observed? and risk > 0, do: round2(spread / risk), else: nil),
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

    Map.put(plan, :decision_plan, GoldBackend.Services.DecisionPlan.build(plan, setup, i))
  end

  defp barrier_room?(setup, entry, cost) do
    case Map.get(setup, :barrier) do
      nil ->
        true

      zone ->
        reward = if setup.action == "buy", do: zone.low - entry, else: entry - zone.high
        risk = abs(entry - setup.stop_loss)
        risk > 0 and (reward - cost) / (risk + cost) + 1.0e-9 >= StrategyPolicy.min_reward_risk()
    end
  end

  # Repeat all gates at the final quote; never move the setup's original reference or SL/TP.
  def revalidate(context, quote, now) do
    entry = if quote, do: quote.price, else: context.plan.entry

    plan =
      build(context.indicators, entry,
        bias: context.plan.bias,
        m15_setup: context.m15_setup,
        as_of: now,
        quote: quote,
        calendar_status: Map.get(context, :calendar_status, "unavailable"),
        blocking_event: GoldBackend.Services.EconomicCalendar.blocking(context.events, now),
        warmup: context.warmup,
        warmup_detail: context.warmup_detail,
        news_bias: context.news_bias
      )

    %{
      context
      | plan: plan,
        analysis_at: now,
        latest:
          if(quote,
            do: %{
              context.latest
              | price: Decimal.from_float(quote.price * 1.0),
                timestamp: quote.timestamp
            },
            else: context.latest
          )
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

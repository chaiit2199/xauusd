defmodule GoldBackend.Services.StrategyPlan do
  @moduledoc "Deterministic structure decision and check matrix. Indicators are advisory; AI gates Telegram separately."
  alias GoldBackend.Services.{EntryQuality, StrategyPolicy}

  def build(i, entry, opts) do
    bias = Keyword.fetch!(opts, :bias)
    setup = Keyword.fetch!(opts, :m15_setup)
    now = Keyword.fetch!(opts, :as_of)
    quote = Keyword.get(opts, :quote)
    quote_ok = EntryQuality.fresh_quote?(quote, now)
    # A candle close remains useful for planning, never as proof of a live entry.
    entry = if quote_ok, do: quote.price, else: setup.entry || entry
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
      if quote_ok and ready and is_number(setup.take_profit),
        do: EntryQuality.assess(setup, entry, spread),
        else: nil

    rr = if quality, do: quality.reward_risk, else: 0.0
    local = DateTime.add(now, 7 * 3600)

    session =
      local.hour >= 14 and local.hour < 22 and Date.day_of_week(DateTime.to_date(local)) <= 5

    event = Keyword.get(opts, :blocking_event)

    calendar_ok =
      Keyword.get(opts, :calendar_status) == "ok" and
        calendar_current?(Keyword.get(opts, :calendar_valid_until), now)

    h1_ready = StrategyPolicy.h1_ready?(bias)
    neutral_breakout = StrategyPolicy.neutral_breakout?(setup, bias)
    active_side = if ready, do: setup.action, else: bias.side

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

    eligible_zone = if ready, do: GoldBackend.Services.DecisionPlan.entry_zone(setup, spread)

    checks = [
      check(
        "data",
        not Keyword.get(opts, :warmup, false),
        Keyword.get(opts, :warmup_detail) ||
          if(h1_ready,
            do: "Dữ liệu OHLC đã sẵn sàng.",
            else: "Chưa đủ H1 hợp lệ; không coi thiếu dữ liệu là H1 trung tính."
          )
      ),
      check("bias", bias.side != "neutral", bias.reason, false, "advisory"),
      check(
        "bias_regime",
        if(h1_ready, do: Map.get(bias, :regime) != "transition", else: nil),
        "H1 đang chuyển hướng; đây là cảnh báo bối cảnh.",
        false,
        "advisory"
      ),
      check(
        "m15_data",
        setup.state != "data_unavailable",
        "Cần OHLC M15 đã đóng, liên tục và đủ mới."
      ),
      check(
        "zoi",
        if(setup.state in ["data_unavailable", "idle"], do: nil, else: setup.state != "wait_zoi"),
        "Lệnh hồi cần chạm ZOI; breakout cần chạm vùng retest hình thành sau phá vỡ, trước nến xác nhận.",
        true,
        "setup"
      ),
      check(
        "trigger",
        if(setup.state in ["data_unavailable", "idle", "wait_zoi"], do: nil, else: ready),
        setup.reason
      ),
      check(
        "direction",
        if(ready and h1_ready,
          do: StrategyPolicy.direction_aligned?(setup, bias),
          else: nil
        ),
        cond do
          neutral_breakout ->
            "Breakout–retest khi H1 trung tính: đồng hướng H1 không bắt buộc."

          ready and h1_ready and StrategyPolicy.direction_aligned?(setup, bias) ->
            "Setup đồng hướng H1; chỉ báo H1 là ưu tiên, không chặn cấu trúc."

          ready and h1_ready ->
            "Setup ngược H1: chỉ báo không chặn; AI sẽ nhận bias/chỉ báo kèm tin để nhận định."

          true ->
            "Đồng hướng H1 là khuyến nghị; chỉ báo không còn điều kiện bắt buộc phát phiếu."
        end,
        false,
        "advisory"
      ),
      check(
        "target_structure",
        if(ready, do: is_number(setup.take_profit), else: nil),
        "Cần mục tiêu từ cấu trúc H1/ngày trước hoặc swing M15 đã xác nhận; không tự tạo TP để đủ R:R."
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
        if(Map.get(setup, :setup_kind) == "breakout_retest",
          do:
            "Retest: giá chưa chạm SL; nến đóng chưa vượt điểm vô hiệu đã lưu. Râu xuyên vùng không tự hủy setup.",
          else: "Lệnh hồi: giá còn trong giới hạn cấu trúc và chưa chạm SL."
        ),
        true,
        "setup"
      ),
      check(
        "calendar_data",
        if(calendar_ok, do: true, else: nil),
        if(calendar_ok,
          do: "Lịch tin đã xác minh; bản tải mới hoặc cache còn hiệu lực.",
          else: "Chưa xác minh lịch tin; chờ bản tải mới hoặc cache còn hiệu lực và đủ phạm vi."
        )
      ),
      check(
        "calendar_window",
        if(calendar_ok, do: is_nil(event), else: nil),
        cond do
          not calendar_ok ->
            "Chưa xác minh lịch tin nên chưa xác định được cửa sổ tin."

          event ->
            "Khóa tin #{event.title}: 15 phút trước / 30 phút sau."

          true ->
            "Ngoài cửa sổ tin đỏ."
        end
      ),
      check(
        "session",
        session,
        if(session,
          do: "Trong khung giờ ưu tiên 14:00–22:00, thứ Hai–thứ Sáu.",
          else:
            "Ngoài khung giờ ưu tiên 14:00–22:00; vẫn xét tín hiệu nếu các điều kiện bắt buộc đạt."
        ),
        false,
        "advisory"
      ),
      check(
        "market_open",
        GoldBackend.Services.MarketSchedule.open?(now),
        "Thị trường nằm ngoài thời gian nghỉ đã cấu hình."
      ),
      check(
        "quote",
        quote_ok,
        if(quote_ok,
          do: "Báo giá hợp lệ trong 120 giây.",
          else:
            "Chưa có báo giá đủ mới để kiểm tra entry hiện tại. Kế hoạch dùng nến đã đóng; cần đối chiếu giá trước khi sử dụng."
        ),
        false,
        "advisory"
      ),
      check(
        "current_entry",
        if(quote_ok, do: true, else: nil),
        if(quote_ok,
          do:
            "Có báo giá mới để kiểm tra entry hiện tại; các điều kiện giá bên dưới vẫn phải đạt.",
          else: "Chưa kiểm tra entry hiện tại; cần báo giá hợp lệ trong 120 giây."
        ),
        true,
        "current_entry"
      ),
      check(
        "entry_drift",
        if(quality, do: quality.drift_ok, else: nil),
        cond do
          is_nil(quality) ->
            "Chờ setup và TP để đánh giá độ lệch entry."

          quality.drift_ok ->
            "Entry trong ngưỡng tham chiếu 0,30 ATR lúc xác nhận."

          true ->
            "Entry muộn: lệch bất lợi quá 0,30 ATR. Chỉ phát tín hiệu nếu cấu trúc, SL/TP và R:R tại giá mới vẫn đạt."
        end,
        false,
        "advisory"
      ),
      check(
        "levels",
        if(quality, do: quality.levels_ok, else: nil),
        "Entry phải nằm giữa SL/TP; SL không vượt 5 USD/oz."
      ),
      check(
        "entry_zone",
        if(quality,
          do: eligible_zone != nil and entry >= eligible_zone.low and entry <= eligible_zone.high,
          else: nil
        ),
        "Chờ giá quay lại vùng entry phù hợp."
      ),
      check(
        "reward_risk",
        if(quality,
          do:
            quality.reward_risk_ok and quality.reward >= 5.0 - 1.0e-9 and
              barrier_room?(setup, entry, spread),
          else: nil
        ),
        "R:R thấp cần chờ retest; ước tính sau chi phí."
      )
    ]

    # Quote-dependent checks are unknown, including advisory drift. Do not mark
    # reference-price arithmetic as a passed check of the current market.
    checks =
      if quote_ok,
        do: checks,
        else:
          Enum.map(checks, fn c ->
            if c.code in [
                 "setup_target",
                 "structure",
                 "entry_drift",
                 "levels",
                 "reward_risk",
                 "entry_zone"
               ] do
              Map.merge(c, %{
                status: "unknown",
                scope: "current_entry",
                reason:
                  "Chưa xác minh tại giá hiện tại; cần báo giá mới và kiểm tra lại hiệu lực setup."
              })
            else
              c
            end
          end)

    reasons =
      checks |> Enum.filter(&(&1.required and &1.status != "pass")) |> Enum.map(& &1.reason)

    action = if reasons == [], do: setup.action, else: "wait"

    state =
      cond do
        setup.state in ["expired", "invalidated"] ->
          setup.state

        lifetime_ok == false ->
          "expired"

        Keyword.get(opts, :warmup, false) or setup.state == "data_unavailable" or
            not calendar_ok ->
          "paused"

        quality && (not quality.structure_ok or quality.target_reached) ->
          "invalidated"

        event ->
          "news_window"

        action != "wait" ->
          "signal_ready"

        ready and not is_number(setup.take_profit) ->
          "wait_target"

        ready and not quote_ok ->
          "awaiting_quote"

        quality &&
            (is_nil(eligible_zone) or entry < eligible_zone.low or entry > eligible_zone.high or
               not quality.levels_ok or not quality.reward_risk_ok or
               quality.reward < 5.0 - 1.0e-9 or
               not barrier_room?(setup, entry, spread)) ->
          "wait_pullback"

        setup.state == "wait_m15" ->
          "wait_confirmation"

        true ->
          "watching"
      end

    planning_action =
      if ready and lifetime_ok == true and state not in ["invalidated", "expired"] and
           not Keyword.get(opts, :warmup, false),
         do: setup.action,
         else: "wait"

    current_entry_status =
      cond do
        state in ["invalidated", "expired"] -> "blocked"
        not quote_ok or is_nil(quality) -> "unchecked"
        action in ["buy", "sell"] -> "eligible"
        true -> "blocked"
      end

    entry_status =
      cond do
        state == "expired" ->
          "EXPIRED"

        state == "invalidated" ->
          "INVALIDATED"

        event && ready ->
          "NEWS_BLOCKED"

        ready && !quote_ok ->
          "WAIT_LIVE_QUOTE"

        action in ["buy", "sell"] ->
          "READY_TO_ENTER"

        ready && quality &&
            (is_nil(eligible_zone) || entry < eligible_zone.low || entry > eligible_zone.high ||
               !quality.reward_risk_ok || !quality.levels_ok || quality.reward < 5.0 - 1.0e-9) ->
          "WAIT_RETEST"

        ready && quality && !quality.drift_ok ->
          "PLAN_VALID_BUT_PRICE_MOVED"

        ready ->
          "PLAN_READY"

        true ->
          "WATCHING"
      end

    warnings =
      []
      |> warn(ready and abs(setup.entry - setup.stop_loss) > 3, "SL rộng hơn scalp target.")
      |> warn(
        quality != nil and quality.reward_risk >= 1.2 and quality.reward_risk < 1.5,
        "R:R phù hợp scalp nhưng thấp hơn 1.5."
      )
      |> warn(
        ready and bias.side in ["buy", "sell"] and bias.side != setup.action,
        "Countertrend setup — ngược bias H1, ưu tiên mục tiêu ngắn."
      )
      |> warn(quality != nil and not quality.drift_ok, "Lệch entry lớn hơn 0.30 ATR.")
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
      timeframe: if(Map.get(setup, :timeframe_seconds) == 300, do: "M5", else: "M15"),
      trend_timeframe: "H1",
      indicator_timeframe: Keyword.get(opts, :indicator_timeframe, "H1"),
      strategy_version: StrategyPolicy.version(),
      mode: "signals_only",
      planning_action: planning_action,
      trade_plan_status: entry_status,
      current_entry_status: current_entry_status,
      price_basis: if(quote_ok, do: "live_quote", else: "m15_close"),
      quote_at: if(quote_ok, do: DateTime.to_iso8601(quote.timestamp)),
      setup_id: Map.get(setup, :id),
      setup_status: state,
      setup_formed_at: Map.get(setup, :formed_at),
      setup_expires_at: Map.get(setup, :expires_at),
      reference_entry: setup.entry,
      reference_atr: setup.atr,
      entry_adverse: if(quality, do: round2(quality.adverse), else: nil),
      entry_limit: if(quality, do: round2(quality.limit), else: nil),
      entry_admission:
        if(action in ["buy", "sell"],
          do: if(quality.drift_ok, do: "reference_band", else: "late_entry"),
          else: nil
        ),
      barrier: Map.get(setup, :barrier),
      execution_status: "not_tracked",
      execution_ready: false,
      bias: bias,
      lean: active_side,
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
      reward_risk_after_spread: if(quality, do: round2(rr)),
      risk_score: if(action == "wait", do: 7, else: 5),
      risk_label: "Cần kiểm chứng",
      block_reason: List.first(reasons),
      blocking_reasons: reasons,
      checks: checks,
      soft_flags: warnings,
      entry_guard: %{blocked: reasons != [], reasons: reasons},
      summary: "#{label} · #{setup.reason}",
      setup_kind: Map.get(setup, :setup_kind),
      candidate_log: Map.get(setup, :candidate_log, []),
      notes: warnings,
      watchlist: [],
      session_key: "#{Date.to_iso8601(DateTime.to_date(local))}:all_sessions",
      news_digest: Keyword.get(opts, :news_bias, %{}) |> Map.get(:digest),
      news_tone: Keyword.get(opts, :news_bias, %{}) |> Map.get(:tone_label),
      rule_commentary:
        "H1: #{label}. Chỉ báo #{Keyword.get(opts, :indicator_timeframe, "H1")}: giá đóng #{i.current_price}; SMA20 #{i.sma_20}; MACD #{i.macd}; RSI #{i.rsi_14}.\n#{bias.reason}\nM15: #{setup.reason}\n#{if reasons == [], do: "Rule đã đủ điều kiện phát phiếu.", else: "Chưa mở lệnh: " <> Enum.join(reasons, " ")}"
    }

    structured = %{
      direction: if(ready, do: String.upcase(setup.action)),
      setup_type: Map.get(setup, :setup_kind),
      context: %{
        h1_bias: bias.side,
        m15_structure: Map.get(setup, :technical_context),
        countertrend: ready and bias.side in ["buy", "sell"] and setup.action != bias.side
      },
      entry: %{
        zone_low: if(eligible_zone, do: eligible_zone.low),
        zone_high: if(eligible_zone, do: eligible_zone.high),
        reference: if(ready, do: setup.entry),
        current_price: if(quote_ok, do: entry),
        status: entry_status
      },
      risk: %{
        stop_loss: if(ready, do: setup.stop_loss),
        stop_distance: if(ready, do: round2(abs(setup.entry - setup.stop_loss))),
        invalidation: Map.get(setup, :invalidation_price),
        tp1: Map.get(setup, :take_profit),
        tp2: Map.get(setup, :take_profit_2),
        reward_to_tp1:
          if(ready and is_number(setup.take_profit),
            do: round2(abs(setup.take_profit - setup.entry))
          ),
        reward_to_tp2:
          if(ready and is_number(Map.get(setup, :take_profit_2)),
            do: round2(abs(setup.take_profit_2 - setup.entry))
          ),
        estimated_rr: if(quality, do: round2(quality.reward_risk))
      },
      status: entry_status,
      warnings: warnings,
      reasons: [setup.reason],
      blockers: reasons
    }

    plan
    |> Map.put(:trade_plan, structured)
    |> Map.put(:decision_plan, GoldBackend.Services.DecisionPlan.build(plan, setup, i))
    |> Map.put(
      :stop_cap_audit,
      if(Keyword.get(opts, :audit_candidates, true),
        do: audit_stop_caps(i, entry, opts, setup),
        else: []
      )
    )
  end

  # Counterfactual diagnostics only: these candidates are never substituted into
  # the published plan. Unknown data must prevent the "sole blocker" label.
  defp audit_stop_caps(i, entry, opts, setup) do
    Enum.map(Map.get(setup, :rejected_candidates, []), fn candidate ->
      probe_setup = %{candidate | blocked: false, state: "ready"}

      probe =
        build(
          i,
          entry,
          opts |> Keyword.put(:m15_setup, probe_setup) |> Keyword.put(:audit_candidates, false)
        )

      q =
        if is_number(candidate.take_profit),
          do: EntryQuality.assess(candidate, entry, probe.spread)

      # Rejected candidates do not have a persisted lifecycle of their own.
      # Only label sole blockers in their confirmation slot; a later candle
      # may have crossed SL/TP even if the current quote has recovered.
      sole =
        candidate.candle_closed_at ==
          DateTime.to_iso8601(
            GoldBackend.Services.CandleClock.closed_at(Keyword.fetch!(opts, :as_of))
          ) and
          q != nil and q.risk > 5.0 and
          entry > 0 and candidate.stop_loss > 0 and candidate.take_profit > 0 and
          if(candidate.action == "buy",
            do: candidate.stop_loss < entry and entry < candidate.take_profit,
            else: candidate.take_profit < entry and entry < candidate.stop_loss
          ) and
          Enum.all?(
            probe.checks,
            &(not &1.required or &1.code in ["levels", "entry_zone", "reward_risk"] or
                &1.status == "pass")
          )

      %{
        setup_id: candidate.id,
        side: candidate.action,
        setup_kind: candidate.setup_kind,
        reference_atr: candidate.atr,
        stop_loss: candidate.stop_loss,
        take_profit: candidate.take_profit,
        entry: entry,
        sole_blocker: sole
      }
    end)
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
        indicator_timeframe: Map.get(context.plan, :indicator_timeframe, "H1"),
        m15_setup: context.m15_setup,
        as_of: now,
        quote: quote,
        calendar_status: Map.get(context, :calendar_status, "unavailable"),
        calendar_valid_until: Map.get(context, :calendar_valid_until),
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

  def expire_checks(checks, code, reason) do
    dependent =
      if code == "quote",
        do: [
          "current_entry",
          "entry_zone",
          "entry_drift",
          "levels",
          "reward_risk",
          "barrier_room",
          "structure",
          "setup_target"
        ],
        else: [
          "current_entry",
          "direction",
          "trigger",
          "entry_drift",
          "levels",
          "reward_risk",
          "barrier_room",
          "structure",
          "setup_target"
        ]

    Enum.map(checks || [], fn check ->
      cond do
        check.code == "quote" and code == "quote" ->
          Map.merge(check, %{
            status: "warning",
            reason: reason,
            required: false,
            scope: "advisory"
          })

        check.code == code ->
          Map.merge(check, %{status: "blocked", reason: reason, required: true})

        (check.code in dependent or (code == "calendar_data" and check.code == "calendar_window")) and
            (Map.get(check, :required, true) or check.code == "entry_drift") ->
          Map.merge(check, %{
            status: "unknown",
            scope: "current_entry",
            reason: "Chờ đánh giá lại với dữ liệu mới."
          })

        true ->
          check
      end
    end)
  end

  # Also used when cached/browser-visible data expires between evaluations.
  def suspend_current_entry(plan, reason) do
    status =
      if Map.get(plan, :setup_status) in ["invalidated", "expired"],
        do: "blocked",
        else: "unchecked"

    plan =
      Map.merge(plan, %{
        action: "wait",
        action_label: "Đứng ngoài",
        execution_ready: false,
        entry_guard: %{blocked: true, reasons: [reason]},
        blocking_reasons: [reason],
        current_entry_status: status,
        trade_plan_status:
          if(status == "blocked",
            do: String.upcase(plan.setup_status),
            else:
              if(String.contains?(String.downcase(reason), "báo giá"),
                do: "WAIT_LIVE_QUOTE",
                else: "PLAN_READY"
              )
          ),
        quote_at: nil,
        price_basis: "m15_close",
        entry_admission: nil,
        entry_adverse: nil,
        entry_limit: nil,
        reward_risk_after_spread: nil
      })

    plan =
      if is_number(Map.get(plan, :reference_entry)),
        do: Map.put(plan, :entry, plan.reference_entry),
        else: plan

    plan =
      case Map.get(plan, :trade_plan) do
        nil ->
          plan

        trade_plan ->
          status = plan.trade_plan_status

          Map.put(plan, :trade_plan, %{
            trade_plan
            | status: status,
              entry: %{trade_plan.entry | status: status, current_price: nil}
          })
      end

    case Map.get(plan, :decision_plan) do
      nil ->
        plan

      decision ->
        Map.put(
          plan,
          :decision_plan,
          Map.merge(decision, %{
            current_entry_status: status,
            current_entry: nil,
            current_quote_at: nil,
            reward_risk: nil,
            cost_sensitivity: nil,
            confirmation: reason,
            reward_risk_basis:
              "Chưa kiểm tra entry hiện tại; đối chiếu báo giá mới trước khi sử dụng."
          })
        )
    end
  end

  defp calendar_current?(nil, _), do: true

  defp calendar_current?(expiry, now) do
    case DateTime.from_iso8601(expiry) do
      {:ok, at, _} -> DateTime.compare(now, at) == :lt
      _ -> false
    end
  end

  defp check(code, value, reason, required \\ true, scope \\ "required") do
    status =
      cond do
        value == true -> "pass"
        not required -> "warning"
        value == false -> "blocked"
        true -> "unknown"
      end

    %{code: code, status: status, reason: reason, required: required, scope: scope}
  end

  defp warn(xs, true, message), do: xs ++ [message]
  defp warn(xs, _, _), do: xs
  defp round2(n), do: Float.round(n * 1.0, 2)
  defp action_label("buy"), do: "Mua"
  defp action_label("sell"), do: "Bán"
  defp action_label(_), do: "Đứng ngoài"
end

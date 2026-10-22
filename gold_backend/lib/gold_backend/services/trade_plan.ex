defmodule GoldBackend.Services.TradePlan do
  @moduledoc """
  H1 decision ticket for an XAUUSD CFD.

  The ticket is the only trade decision. A written commentary may explain it
  and may not flip the side. Stops are 2× the hourly ATR, targets are twice
  the stop, and a stop wider than 5× ATR is not used.
  """

  @point 0.01
  @spread 0.40

  def build(indicators, entry, opts \\ []) when is_number(entry) do
    entry = round2(entry)
    lean = lean(indicators)
    stop_usd = stop_distance(indicators)
    take_usd = round2(stop_usd * 2)
    rr_after_spread = reward_after_spread(stop_usd, take_usd)
    signal_action = action(indicators, lean)
    news_bias = Keyword.get(opts, :news_bias)
    block = block_reason(opts, rr_after_spread, signal_action)
    action = if block, do: :wait, else: signal_action
    {stop_loss, take_profit} = levels(lean, entry, stop_usd, take_usd)
    score = risk_score(indicators, action, lean, block, news_bias)

    %{
      instrument: "XAUUSD",
      market: "CFD",
      timeframe: "H1",
      action: Atom.to_string(action),
      action_label: action_label(action),
      lean: Atom.to_string(lean),
      lean_label: lean_label(lean),
      market_state: market_state(indicators, lean),
      entry: entry,
      stop_loss: stop_loss,
      take_profit: take_profit,
      stop_distance: round2(abs(stop_loss - entry)),
      take_distance: round2(abs(take_profit - entry)),
      stop_points: points(abs(stop_loss - entry)),
      take_points: points(abs(take_profit - entry)),
      point_size: @point,
      spread: @spread,
      reward_risk: if(stop_usd == 0, do: 0.0, else: Float.round(take_usd / stop_usd, 2)),
      reward_risk_after_spread: Float.round(rr_after_spread, 2),
      risk_score: score,
      risk_label: risk_label(score),
      block_reason: block,
      news_tone: news_tone(news_bias),
      news_digest: news_digest(news_bias),
      summary: summary(action, lean, risk_label(score), block, indicators),
      notes: notes(indicators, lean, stop_usd, news_bias)
    }
  end

  def commentary(plan, extras \\ %{}) do
    watch? = plan.action == "wait"
    indicators = Map.get(extras, :indicators)
    news_digest = Map.get(extras, :news_digest) || Map.get(plan, :news_digest)

    evidence =
      cond do
        is_map(indicators) ->
          "Bằng chứng H1: giá #{usd(indicators.current_price)} vs SMA20 #{usd(indicators.sma_20)}, EMA50 #{usd(indicators.ema_50)}; MACD #{indicators.macd}; RSI #{indicators.rsi_14}; ATR #{usd(indicators.atr_14)}."

        true ->
          nil
      end

    news_line =
      if is_binary(news_digest) and news_digest != "",
        do: "Tin gần đây: #{news_digest}",
        else: "Tin gần đây: chưa có tiêu đề đủ mạnh trong 3 ngày."

    """
    Giá đang xem: #{usd(plan.entry)} USD.
    Quyết định: #{plan.action_label}. #{plan.block_reason || "Tín hiệu đã cùng một hướng."}
    Giá đang #{direction_word(plan.lean)}. Trạng thái: #{plan.market_state}.
    #{evidence}
    #{news_line}

    #{if watch?, do: "Các mức dưới đây chỉ để xem, chưa phải lệnh cần vào.", else: "Mức lệnh:"}
    Cắt lỗ #{usd(plan.stop_loss)} USD, nằm #{stop_side(plan.lean)} giá #{usd(plan.stop_distance)} USD.
    Chốt lời #{usd(plan.take_profit)} USD, nằm #{take_side(plan.lean)} giá #{usd(plan.take_distance)} USD.
    Nếu đúng hướng, tiền lời khoảng #{plan.reward_risk_after_spread} lần tiền lỗ. Phí vào lệnh tạm tính #{usd(plan.spread)} USD.

    Rủi ro #{plan.risk_score} trên 10, mức #{plan.risk_label}.
    """
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp bull_score(indicators) do
    count([
      indicators.current_price > indicators.sma_20,
      indicators.current_price > indicators.ema_50,
      indicators.macd > 0,
      indicators.roc_10 > 0,
      indicators.rsi_14 >= 55
    ])
  end

  defp bear_score(indicators) do
    count([
      indicators.current_price < indicators.sma_20,
      indicators.current_price < indicators.ema_50,
      indicators.macd < 0,
      indicators.roc_10 < 0,
      indicators.rsi_14 <= 45
    ])
  end

  defp lean(indicators) do
    bull = bull_score(indicators)
    bear = bear_score(indicators)

    cond do
      bull > bear -> :buy
      bear > bull -> :sell
      indicators.macd > 0 or indicators.roc_10 > 0 -> :buy
      indicators.macd < 0 or indicators.roc_10 < 0 -> :sell
      true -> :buy
    end
  end

  defp action(indicators, lean) do
    bull = bull_score(indicators)
    bear = bear_score(indicators)

    cond do
      lean == :buy and indicators.current_price > indicators.sma_20 and indicators.macd > 0 and
        bull >= 4 and indicators.rsi_14 < 70 and indicators.stochastic_k < 85 ->
        :buy

      lean == :sell and indicators.current_price < indicators.sma_20 and indicators.macd < 0 and
        bear >= 4 and indicators.rsi_14 > 30 and indicators.stochastic_k > 15 ->
        :sell

      true ->
        :wait
    end
  end

  defp block_reason(opts, rr_after_spread, signal_action) do
    event = Keyword.get(opts, :blocking_event)
    warmup_detail = Keyword.get(opts, :warmup_detail)

    cond do
      Keyword.get(opts, :warmup, false) ->
        warmup_detail ||
          "Chưa đủ giá thị trường thật để vào lệnh. Lịch sử 5 ngày (gồm seed) chỉ để tính SMA/EMA/ATR."

      event ->
        "Sắp có tin #{event.title}. Chưa vào lệnh từ 30 phút trước đến 30 phút sau giờ ra tin."

      rr_after_spread < 1.5 ->
        "Phần lời sau phí vào lệnh chưa đủ lớn so với phần lỗ."

      signal_action == :wait ->
        "Tín hiệu chưa cùng một hướng."

      true ->
        nil
    end
  end

  defp stop_distance(indicators) do
    atr = max(indicators.atr_14, 0.5)
    round2(min(atr * 2, atr * 5))
  end

  defp reward_after_spread(stop_usd, take_usd) do
    risk = stop_usd + @spread
    reward = take_usd - @spread
    if risk <= 0, do: 0.0, else: reward / risk
  end

  defp levels(:buy, entry, stop_usd, take_usd),
    do: {round2(entry - stop_usd), round2(entry + take_usd)}

  defp levels(:sell, entry, stop_usd, take_usd),
    do: {round2(entry + stop_usd), round2(entry - take_usd)}

  defp risk_score(indicators, action, lean, block, news_bias) do
    conflict? = news_conflicts?(lean, news_bias)

    score =
      3
      |> add(2, indicators.rsi_14 >= 70 or indicators.rsi_14 <= 30)
      |> add(2, indicators.stochastic_k >= 80 or indicators.stochastic_k <= 20)
      |> add(1, abs(indicators.roc_10) >= 1.0)
      |> add(1, outside_band?(indicators))
      |> add(1, action == :wait)
      |> add(2, lean == :sell and indicators.stochastic_k <= 20)
      |> add(2, lean == :buy and indicators.stochastic_k >= 80)
      |> add(2, is_binary(block))
      |> add(1, news_bias_high_impact?(news_bias))
      |> add(1, conflict?)

    score |> max(1) |> min(10)
  end

  defp news_conflicts?(:buy, %{tone: :gold_bearish}), do: true
  defp news_conflicts?(:sell, %{tone: :gold_bullish}), do: true
  defp news_conflicts?(_, _), do: false

  defp news_bias_high_impact?(%{high_impact: true}), do: true
  defp news_bias_high_impact?(_), do: false

  defp news_tone(%{tone_label: label}) when is_binary(label), do: label
  defp news_tone(_), do: nil

  defp news_digest(%{digest: digest}) when is_binary(digest), do: digest
  defp news_digest(_), do: nil

  defp market_state(indicators, lean) do
    cond do
      downtrend?(indicators) and indicators.current_price <= indicators.bollinger_bands.lower ->
        "Giảm tiếp diễn"

      downtrend?(indicators) ->
        "Giảm"

      uptrend?(indicators) ->
        "Tăng"

      lean == :sell ->
        "Giảm"

      lean == :buy ->
        "Tăng"

      true ->
        "Đi ngang"
    end
  end

  defp downtrend?(indicators) do
    indicators.current_price < indicators.sma_20 and indicators.sma_20 <= indicators.ema_50 and
      indicators.macd < 0
  end

  defp uptrend?(indicators) do
    indicators.current_price > indicators.sma_20 and indicators.sma_20 >= indicators.ema_50 and
      indicators.macd > 0
  end

  defp outside_band?(indicators) do
    price = indicators.current_price
    price > indicators.bollinger_bands.upper or price < indicators.bollinger_bands.lower
  end

  defp notes(indicators, lean, stop_usd, news_bias) do
    pivot = indicators.pivot_level
    place = if(lean == :sell, do: "trên", else: "dưới")

    base = [
      "Cắt lỗ nằm #{place} giá #{usd(stop_usd)} USD. Khoảng này bằng hai lần mức giá đi trung bình trong một giờ, để không bị chạm lỗ vì nhiễu ngắn.",
      "Chốt lời nằm xa gấp đôi khoảng cắt lỗ. Phí chênh lệch khi vào lệnh tạm tính #{usd(@spread)} USD, chưa lấy số thật từ sàn.",
      "Mốc trong ngày: dưới #{usd(pivot.s1)} USD, giữa #{usd(pivot.p)} USD, trên #{usd(pivot.r1)} USD.",
      "Kế hoạch này cho trong ngày. Giữ qua đêm sẽ bị tính thêm phí, chưa cộng vào lời lỗ ở trên."
    ]

    base
    |> maybe(
      "Giá đang đi sát vùng thấp trong lúc xu hướng giảm. Đà giảm vẫn còn, chưa phải chỗ để mua.",
      walking_band?(indicators)
    )
    |> maybe(
      "Giá đã xuống dưới #{usd(pivot.s1)} USD. Mốc này giờ là vùng cản phía trên.",
      indicators.current_price < pivot.s1
    )
    |> maybe(news_digest(news_bias), is_binary(news_digest(news_bias)))
    |> maybe(
      "Tin đang ngược hướng kỹ thuật — giảm kích thước lệnh hoặc đứng ngoài nếu chưa có xác nhận.",
      news_conflicts?(lean, news_bias)
    )
  end

  defp walking_band?(indicators) do
    downtrend?(indicators) and
      indicators.current_price <= indicators.bollinger_bands.lower + indicators.atr_14
  end

  defp summary(:buy, _lean, risk, nil, _indicators),
    do: "Mua theo hướng tăng. Rủi ro #{risk}. Lời lỗ chưa trừ phí thật của sàn."

  defp summary(:sell, _lean, risk, nil, _indicators),
    do: "Bán theo hướng giảm. Rủi ro #{risk}. Lời lỗ chưa trừ phí thật của sàn."

  defp summary(:wait, lean, _risk, reason, _indicators) do
    "Chưa mở lệnh. #{reason} Giá đang #{direction_word(lean)}."
  end

  defp direction_word(:buy), do: "nghiêng lên"
  defp direction_word(:sell), do: "nghiêng xuống"
  defp direction_word("buy"), do: "nghiêng lên"
  defp direction_word("sell"), do: "nghiêng xuống"
  defp direction_word(_), do: "đi ngang"

  defp stop_side(:sell), do: "trên"
  defp stop_side("sell"), do: "trên"
  defp stop_side(_), do: "dưới"

  defp take_side(:sell), do: "dưới"
  defp take_side("sell"), do: "dưới"
  defp take_side(_), do: "trên"

  defp action_label(:buy), do: "Mua"
  defp action_label(:sell), do: "Bán"
  defp action_label(:wait), do: "Không giao dịch"

  defp lean_label(:buy), do: "Nghiêng lên"
  defp lean_label(:sell), do: "Nghiêng xuống"

  defp usd(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp risk_label(score) when score <= 3, do: "thấp"
  defp risk_label(score) when score <= 6, do: "trung bình"
  defp risk_label(score) when score <= 8, do: "cao"
  defp risk_label(_score), do: "rất cao"

  defp points(distance), do: distance |> Kernel.*(100) |> Float.round() |> trunc()
  defp round2(value), do: value |> Kernel.*(1.0) |> Float.round(2)
  defp count(flags), do: Enum.count(flags, & &1)
  defp add(score, _weight, false), do: score
  defp add(score, weight, true), do: score + weight
  defp maybe(list, _note, false), do: list
  defp maybe(list, note, true), do: list ++ [note]
end

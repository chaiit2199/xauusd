defmodule GoldBackend.Services.TradePlan do
  @moduledoc """
  H1 decision ticket for an XAUUSD CFD.

  The ticket is the only trade decision. A written commentary may explain it
  and may not flip the side. Stops are 2× the hourly ATR, targets are twice
  the stop, and a stop wider than 5× ATR is not used.
  """

  alias GoldBackend.Services.EntryRules

  @point 0.01
  @spread 0.40

  def build(indicators, entry, opts \\ []) when is_number(entry) do
    entry = round2(entry)
    indicators = %{indicators | current_price: entry}
    requested = Keyword.get(opts, :ai_action)
    lean = if requested in [:buy, :sell], do: requested, else: lean(indicators)
    stop_usd = stop_distance(indicators)
    take_usd = round2(stop_usd * 2)
    rr_after_spread = reward_after_spread(stop_usd, take_usd)

    signal_action =
      if requested in [:buy, :sell, :wait], do: requested, else: action(indicators, lean)

    news_bias = Keyword.get(opts, :news_bias)
    entry_guard = EntryRules.assess(indicators, lean, Keyword.get(opts, :price_action, %{}))
    block = block_reason(opts, rr_after_spread, signal_action, indicators, news_bias, entry_guard)
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
      entry_guard: entry_guard,
      news_tone: news_tone(news_bias),
      news_digest: news_digest(news_bias),
      summary: summary(action, lean, risk_label(score), block, indicators),
      notes: notes(indicators, lean, stop_usd, news_bias),
      watchlist:
        if(Keyword.get(opts, :warmup, false),
          do: [],
          else: pullback_watchlist(indicators, entry, action)
        )
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

    watchlist_text = watchlist_commentary(Map.get(plan, :watchlist, []))

    """
    **QUYẾT ĐỊNH: #{String.upcase(plan.action_label)}** · Trạng thái: #{plan.market_state} · Rủi ro: #{plan.risk_score}/10 (#{plan.risk_label}).

    **1. Bức tranh H1**
    Giá #{usd(plan.entry)} đang #{direction_word(plan.lean)}. #{evidence}
    RSI/Stochastic quá bán trong xu hướng giảm không tự động là tín hiệu mua; đó có thể là pha chạy thanh khoản khi đà ROC vẫn âm.

    **2. Tin tức và thanh khoản**
    #{news_line} Không mở vị thế trong 30 phút trước/sau tin USD tác động mạnh vì spread và biến động có thể quét hai đầu.

    **3. Kịch bản chờ xác nhận**
    #{if watch?, do: "Chỉ theo dõi các vùng dưới đây; chưa phải lệnh thị trường.", else: "Phiếu lệnh hiện tại vẫn là quyết định ưu tiên."}
    #{watchlist_text}

    **4. Quản trị rủi ro**
    Không nhồi lệnh hoặc nới SL. #{if watch?, do: "Chờ nến H1 xác nhận thay vì bán đuổi/bắt đáy.", else: "SL #{usd(plan.stop_loss)}, TP #{usd(plan.take_profit)}; R:R sau spread #{plan.reward_risk_after_spread}."}
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

  defp block_reason(opts, rr_after_spread, signal_action, indicators, news_bias, entry_guard) do
    event = Keyword.get(opts, :blocking_event)
    warmup_detail = Keyword.get(opts, :warmup_detail)
    price_action = Keyword.get(opts, :price_action, %{})

    cond do
      Keyword.get(opts, :warmup, false) ->
        warmup_detail ||
          "Chưa đủ giá thị trường thật để vào lệnh. Lịch sử 5 ngày (gồm seed) chỉ để tính SMA/EMA/ATR."

      event ->
        "Sắp có tin #{event.title}. Chưa vào lệnh từ 30 phút trước đến 30 phút sau giờ ra tin."

      news_trade_block?(news_bias) ->
        "Tin USD tác động mạnh mới xuất hiện. Khóa lệnh 90 phút để tránh spread giãn và cú quét hai đầu sau tin."

      v_reversal_against?(signal_action, indicators, price_action) ->
        reversal_block_reason(signal_action, price_action)

      rr_after_spread < 1.5 ->
        "Phần lời sau phí vào lệnh chưa đủ lớn so với phần lỗ."

      signal_action == :buy and
          (indicators.current_price <= indicators.sma_20 or indicators.macd <= 0) ->
        "Điều kiện mua không phù hợp với SMA20 hoặc MACD."

      signal_action == :sell and
          (indicators.current_price >= indicators.sma_20 or indicators.macd >= 0) ->
        "Điều kiện bán không phù hợp với SMA20 hoặc MACD."

      entry_guard.blocked ->
        hd(entry_guard.reasons)

      signal_action == :wait ->
        "Tín hiệu chưa cùng một hướng."

      true ->
        nil
    end
  end

  defp news_trade_block?(%{trade_block: true}), do: true
  defp news_trade_block?(_), do: false

  defp v_reversal_against?(:sell, indicators, price_action) do
    rebound = Map.get(price_action, :rebound_from_low, 0.0)
    low = Map.get(price_action, :low)

    is_number(low) and low <= indicators.bollinger_bands.lower and
      rebound >= max(indicators.atr_14 * 1.5, 1.0)
  end

  defp v_reversal_against?(:buy, indicators, price_action) do
    pullback = Map.get(price_action, :pullback_from_high, 0.0)
    high = Map.get(price_action, :high)

    is_number(high) and high >= indicators.bollinger_bands.upper and
      pullback >= max(indicators.atr_14 * 1.5, 1.0)
  end

  defp v_reversal_against?(_, _indicators, _price_action), do: false

  defp reversal_block_reason(:sell, price_action) do
    "Không bán đuổi: giá vừa hồi #{usd(Map.get(price_action, :rebound_from_low, 0.0))} USD từ đáy #{usd(Map.get(price_action, :low, 0.0))} trong 90 phút sau khi quét biên dưới Bollinger."
  end

  defp reversal_block_reason(:buy, price_action) do
    "Không mua đuổi: giá vừa giảm #{usd(Map.get(price_action, :pullback_from_high, 0.0))} USD từ đỉnh #{usd(Map.get(price_action, :high, 0.0))} trong 90 phút sau khi quét biên trên Bollinger."
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

  # Conditional observation plans only: never executable pending orders.
  # Follow the actual trend, including when an AI proposes the opposite side.
  defp pullback_watchlist(indicators, entry, :wait) do
    side = EntryRules.trend(indicators)
    atr = max(indicators.atr_14, 0.5)
    sma = indicators.sma_20

    case side do
      :sell ->
        low = round2(max(sma - 0.5 * atr, entry + @point))
        high = round2(sma)
        stop = round2(high + 2 * atr)
        target = round2(low - 2 * (stop - low))

        if low < high and target > 0 do
          [
            %{
              id: "sell-pullback",
              side: "sell",
              order_type: "sell_limit",
              title: "Sell Limit · Chờ hồi về kháng cự",
              priority: "Theo xu hướng H1",
              condition:
                "Chờ RSI 45–55, Stochastic ≥ 30 và giá hồi vùng SMA20. Chỉ cân nhắc sau nến H1 từ chối giá; kiểm tra lại toàn bộ điều kiện vào lệnh. Chưa đặt lệnh.",
              entry_low: low,
              entry_high: high,
              stop_loss: stop,
              take_profit: target,
              reward_risk: rr(low, stop, target)
            }
          ]
        else
          []
        end

      :buy ->
        low = round2(sma)
        high = round2(min(sma + 0.5 * atr, entry - @point))
        stop = round2(low - 2 * atr)
        target = round2(high + 2 * (high - stop))

        if low < high and stop > 0 do
          [
            %{
              id: "buy-pullback",
              side: "buy",
              order_type: "buy_limit",
              title: "Buy Limit · Chờ điều chỉnh về hỗ trợ",
              priority: "Theo xu hướng H1",
              condition:
                "Chờ RSI 45–50, Stochastic ≤ 75 và giá điều chỉnh về SMA20. Chỉ cân nhắc sau nến H1 giữ hỗ trợ; kiểm tra lại toàn bộ điều kiện vào lệnh. Chưa đặt lệnh.",
              entry_low: low,
              entry_high: high,
              stop_loss: stop,
              take_profit: target,
              reward_risk: rr(high, stop, target)
            }
          ]
        else
          []
        end

      :wait ->
        []
    end
  end

  defp pullback_watchlist(_indicators, _entry, _action), do: []

  defp watchlist_commentary([]),
    do: "Chưa có vùng hồi/retest phù hợp từ dữ liệu H1 hiện tại."

  defp watchlist_commentary(watchlist) do
    Enum.map_join(watchlist, "\n", fn zone ->
      "- #{zone.priority}: #{zone.title}. Vùng #{usd(zone.entry_low)}–#{usd(zone.entry_high)}, SL #{usd(zone.stop_loss)}, TP #{usd(zone.take_profit)}. #{zone.condition}"
    end)
  end

  defp rr(entry, stop, target) do
    risk = abs(stop - entry)
    reward = abs(entry - target)
    if risk == 0, do: 0.0, else: Float.round(reward / risk, 2)
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

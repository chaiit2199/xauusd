defmodule GoldBackend.Services.EntryRules do
  @moduledoc """
  Entry timing for the H1 pullback strategy, independent of an AI action.
  ATR is the application's hourly close-to-close volatility proxy.
  Retests use ordered live quotes, not inferred candle patterns or extrema.
  """

  def assess(i, side, price_action \\ %{}) when side in [:buy, :sell] do
    atr = max(i.atr_14, 0.5)
    near = 0.25 * atr
    price = i.current_price
    sell? = side == :sell
    prefix = if sell?, do: "Không bán đuổi", else: "Không mua đuổi"

    reset? =
      if sell?, do: i.rsi_14 >= 45 and i.rsi_14 <= 55, else: i.rsi_14 >= 45 and i.rsi_14 <= 50

    extreme? = if sell?, do: i.rsi_14 < 35, else: i.rsi_14 > 65
    stochastic? = if sell?, do: i.stochastic_k < 30, else: i.stochastic_k > 75

    band? =
      if sell?,
        do: price <= i.bollinger_bands.lower + near,
        else: price >= i.bollinger_bands.upper - near

    stretched? = if sell?, do: i.sma_20 - price > 2 * atr, else: price - i.sma_20 > 2 * atr
    level = if sell?, do: i.pivot_level.s1, else: i.pivot_level.r1
    broken? = if sell?, do: price < level, else: price > level
    quotes = Map.get(price_action, :prices, [])
    retest = retest_state(quotes, level, side, near)
    barrier = if sell?, do: "S1", else: "R1"
    # The SMA zone is approached from the trend side. A broken pivot level
    # can substitute only after an observed break -> retest -> continuation.
    sma_zone? = abs(price - i.sma_20) <= 0.5 * atr
    retest_zone? = retest == :confirmed and abs(price - level) <= 0.5 * atr

    opposing_levels =
      if sell?, do: [i.pivot_level.s1, i.pivot_level.p], else: [i.pivot_level.r1, i.pivot_level.p]

    near_barrier? =
      Enum.any?(opposing_levels, fn value ->
        distance = if sell?, do: price - value, else: value - price
        distance >= 0 and distance <= near
      end)

    reasons =
      []
      |> add(extreme?, "#{prefix}: RSI #{i.rsi_14} #{if sell?, do: "< 35", else: "> 65"}.")
      |> add(
        stochastic?,
        "#{prefix}: Stochastic %K #{i.stochastic_k} #{if sell?, do: "< 30", else: "> 75"}."
      )
      |> add(
        band?,
        "#{prefix}: giá chạm hoặc sát dải #{if sell?, do: "dưới", else: "trên"} Bollinger (trong 0,25 ATR)."
      )
      |> add(stretched?, "#{prefix}: giá cách SMA20 hơn 2 ATR; chờ giá hồi về vùng vào lệnh.")
      |> add(
        near_barrier?,
        "#{prefix}: giá sát #{if sell?, do: "hỗ trợ S1/Pivot", else: "kháng cự R1/Pivot"} trong 0,25 ATR."
      )
      |> add(
        broken? and retest != :confirmed,
        "#{prefix}: giá đã vượt #{barrier} nhưng chưa xác nhận retest từ chuỗi giá thị trường."
      )
      |> add(
        not reset?,
        "Chờ RSI về vùng #{if sell?, do: "45–55 để bán khi hồi", else: "45–50 để mua khi điều chỉnh"}."
      )
      |> add(
        not (sma_zone? or retest_zone?),
        "Chờ giá về trong 0,5 ATR của SMA20 hoặc vùng #{barrier} đã retest; chưa mở lệnh thị trường."
      )

    %{blocked: reasons != [], reasons: reasons}
  end

  def trend(i) do
    cond do
      i.current_price < i.sma_20 and i.macd < 0 -> :sell
      i.current_price > i.sma_20 and i.macd > 0 -> :buy
      true -> :wait
    end
  end

  def retest_state(prices, level, side, tolerance) when side in [:buy, :sell] do
    # Missing history must not imply a retest. Prices must be chronological.
    if length(prices) < 3 do
      :unknown
    else
      direction = if side == :sell, do: -1, else: 1
      initial = if (hd(prices) - level) * direction > 0, do: :unknown, else: :unbroken

      Enum.reduce(prices, initial, fn price, state ->
        distance = (price - level) * direction

        cond do
          distance < -tolerance -> :unbroken
          state == :unbroken and distance > tolerance -> :pending
          state == :pending and abs(distance) <= tolerance -> :testing
          state == :testing and distance > tolerance -> :confirmed
          true -> state
        end
      end)
    end
  end

  defp add(reasons, true, message), do: reasons ++ [message]
  defp add(reasons, false, _message), do: reasons
end

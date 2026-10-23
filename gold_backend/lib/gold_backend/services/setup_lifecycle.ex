defmodule GoldBackend.Services.SetupLifecycle do
  @moduledoc "Replay the last two M15 confirmations without moving their original levels or ATR."
  alias GoldBackend.Services.{
    BiasEngine,
    CandleClock,
    Indicators,
    MarketStructure,
    SetupEngine,
    StrategyPolicy,
    Zoi
  }

  def assess(m15, h1, bias, now, events) do
    slot = CandleClock.closed_at(now)
    current = candidate(m15, h1, bias, slot)

    if current.state == "data_unavailable" or
         (bias.side == "neutral" and is_nil(Map.get(bias, :adx))) do
      current
    else
      candidates = [
        current
        | Enum.map([900, 1800], fn seconds ->
            at = DateTime.add(slot, -seconds)
            candidate(m15, h1, BiasEngine.assess(h1, at), at)
          end)
      ]

      case Enum.find(candidates, &(&1.state == "ready")) do
        nil -> current
        setup -> validate(setup, m15, bias, now, events)
      end
    end
  end

  defp candidate(m15, h1, bias, at) do
    trigger_open = DateTime.add(at, -900)

    location =
      h1
      |> Enum.filter(&(DateTime.compare(DateTime.add(&1.open_time, 3600), trigger_open) != :gt))
      |> Enum.sort_by(& &1.open_time, DateTime)

    zones =
      if length(location) < 20,
        do: [],
        else:
          Zoi.build(
            location,
            Indicators.summarize_candles(location, 3600).indicators,
            trigger_open
          )

    context = if length(location) >= 20, do: MarketStructure.assess(location, trigger_open)
    zones = zones ++ if(context, do: context.aoi, else: [])
    # All candidate zones, including AOI, must precede the trigger.
    known_at =
      if location != [],
        do: DateTime.to_iso8601(DateTime.add(List.last(location).open_time, 3600))

    zones = Enum.map(zones, &Map.put(&1, :known_at, known_at))
    SetupEngine.assess(m15, bias, zones, at, context)
  end

  def identify(setup) do
    {:ok, formed, _} = DateTime.from_iso8601(setup.candle_closed_at)
    identity = {StrategyPolicy.version(), setup.action, setup.zone.id, setup.candle_closed_at}
    id = :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16(case: :lower)

    Map.merge(setup, %{
      id: id,
      formed_at: setup.candle_closed_at,
      expires_at: DateTime.to_iso8601(DateTime.add(formed, StrategyPolicy.setup_seconds())),
      price_source: "gold_api",
      price_basis: "reference"
    })
  end

  def validate(setup, bars, bias, now, events) do
    {:ok, formed, _} = DateTime.from_iso8601(setup.formed_at)
    {:ok, expiry, _} = DateTime.from_iso8601(setup.expires_at)

    after_signal =
      Enum.filter(bars, fn b ->
        DateTime.compare(b.open_time, formed) != :lt and
          DateTime.compare(DateTime.add(b.open_time, 900), now) != :gt
      end)

    broken =
      Enum.any?(after_signal, fn b ->
        if setup.action == "buy",
          do: b.low <= setup.stop_loss or b.close <= setup.zone.low,
          else: b.high >= setup.stop_loss or b.close >= setup.zone.high
      end)

    target_reached =
      Enum.any?(after_signal, fn b ->
        is_number(setup.take_profit) and
          if(setup.action == "buy",
            do: b.high >= setup.take_profit,
            else: b.low <= setup.take_profit
          )
      end)

    news_changed =
      Enum.any?(events, fn e ->
        e.impact == "High" and Map.get(e, :country, "USD") == "USD" and
          DateTime.compare(DateTime.add(e.time, -900), now) != :gt and
          DateTime.compare(DateTime.add(e.time, 1800), formed) != :lt
      end)

    cond do
      DateTime.compare(now, expiry) != :lt ->
        halt(setup, "expired", "Setup đã hết hạn sau hai nến M15; chờ xác nhận mới.")

      bias.side != setup.action ->
        halt(setup, "invalidated", "Hướng H1 đã thay đổi; setup cũ mất hiệu lực.")

      broken ->
        halt(setup, "invalidated", "Giá đã phá cấu trúc của setup; chờ xác nhận mới.")

      target_reached ->
        halt(setup, "invalidated", "Giá đã chạm mục tiêu của setup; không phát lại tín hiệu cũ.")

      news_changed ->
        halt(
          setup,
          "invalidated",
          "Setup đi qua cửa sổ tin quan trọng; cần xác nhận M15 mới sau tin."
        )

      true ->
        setup
    end
  end

  defp halt(setup, state, reason), do: %{setup | blocked: true, state: state, reason: reason}
end

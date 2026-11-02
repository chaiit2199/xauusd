defmodule GoldBackend.Services.SetupLifecycle do
  @moduledoc "Replay recent M15 confirmations without moving their original levels or ATR."
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

    if current.state == "data_unavailable" do
      current
    else
      candidates = [
        current
        | Enum.map([900, 1800], fn seconds ->
            at = DateTime.add(slot, -seconds)
            candidate(m15, h1, BiasEngine.assess(h1, at), at)
          end)
      ]

      all =
        candidates
        |> Enum.flat_map(fn s -> [s | Map.get(s, :alternatives, [])] end)
        |> Enum.filter(&(&1.state == "ready"))
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(&validate(&1, m15, bias, now, events))

      chosen = Enum.find(all, &(&1.state == "ready")) || List.first(all) || current
      Map.put(chosen, :alternatives, all)
    end
  end

  # Only genuine, closed M5 bars may confirm a previously touched M15 zone.
  def assess_with_m5(m15, m5, h1, bias, now, events, opts \\ []) do
    m15_setup = assess(m15, h1, bias, now, events)

    result =
      if m15_setup.state == "data_unavailable" or m5 == [] do
        m15_setup
      else
        slot = CandleClock.closed_at(now, 300)

        m5_candidates =
          Enum.map([0, 300, 600, 900], fn offset ->
            at = DateTime.add(slot, -offset)
            trigger_open = DateTime.add(at, -300)

            recent_m15 =
              m15
              |> Enum.filter(
                &(DateTime.compare(DateTime.add(&1.open_time, 900), trigger_open) != :gt)
              )
              |> Enum.take(-3)

            zones =
              m15_setup.zones
              |> Enum.reject(&(Map.get(&1, :target_only, false) or Map.has_key?(&1, :side)))
              |> Enum.filter(fn z ->
                Enum.any?(recent_m15, fn b ->
                  known = Map.get(z, :known_at)

                  (is_nil(known) or known <= DateTime.to_iso8601(b.open_time)) and
                    Zoi.touch?(b, z)
                end)
              end)

            historical_bias = BiasEngine.assess(h1, trigger_open)
            setup = SetupEngine.assess(m5, historical_bias, zones, at, nil, 300)

            if setup.state == "ready", do: validate(setup, m5, bias, now, events), else: setup
          end)

        options = Enum.filter([m15_setup | m5_candidates], &(&1.state == "ready"))

        selected = if options == [], do: m15_setup, else: SetupEngine.select(options, bias)

        logs =
          [m15_setup | m5_candidates]
          |> Enum.flat_map(&Map.get(&1, :candidate_log, []))
          |> Enum.uniq_by(& &1.id)

        selected
        |> Map.merge(%{candidate_log: logs, candidate_count: length(logs)})
        |> Map.put(
          :alternatives,
          [m15_setup | m5_candidates] ++ Map.get(m15_setup, :alternatives, [])
        )
      end

    quote = Keyword.get(opts, :quote)

    all =
      [result | Map.get(result, :alternatives, [])]
      |> Enum.filter(&is_binary(Map.get(&1, :id)))
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(&validate_quote(&1, quote, now))

    valid = Enum.filter(all, &(&1.state == "ready" and not &1.blocked))
    chosen = if valid == [], do: List.first(all) || result, else: SetupEngine.select(valid, bias)

    if m5 == [] and is_nil(quote),
      do: result,
      else: Map.put(chosen, :alternatives, Enum.map(all, &Map.delete(&1, :alternatives)))
  end

  def validate_quote(setup, quote, now) do
    if GoldBackend.Services.EntryQuality.fresh_quote?(quote, now) and setup.state == "ready" do
      q = GoldBackend.Services.EntryQuality.assess(setup, quote.price, 0.0)

      if q.target_reached or not q.structure_ok,
        do:
          halt(
            setup,
            "invalidated",
            "Báo giá đã chạm SL hoặc TP; quét setup mới ngay trong lần đánh giá này."
          ),
        else: setup
    else
      setup
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
    seconds = Map.get(setup, :timeframe_seconds, 900)

    identity =
      {StrategyPolicy.version(), seconds, setup.action, setup.zone.id, setup.candle_closed_at}

    id = :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16(case: :lower)

    setup =
      Map.put_new(
        setup,
        :invalidation_price,
        if(setup.action == "buy", do: setup.zone.low, else: setup.zone.high)
      )

    Map.merge(setup, %{
      id: id,
      formed_at: setup.candle_closed_at,
      expires_at:
        DateTime.to_iso8601(
          DateTime.add(formed, if(seconds == 300, do: 1200, else: StrategyPolicy.setup_seconds()))
        ),
      price_source: "gold_api",
      price_basis: "reference"
    })
  end

  def validate(setup, bars, _bias, now, _events) do
    {:ok, formed, _} = DateTime.from_iso8601(setup.formed_at)
    {:ok, expiry, _} = DateTime.from_iso8601(setup.expires_at)

    seconds = Map.get(setup, :timeframe_seconds, 900)

    after_signal =
      Enum.filter(bars, fn b ->
        DateTime.compare(b.open_time, formed) != :lt and
          DateTime.compare(DateTime.add(b.open_time, seconds), now) != :gt
      end)

    broken =
      Enum.any?(after_signal, fn b ->
        if setup.action == "buy",
          do:
            b.low <= setup.stop_loss or
              b.close <= (Map.get(setup, :invalidation_price) || setup.zone.low),
          else:
            b.high >= setup.stop_loss or
              b.close >= (Map.get(setup, :invalidation_price) || setup.zone.high)
      end)

    target_reached =
      Enum.any?(after_signal, fn b ->
        is_number(setup.take_profit) and
          if(setup.action == "buy",
            do: b.high >= setup.take_profit,
            else: b.low <= setup.take_profit
          )
      end)

    cond do
      DateTime.compare(now, expiry) != :lt ->
        halt(setup, "expired", "Setup đã hết hạn; chờ xác nhận mới.")

      # H1/indicator bias is advisory for AI; do not cancel structure setups on bias flip.

      broken ->
        halt(setup, "invalidated", "Giá đã phá cấu trúc của setup; chờ xác nhận mới.")

      target_reached ->
        halt(setup, "invalidated", "Giá đã chạm mục tiêu của setup; không phát lại tín hiệu cũ.")

      true ->
        setup
    end
  end

  defp halt(setup, state, reason), do: %{setup | blocked: true, state: state, reason: reason}
end

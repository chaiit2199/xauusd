defmodule GoldBackend.Services.CandleStore do
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Trading.{MarketCandle, OhlcRequest}

  def load(seconds, slot) do
    cutoff = DateTime.add(slot, -seconds)

    from(c in MarketCandle,
      where: c.source == "gold_api_ohlc" and c.timeframe == ^seconds and c.open_time <= ^cutoff,
      order_by: [desc: c.open_time],
      limit: 200
    )
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&MarketCandle.to_bar/1)
  end

  def put(bar, seconds) do
    stamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    row = Map.take(bar, [:source, :open_time, :open, :high, :low, :close])

    row =
      Enum.reduce([:open, :high, :low, :close], row, fn key, acc ->
        Map.update!(acc, key, &Decimal.from_float/1)
      end)

    row = Map.merge(row, %{timeframe: seconds, inserted_at: stamp, updated_at: stamp})

    Repo.insert_all(MarketCandle, [row],
      on_conflict: {:replace, [:open, :high, :low, :close, :updated_at]},
      conflict_target: [:source, :timeframe, :open_time]
    )

    :ok
  end

  def recent_attempts(now) do
    cutoff = DateTime.add(now, -6 * 3600)

    Repo.all(
      from r in OhlcRequest,
        where: r.requested_at > ^cutoff,
        select: %{
          timeframe: r.timeframe,
          open_time: r.open_time,
          status: r.status,
          requested_at: r.requested_at
        }
    )
  end

  def reserve(open_time, seconds, now) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(640015)")
      cutoff = DateTime.add(now, -3600)

      count =
        Repo.one(from r in OhlcRequest, where: r.requested_at > ^cutoff, select: count(r.id))

      cooldown =
        Repo.exists?(
          from r in OhlcRequest,
            where: r.requested_at > ^cutoff and r.status in ["rate_limited", "unauthorized"]
        )

      duplicate =
        Repo.exists?(
          from r in OhlcRequest,
            where:
              r.open_time == ^open_time and r.timeframe == ^seconds and
                r.requested_at > ^DateTime.add(now, -120)
        )

      if count >= 8 or cooldown or duplicate do
        Repo.rollback(:quota_or_cooldown)
      else
        {1, [row]} =
          Repo.insert_all(
            OhlcRequest,
            [%{requested_at: now, open_time: open_time, timeframe: seconds, status: "pending"}],
            returning: [:id]
          )

        row.id
      end
    end)
  end

  def finish(id, status) do
    Repo.update_all(from(r in OhlcRequest, where: r.id == ^id), set: [status: status])
    :ok
  end
end

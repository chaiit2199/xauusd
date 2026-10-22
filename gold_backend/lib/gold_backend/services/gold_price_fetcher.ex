defmodule GoldBackend.Services.GoldPriceFetcher do
  @moduledoc """
  Stores one XAU/USD quote every three minutes.

  Order of sources:
  1. metals.dev when `METALS_DEV_API_KEY` is set
  2. the public Gold API (`api.gold-api.com`)
  3. a one-dollar random walk from the last stored price, so the chart
     still moves when both upstreams are down

  An empty table is filled with five days of hourly prices around the latest
  quote (~120 bars). That window is what SMA20 / EMA50 / ATR need on H1.
  Those rows are marked `origin: "seed"` so the ticket stays locked until a
  few live market prints arrive — seed is indicator fuel, not a tradeable quote.
  """

  use GenServer

  alias GoldBackend.Repo
  alias GoldBackend.Trading.GoldPrice

  import Ecto.Query

  require Logger

  @interval 180_000
  @seed_hours 24 * 5
  @fallback_anchor Decimal.new("4138.00")

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    send(self(), :fetch_price)
    {:ok, state}
  end

  def handle_info(:fetch_price, state) do
    safe_cycle()
    schedule_fetch()
    {:noreply, state}
  end

  def seed_history_if_empty do
    if Repo.aggregate(GoldPrice, :count, :id) > 0 do
      {:ok, :exists}
    else
      anchor = current_anchor()

      Repo.transaction(fn ->
        Repo.query!("LOCK TABLE gold_prices IN EXCLUSIVE MODE")

        if Repo.aggregate(GoldPrice, :count, :id) > 0 do
          :exists
        else
          insert_seed(anchor)
        end
      end)
      |> case do
        {:ok, :exists} -> {:ok, :exists}
        {:ok, count} when is_integer(count) -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def fetch_and_store_price do
    case fetch_live_quote() do
      {:ok, price, origin} ->
        store_price(price, origin)
        Logger.info("Stored XAU/USD #{price} from #{origin}")

      :unavailable ->
        price = synthetic_price()
        store_price(price, "synthetic")
        Logger.warning("Live gold quote unavailable, stored synthetic #{price}")
    end
  end

  defp safe_cycle do
    seed_history_if_empty()
    fetch_and_store_price()
  rescue
    error ->
      Logger.error("Gold price cycle failed: #{Exception.message(error)}")
  end

  defp schedule_fetch do
    Process.send_after(self(), :fetch_price, @interval)
  end

  defp current_anchor do
    case fetch_live_quote() do
      {:ok, price, _origin} -> price
      :unavailable -> @fallback_anchor
    end
  end

  defp fetch_live_quote do
    case fetch_metals_dev() do
      {:ok, price} ->
        {:ok, price, "metals_dev"}

      _ ->
        case fetch_gold_api() do
          {:ok, price} -> {:ok, price, "gold_api"}
          _ -> :unavailable
        end
    end
  end

  defp fetch_metals_dev do
    case Application.get_env(:gold_backend, :metals_dev_api_key) do
      key when is_binary(key) and key != "" ->
        url =
          "https://api.metals.dev/v1/latest?api_key=#{URI.encode_www_form(key)}&currency=USD&unit=toz"

        with {:ok, data} <- get_json(url) do
          data |> get_in(["metals", "gold"]) |> cast_price() |> ok_price()
        end

      _ ->
        {:error, :no_key}
    end
  end

  defp fetch_gold_api do
    with {:ok, data} <- get_json("https://api.gold-api.com/price/XAU") do
      data["price"] |> cast_price() |> ok_price()
    end
  end

  defp get_json(url) do
    options = [timeout: 10_000, recv_timeout: 10_000, follow_redirect: true]
    headers = [{"User-Agent", "gold-backend"}, {"Accept", "application/json"}]

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ok_price(%Decimal{} = price), do: {:ok, price}
  defp ok_price(_), do: {:error, :bad_price}

  defp cast_price(value) when is_integer(value), do: Decimal.new(value)

  defp cast_price(value) when is_float(value) do
    value |> :erlang.float_to_binary(decimals: 2) |> Decimal.new()
  end

  defp cast_price(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.round(decimal, 2)
      _ -> nil
    end
  end

  defp cast_price(_), do: nil

  defp synthetic_price do
    base =
      Repo.one(from p in GoldPrice, order_by: [desc: p.timestamp], limit: 1)
      |> case do
        nil -> @fallback_anchor
        row -> row.price
      end

    delta =
      ((:rand.uniform() - 0.5) * 2.0)
      |> :erlang.float_to_binary(decimals: 2)
      |> Decimal.new()

    base |> Decimal.add(delta) |> Decimal.round(2) |> Decimal.max(Decimal.new("1.00"))
  end

  defp insert_seed(anchor) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    latest = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600, :second)
    prices = walk_backwards(anchor, @seed_hours)

    rows =
      Enum.with_index(prices, fn price, index ->
        hours_from_end = @seed_hours - 1 - index

        %{
          price: price,
          currency: "USD",
          origin: "seed",
          timestamp: DateTime.add(latest, -hours_from_end * 3600, :second),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(GoldPrice, rows)
    length(rows)
  end

  defp walk_backwards(latest, count) do
    Enum.reduce(1..(count - 1), [latest], fn _, [current | _] = acc ->
      delta =
        ((:rand.uniform() - 0.5) * 8.0)
        |> :erlang.float_to_binary(decimals: 2)
        |> Decimal.new()

      previous =
        current
        |> Decimal.add(delta)
        |> Decimal.round(2)
        |> Decimal.max(Decimal.new("1.00"))

      [previous | acc]
    end)
  end

  defp store_price(price, origin) do
    %GoldPrice{}
    |> GoldPrice.changeset(%{
      price: price,
      currency: "USD",
      origin: origin,
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end
end

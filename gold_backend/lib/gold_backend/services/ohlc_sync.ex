defmodule GoldBackend.Services.OhlcSync do
  @moduledoc "Bounded OHLC ingestion: newest M15 first, then H1 history or M15 gap repair."
  alias GoldBackend.Services.{CandleClock, CandleStore, GoldOhlc}

  def refresh(slot, opts \\ []) do
    store = Keyword.get(opts, :store, CandleStore)
    provider = Keyword.get(opts, :provider, GoldOhlc)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if provider.configured?() do
      requests =
        plan(
          store.load(900, slot),
          store.load(3600, slot),
          store.recent_attempts(now),
          slot,
          now
        )

      Enum.reduce_while(requests, %{status: "ok", error: nil}, fn {seconds, at}, _acc ->
        with {:ok, id} <- store.reserve(at, seconds, now) do
          case provider.fetch(at, seconds, opts) do
            {:ok, bar} ->
              :ok = store.put(bar, seconds)
              store.finish(id, "ok")
              {:cont, %{status: "ok", error: nil}}

            {:error, reason} ->
              store.finish(id, error_code(reason))
              {:halt, %{status: "error", error: message(reason)}}
          end
        else
          {:error, _} ->
            {:halt,
             %{
               status: "limited",
               error: "Đang chờ hạn mức OHLC; tối đa 8 lượt/giờ cho ứng dụng."
             }}
        end
      end)
    else
      %{status: "missing_key", error: message(:missing_key)}
    end
  end

  def plan(m15, h1, attempts, slot, now) do
    history_tick? = DateTime.compare(slot, CandleClock.closed_at(slot)) == :eq
    slot = CandleClock.closed_at(slot)
    last_m15 = DateTime.add(slot, -900)
    last_h1 = slot |> CandleClock.closed_at(3600) |> DateTime.add(-3600)
    m15_times = MapSet.new(Enum.map(m15, &DateTime.to_unix(&1.open_time)))
    h1_times = MapSet.new(Enum.map(h1, &DateTime.to_unix(&1.open_time)))

    available? = fn seconds, at, known ->
      not GoldBackend.Services.MarketSchedule.closed_interval?(at, seconds) and
        not MapSet.member?(known, DateTime.to_unix(at)) and
        not Enum.any?(attempts, fn a ->
          a.timeframe == seconds and DateTime.compare(a.open_time, at) == :eq and
            DateTime.diff(now, a.requested_at) <
              if(a.status == "invalid_ohlc", do: 6 * 3600, else: 120)
        end)
    end

    current = if available?.(900, last_m15, m15_times), do: [{900, last_m15}], else: []

    missing_h1 =
      Enum.find(0..167, fn back ->
        available?.(3600, DateTime.add(last_h1, -back * 3600), h1_times)
      end)

    missing_m15 =
      Enum.find(1..49, fn back ->
        available?.(900, DateTime.add(last_m15, -back * 900), m15_times)
      end)

    history =
      cond do
        not history_tick? ->
          []

        missing_h1 != nil and
            (length(h1) < 50 or not MapSet.member?(h1_times, DateTime.to_unix(last_h1))) ->
          [{3600, DateTime.add(last_h1, -missing_h1 * 3600)}]

        missing_m15 != nil ->
          [{900, DateTime.add(last_m15, -missing_m15 * 900)}]

        true ->
          []
      end

    current ++ history
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_), do: "http_error"
  defp message(:missing_key), do: "Chưa cấu hình GOLD_API_KEY để lấy OHLC XAU/USD."
  defp message(:unauthorized), do: "Gold API từ chối API key hoặc quyền truy cập OHLC."
  defp message(:rate_limited), do: "Gold API giới hạn lượt gọi; tạm dừng OHLC trong một giờ."

  defp message(:stale_quote),
    do:
      "Báo giá Gold API cũ hơn 120 giây so với giờ máy chủ; chờ dữ liệu mới hoặc kiểm tra đồng hồ máy chủ."

  defp message(:clock_skew),
    do:
      "Thời gian báo giá Gold API đi trước máy chủ hơn 5 giây; cần kiểm tra đồng bộ giờ máy chủ."

  defp message(:invalid_quote),
    do: "Gold API trả báo giá XAU/USD không hợp lệ; chờ dữ liệu hợp lệ."

  defp message(:invalid_ohlc), do: "Gold API chưa trả OHLC hợp lệ cho khoảng nến yêu cầu."
  defp message(:not_settled), do: "Chờ thêm 30 giây sau đóng nến để nguồn cập nhật OHLC."
  defp message(_), do: "Không lấy được dữ liệu Gold API; chờ lần đồng bộ kế tiếp."
end

defmodule GoldBackend.Services.SignalSimulator do
  @moduledoc "Price-touch study on complete provider M15 candles; never a broker fill or P&L."
  alias GoldBackend.Services.CandleClock

  def evaluate(signal, bars, now) do
    start = next_full_bar(signal.published_at)
    until = min_time(signal.horizon_at, now) |> CandleClock.closed_at()

    deadline =
      if signal.cancelled_at,
        do: min_time(signal.entry_expires_at, signal.cancelled_at),
        else: signal.entry_expires_at

    base = %{
      status: "pending_entry",
      entry_touched: false,
      entry_bar_at: nil,
      exit_bar_at: nil,
      entry_price: nil,
      observed_from: iso(start),
      observed_through: nil,
      model: "m15-touch-v1",
      detail: "Chỉ xét nến M15 trọn vẹn sau khi phát tín hiệu; chạm giá không xác nhận khớp lệnh."
    }

    grouped = Enum.group_by(bars, & &1.open_time)

    slots =
      if DateTime.compare(start, until) == :lt,
        do:
          Stream.iterate(start, &DateTime.add(&1, 900))
          |> Enum.take_while(&(DateTime.compare(&1, until) == :lt)),
        else: []

    result =
      Enum.reduce_while(slots, base, fn at, state ->
        if not state.entry_touched and DateTime.compare(at, deadline) != :lt do
          {:halt, %{state | status: no_entry_status(signal)}}
        else
          case Map.get(grouped, at) do
            [bar] ->
              if valid?(bar) do
                close = DateTime.add(at, 900)
                # A cancellation part-way through a candle makes its order unknowable.
                if not state.entry_touched and DateTime.compare(close, deadline) == :gt do
                  {:halt,
                   %{
                     state
                     | status: "ambiguous",
                       detail:
                         "Thời hạn hoặc điều kiện hủy nằm giữa nến; không xác định được thứ tự chạm entry."
                   }}
                else
                  next = step(state, signal, bar) |> Map.put(:observed_through, iso(close))
                  if terminal?(next.status), do: {:halt, next}, else: {:cont, next}
                end
              else
                {:halt,
                 %{
                   state
                   | status: "data_gap",
                     detail: "Nến thiếu xác nhận hoặc OHLC không hợp lệ; chưa kết luận kết quả."
                 }}
              end

            _ ->
              {:halt,
               %{
                 state
                 | status: "data_gap",
                   detail:
                     "Thiếu hoặc trùng nến M15 trong cửa sổ theo dõi; chưa kết luận kết quả."
               }}
          end
        end
      end)

    cond do
      terminal?(result.status) or result.status == "data_gap" ->
        result

      result.entry_touched and DateTime.compare(now, signal.horizon_at) != :lt ->
        %{result | status: "expired_after_entry"}

      not result.entry_touched and DateTime.compare(now, deadline) != :lt and
          (DateTime.compare(until, deadline) != :lt or DateTime.compare(start, deadline) != :lt) ->
        %{result | status: no_entry_status(signal)}

      true ->
        result
    end
  end

  defp step(state, s, b) do
    tp = if s.side == "buy", do: b.high >= s.take_profit, else: b.low <= s.take_profit
    sl = if s.side == "buy", do: b.low <= s.stop_loss, else: b.high >= s.stop_loss
    touch = b.low <= s.entry_high and b.high >= s.entry_low
    open_inside = b.open >= s.entry_low and b.open <= s.entry_high
    beyond_stop = if s.side == "buy", do: b.open <= s.stop_loss, else: b.open >= s.stop_loss

    cond do
      state.entry_touched ->
        outcome(state, tp, sl, b)

      beyond_stop ->
        %{state | status: "invalidated_before_entry", exit_bar_at: iso(b.open_time)}

      touch ->
        price =
          if open_inside,
            do: b.open,
            else: if(b.open > s.entry_high, do: s.entry_high, else: s.entry_low)

        entered = %{
          state
          | entry_touched: true,
            entry_bar_at: iso(b.open_time),
            entry_price: price,
            status: "entry_touched"
        }

        if not open_inside and (tp or sl),
          do: %{
            entered
            | status: "ambiguous",
              exit_bar_at: iso(b.open_time),
              detail:
                "Entry và mức thoát cùng được chạm trong nến; OHLC không xác định được thứ tự."
          },
          else: outcome(entered, tp, sl, b)

      tp or sl ->
        %{state | status: "invalidated_before_entry", exit_bar_at: iso(b.open_time)}

      true ->
        state
    end
  end

  defp outcome(state, true, true, b),
    do: %{
      state
      | status: "ambiguous",
        exit_bar_at: iso(b.open_time),
        detail: "Cùng nến chạm cả TP và SL; không xác định mức nào trước."
    }

  defp outcome(state, true, false, b),
    do: %{state | status: "tp_first", exit_bar_at: iso(b.open_time)}

  defp outcome(state, false, true, b),
    do: %{state | status: "sl_first", exit_bar_at: iso(b.open_time)}

  defp outcome(state, false, false, _), do: state

  defp terminal?(status),
    do:
      status in [
        "tp_first",
        "sl_first",
        "ambiguous",
        "invalidated_before_entry",
        "cancelled_without_entry",
        "expired_without_entry",
        "expired_after_entry"
      ]

  defp no_entry_status(s),
    do:
      if(s.cancelled_at && DateTime.compare(s.cancelled_at, s.entry_expires_at) == :lt,
        do: "cancelled_without_entry",
        else: "expired_without_entry"
      )

  defp next_full_bar(at) do
    floor = CandleClock.closed_at(at)
    if DateTime.compare(at, floor) == :eq, do: floor, else: DateTime.add(floor, 900)
  end

  defp valid?(b),
    do:
      Map.get(b, :confirmed) == true and not Map.get(b, :approx, false) and
        not Map.get(b, :is_approximate, false) and
        Enum.all?([b.open, b.high, b.low, b.close], &is_number/1) and
        b.low > 0 and b.low <= min(b.open, b.close) and b.high >= max(b.open, b.close)

  defp min_time(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp iso(at), do: DateTime.to_iso8601(at)
end

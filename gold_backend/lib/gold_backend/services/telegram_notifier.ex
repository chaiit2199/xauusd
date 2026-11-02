defmodule GoldBackend.Services.TelegramNotifier do
  require Logger
  alias GoldBackend.Services.AiDecision

  def configuration_status do
    config = Application.get_env(:gold_backend, :telegram, [])

    missing =
      [{:bot_token, "TELEGRAM_BOT_TOKEN"}, {:chat_id, "TELEGRAM_CHAT_ID"}]
      |> Enum.reject(fn {key, _} -> present?(Keyword.get(config, key)) end)
      |> Enum.map(&elem(&1, 1))

    %{configured: missing == [], missing: missing}
  end

  def validate_config do
    case configuration_status() do
      %{configured: true} ->
        :ok

      %{missing: missing} ->
        failure(
          "Thiếu #{Enum.join(missing, ", ")}; kiểm tra env.sh trên VPS và tạo lại container API."
        )
    end
  end

  def notify(snapshot, opts \\ [])

  def notify(%{cfd_plan: %{action: "wait"}}, _opts), do: :ok

  def notify(%{cfd_plan: %{action: action}} = snapshot, opts)
      when action in ["buy", "sell"] do
    with :ok <- validate_ai_confirm(snapshot),
         :ok <- validate_slot(snapshot),
         :ok <- validate_ticket(snapshot),
         :ok <- validate_config(),
         true <- notification_allowed?(Keyword.get(opts, :now, DateTime.utc_now())) do
      deliver(format_message(snapshot), opts)
    else
      false -> :ok
      error -> error
    end
  end

  def notify(_, _), do: {:error, "Snapshot không hợp lệ để gửi Telegram."}

  @doc "Plan/entry lifecycle alerts use deterministic checks; AI commentary is optional."
  def notify_event(snapshot, event, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- if(event == "READY_TO_ENTER", do: :ok, else: {:error, :event_disabled}),
         :ok <- validate_event(snapshot, event, now),
         :ok <- validate_config(),
         true <- notification_allowed?(now) do
      started = System.monotonic_time(:millisecond)
      result = deliver(format_event(snapshot, event, now), opts)

      Logger.info(
        "telegram_entry_delivery " <>
          Jason.encode!(%{
            setup_id: Map.get(snapshot.cfd_plan, :setup_id),
            entry: snapshot.cfd_plan.entry,
            quote_at: Map.get(snapshot.cfd_plan, :quote_at),
            quote_age_seconds: quote_age(snapshot.cfd_plan, now),
            send_started_at: DateTime.to_iso8601(now),
            signal_valid_until: Map.get(snapshot, :signal_valid_until),
            request_ms: System.monotonic_time(:millisecond) - started,
            accepted: result == :ok
          })
      )

      result
    else
      false -> {:error, :outside_notification_hours}
      error -> error
    end
  end

  def validate_event(%{cfd_plan: plan} = snapshot, event, now) do
    terminal = event in ["INVALIDATED", "EXPIRED"]
    checks = Map.get(plan, :plan_checks, [])
    fresh_setup = future?(Map.get(plan, :setup_expires_at), now)
    calendar = future?(Map.get(snapshot, :calendar_valid_until), now)

    valid_plan =
      Map.get(plan, :plan_status) == "PLAN_READY" and checks != [] and
        Enum.all?(checks, &(&1.status == "pass")) and fresh_setup and calendar

    valid =
      cond do
        terminal ->
          String.upcase(Map.get(plan, :setup_status, "")) == event

        event == "PLAN_READY" ->
          valid_plan

        event == "READY_TO_ENTER" ->
          valid_plan and plan.action in ["buy", "sell"] and
            Map.get(plan, :trade_plan_status) == event and
            future?(Map.get(snapshot, :signal_valid_until), now) and
            Enum.all?(
              Map.get(plan, :checks, []),
              &(not Map.get(&1, :required, true) or &1.status == "pass")
            )

        event in ["WAIT_RETEST", "PRICE_MOVED"] ->
          valid_plan and Map.get(plan, :trade_plan_status) == event

        true ->
          false
      end

    if valid, do: :ok, else: {:error, :event_not_eligible}
  end

  defp future?(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.compare(now, at) == :lt
      _ -> false
    end
  end

  defp future?(_, _), do: false

  def format_event(%{cfd_plan: plan} = snapshot, event, now \\ DateTime.utc_now()) do
    side =
      Map.get(
        plan,
        :trade_direction_label,
        String.upcase(Map.get(plan, :planning_action, "wait"))
      )

    entry = if event == "READY_TO_ENTER", do: plan.entry, else: plan.reference_entry
    tp2 = get_in(plan, [:trade_plan, :risk, :tp2])

    note =
      case event do
        "PLAN_READY" ->
          "Kế hoạch từ nến đã đóng; chưa phải xác nhận vào ngay. Chờ báo giá mới để kiểm tra entry."

        "READY_TO_ENTER" ->
          "Báo giá mới và các hard rule vào ngay đã đạt; đây là tín hiệu nghiên cứu, không phải lệnh đã khớp."

        "WAIT_RETEST" ->
          "Plan còn hiệu lực; chờ retest đạt điều kiện vào."

        "PRICE_MOVED" ->
          "Giá đã di chuyển; không đuổi giá, chờ kiểm tra lại entry."

        _ ->
          "Setup đã kết thúc; đang quét setup mới."
      end

    Enum.join(
      [
        "#{event} · XAUUSD · #{side}",
        "#{Map.get(plan, :h1_bias_label, "H1 chưa rõ")} | #{plan.timeframe}",
        "#{if event == "READY_TO_ENTER", do: "Giá kiểm tra", else: "Entry tham chiếu"}: #{entry}",
        "SL: #{plan.stop_loss} | TP1: #{plan.take_profit} | TP2: #{tp2 || "chưa đủ khoảng trống cấu trúc"}",
        "Nguồn quote: Gold API XAU/USD · không phải bid/ask FXCM",
        "Giờ quote UTC: #{Map.get(plan, :quote_at) || "không rõ"} · Tuổi quote lúc gửi: #{quote_age(plan, now) || "không rõ"} giây",
        "Bắt đầu gửi UTC: #{DateTime.to_iso8601(now)}",
        "Entry được kiểm tra có hiệu lực tới UTC: #{Map.get(snapshot, :signal_valid_until) || "không rõ"}",
        "Hết hạn setup UTC: #{plan.setup_expires_at}",
        note,
        Enum.join(Map.get(plan, :soft_flags, []), " · ")
      ],
      "\n"
    )
  end

  defp quote_age(plan, now) do
    case DateTime.from_iso8601(Map.get(plan, :quote_at) || "") do
      {:ok, at, _} -> DateTime.diff(now, at)
      _ -> nil
    end
  end

  defp deliver(text, opts) do
    config = Application.get_env(:gold_backend, :telegram, [])
    token = config |> Keyword.fetch!(:bot_token) |> String.trim()
    chat = config |> Keyword.fetch!(:chat_id) |> String.trim()
    post = Keyword.get(opts, :http_post, &HTTPoison.post/4)

    result =
      post.(
        "https://api.telegram.org/bot#{token}/sendMessage",
        Jason.encode!(%{chat_id: chat, text: text}),
        [{"Content-Type", "application/json"}],
        timeout: 5_000,
        recv_timeout: 5_000
      )

    case result do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true}} when status == 200 ->
            Logger.info("Telegram notification delivered")
            :ok

          {:ok, %{"description" => description} = response} when is_binary(description) ->
            code = response["error_code"] || status

            detail =
              description
              |> String.replace([token, chat], "[redacted]")
              |> String.replace(~r/\s+/, " ")
              |> String.slice(0, 300)

            failure("HTTP #{status}: #{detail}. #{hint(code)}")

          _ ->
            failure("HTTP #{status}: phản hồi Telegram không hợp lệ.")
        end

      {:error, %HTTPoison.Error{reason: reason}} ->
        # Do not log the request URL: it contains the bot token.
        detail = if is_atom(reason), do: Atom.to_string(reason), else: "network_error"
        failure("Không kết nối được Telegram (#{detail}); kiểm tra mạng/DNS/TLS của container.")
    end
  end

  # Notification hours do not alter the rule decision or publication history.
  def notification_allowed?(now) do
    window =
      Application.get_env(
        :gold_backend,
        :notification_hours,
        System.get_env("TELEGRAM_NOTIFY_HOURS", "all")
      )

    hour = DateTime.add(now, 7 * 3600).hour

    case window do
      "all" ->
        true

      value when is_binary(value) ->
        case Regex.run(~r/^(\d{1,2})-(\d{1,2})$/, value) do
          [_, first, last] ->
            first = String.to_integer(first)
            last = String.to_integer(last)

            first in 0..23 and last in 0..24 and first != last and
              if(first < last,
                do: hour >= first and hour < last,
                else: hour >= first or hour < last
              )

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp validate_ai_confirm(
         %{cfd_plan: %{action: side}, ai_action: side, ai_status: "ready"} = snapshot
       )
       when side in ["buy", "sell"] do
    case AiDecision.validate_reason(Map.get(snapshot, :ai_insight)) do
      {:ok, _} -> :ok
      {:error, _} -> failure("Chưa có nhận định AI hợp lệ; không gửi Telegram chỉ theo rule.")
    end
  end

  defp validate_ai_confirm(%{ai_action: "wait"}),
    do: failure("AI chọn Đứng ngoài; không gửi Telegram.")

  defp validate_ai_confirm(_),
    do: failure("Chờ AI xác nhận cùng chiều setup; chỉ báo và tin đã gửi kèm để nhận định.")

  defp validate_slot(%{signal_valid_until: expiry} = snapshot) when is_binary(expiry) do
    with {:ok, at, _} <- DateTime.from_iso8601(expiry),
         :lt <- DateTime.compare(DateTime.utc_now(), at) do
      validate_slot(Map.delete(snapshot, :signal_valid_until))
    else
      _ -> failure("Không gửi tín hiệu có báo giá đã quá hạn.")
    end
  end

  defp validate_slot(%{calendar_valid_until: expiry} = snapshot) when is_binary(expiry) do
    with {:ok, at, _} <- DateTime.from_iso8601(expiry),
         :lt <- DateTime.compare(DateTime.utc_now(), at) do
      validate_slot(Map.delete(snapshot, :calendar_valid_until))
    else
      _ -> failure("Không gửi tín hiệu khi lịch tin đã hết hiệu lực.")
    end
  end

  defp validate_slot(%{ai_next_analysis_at: expiry}) do
    case if(is_binary(expiry), do: DateTime.from_iso8601(expiry), else: :invalid) do
      {:ok, at, _} ->
        if DateTime.compare(DateTime.utc_now(), at) == :lt,
          do: :ok,
          else: failure("Không gửi nhận định đã hết chu kỳ M15.")

      _ ->
        failure("Thời hạn nhận định M15 không hợp lệ.")
    end
  end

  defp validate_slot(_), do: :ok

  defp validate_ticket(%{
         cfd_plan: %{action: side, entry: entry, stop_loss: stop, take_profit: target}
       })
       when is_number(entry) and is_number(stop) and is_number(target) do
    valid =
      entry > 0 and stop > 0 and target > 0 and
        if side == "buy",
          do: stop < entry and entry < target,
          else: target < entry and entry < stop

    if valid, do: :ok, else: failure("Mức giá phiếu không hợp lệ.")
  end

  defp validate_ticket(_), do: failure("Thiếu mức giá phiếu.")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp failure(reason) do
    Logger.warning("Telegram: #{reason}")
    {:error, reason}
  end

  defp hint(401), do: "Kiểm tra TELEGRAM_BOT_TOKEN."
  defp hint(400), do: "Kiểm tra TELEGRAM_CHAT_ID và mở bot để gửi /start."
  defp hint(403), do: "Mở khóa bot, gửi /start hoặc cấp quyền gửi tin trong nhóm/kênh."
  defp hint(429), do: "Telegram đang giới hạn tần suất gửi."
  defp hint(_), do: "Kiểm tra phản hồi Telegram và kết nối của container."

  def format_message(%{cfd_plan: plan} = snapshot) do
    label =
      case plan.action do
        "buy" -> "Mua"
        "sell" -> "Bán"
        "wait" -> "Đứng ngoài"
      end

    levels =
      if plan.action == "wait" do
        []
      else
        ["Giá vào lệnh: #{plan.entry}", "TP: #{plan.take_profit} | SL: #{plan.stop_loss}"]
      end

    indicators = Map.get(snapshot, :indicators_10, %{})

    evidence =
      if Enum.all?([:sma_20, :macd, :rsi_14], &Map.has_key?(indicators, &1)) do
        "SMA20 #{indicators.sma_20}, MACD #{indicators.macd}, RSI #{indicators.rsi_14}. "
      else
        ""
      end

    reason =
      case AiDecision.validate_reason(Map.get(snapshot, :ai_insight)) do
        {:ok, text} ->
          short_reason(text)

        _ ->
          Map.get(plan, :block_reason) ||
            Map.get(plan, :summary, "Chờ nhận định AI xác nhận setup cấu trúc.")
      end

    (["Khuyến nghị: #{label}"] ++ levels ++ ["Lý do: #{evidence}#{reason}"])
    |> Enum.join("\n")
  end

  defp short_reason(text) when is_binary(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > 350, do: String.slice(text, 0, 347) <> "...", else: text
  end

  defp short_reason(_), do: "Chưa có nhận định AI."
end

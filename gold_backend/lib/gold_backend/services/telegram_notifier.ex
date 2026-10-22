defmodule GoldBackend.Services.TelegramNotifier do
  require Logger

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
  def notify(%{ai_error: error}, _opts) when not is_nil(error), do: :ok

  def notify(%{cfd_plan: %{action: action}} = snapshot, opts)
      when action in ["buy", "sell"] do
    with :ok <- validate_config() do
      config = Application.get_env(:gold_backend, :telegram, [])
      token = config |> Keyword.fetch!(:bot_token) |> String.trim()
      chat = config |> Keyword.fetch!(:chat_id) |> String.trim()
      post = Keyword.get(opts, :http_post, &HTTPoison.post/4)

      result =
        post.(
          "https://api.telegram.org/bot#{token}/sendMessage",
          Jason.encode!(%{chat_id: chat, text: format_message(snapshot)}),
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
  end

  def notify(_, _), do: {:error, "Snapshot không hợp lệ để gửi Telegram."}

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
        "wait" -> "Không giao dịch"
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
      cond do
        is_binary(Map.get(snapshot, :ai_error)) ->
          "Không có quyết định AI hợp lệ: #{snapshot.ai_error}"

        plan.action == "wait" and is_binary(Map.get(plan, :block_reason)) and
            Map.get(snapshot, :ai_action) != "wait" ->
          plan.block_reason

        true ->
          short_reason(Map.get(snapshot, :ai_insight))
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

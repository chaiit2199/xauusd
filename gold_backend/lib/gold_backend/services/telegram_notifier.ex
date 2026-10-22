defmodule GoldBackend.Services.TelegramNotifier do
  require Logger

  def notify(%{cfd_plan: %{action: action}} = snapshot) when action in ["buy", "sell", "wait"] do
    config = Application.get_env(:gold_backend, :telegram, [])
    token = Keyword.get(config, :bot_token)
    chat = Keyword.get(config, :chat_id)

    if is_binary(token) and token != "" and is_binary(chat) and chat != "" do
      message = format_message(snapshot)

      case HTTPoison.post(
             "https://api.telegram.org/bot#{token}/sendMessage",
             Jason.encode!(%{chat_id: chat, text: message}),
             [{"Content-Type", "application/json"}],
             timeout: 5_000,
             recv_timeout: 5_000
           ) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          unless match?({:ok, %{"ok" => true}}, Jason.decode(body)),
            do: Logger.warning("Telegram rejected notification")

        _ ->
          Logger.warning("Telegram notification failed")
      end
    end

    :ok
  end

  def notify(_), do: :ok

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

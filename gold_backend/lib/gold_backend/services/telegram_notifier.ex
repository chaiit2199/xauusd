defmodule GoldBackend.Services.TelegramNotifier do
  require Logger

  def notify(%{cfd_plan: %{action: action} = plan} = snapshot) when action in ["buy", "sell"] do
    config = Application.get_env(:gold_backend, :telegram, [])
    token = Keyword.get(config, :bot_token)
    chat = Keyword.get(config, :chat_id)

    if is_binary(token) and token != "" and is_binary(chat) and chat != "" do
      message =
        "XAUUSD #{String.upcase(action)}\nGiá: #{plan.entry} | SL: #{plan.stop_loss} | TP: #{plan.take_profit}\n#{snapshot.ai_insight}\nThời gian: #{snapshot.ai_cached_at}"

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
end

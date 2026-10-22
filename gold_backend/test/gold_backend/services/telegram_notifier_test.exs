defmodule GoldBackend.Services.TelegramNotifierTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias GoldBackend.Services.TelegramNotifier

  @snapshot %{cfd_plan: %{action: "wait"}, ai_error: "AI chưa trả nhận định tiếng Việt hợp lệ."}

  setup do
    previous = Application.get_env(:gold_backend, :telegram)
    Application.put_env(:gold_backend, :telegram, bot_token: " test-token ", chat_id: " 12345 ")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:gold_backend, :telegram, previous),
        else: Application.delete_env(:gold_backend, :telegram)
    end)
  end

  test "missing or whitespace-only credentials report exactly what is missing without sending" do
    Application.put_env(:gold_backend, :telegram, bot_token: " \n", chat_id: "12345")

    assert %{configured: false, missing: ["TELEGRAM_BOT_TOKEN"]} =
             TelegramNotifier.configuration_status()

    log =
      capture_log(fn ->
        assert {:error, reason} =
                 TelegramNotifier.notify(@snapshot,
                   http_post: fn _, _, _, _ -> flunk("must not send") end
                 )

        assert reason =~ "TELEGRAM_BOT_TOKEN"
      end)

    assert log =~ "TELEGRAM_BOT_TOKEN"
    refute log =~ "12345"
  end

  test "AI errors and wait decisions still send a notification" do
    post = fn url, body, headers, _ ->
      send(self(), {:sent, url, Jason.decode!(body), headers})
      {:ok, %HTTPoison.Response{status_code: 200, body: ~s({"ok":true})}}
    end

    assert :ok = TelegramNotifier.notify(@snapshot, http_post: post)

    assert_received {:sent, "https://api.telegram.org/bottest-token/sendMessage", payload,
                     [{"Content-Type", "application/json"}]}

    assert payload["chat_id"] == "12345"
    assert payload["text"] =~ "Không giao dịch"
    assert payload["text"] =~ @snapshot.ai_error
    refute payload["text"] =~ "SL:"
  end

  test "Telegram API rejection is returned with actionable diagnostics and secrets redacted" do
    for {code, description, hint} <- [
          {400, "Bad Request: chat not found", "TELEGRAM_CHAT_ID"},
          {401, "Unauthorized", "TELEGRAM_BOT_TOKEN"},
          {403, "Forbidden: bot was blocked by the user", "/start"},
          {429, "Too Many Requests", "tần suất"}
        ] do
      post = fn _, _, _, _ ->
        {:ok,
         %HTTPoison.Response{
           status_code: code,
           body:
             Jason.encode!(%{
               ok: false,
               error_code: code,
               description: description <> " test-token 12345"
             })
         }}
      end

      log =
        capture_log(fn ->
          assert {:error, reason} = TelegramNotifier.notify(@snapshot, http_post: post)
          assert reason =~ description
          assert reason =~ hint
          refute reason =~ "test-token"
          refute reason =~ "12345"
        end)

      assert log =~ "HTTP #{code}"
      refute log =~ "test-token"
      refute log =~ "12345"
    end
  end

  test "HTTP success with ok false and non-JSON responses are not delivery successes" do
    for body <- [~s({"ok":false,"description":"Rejected"}), "bad gateway"] do
      post = fn _, _, _, _ -> {:ok, %HTTPoison.Response{status_code: 200, body: body}} end

      capture_log(fn ->
        assert {:error, _} = TelegramNotifier.notify(@snapshot, http_post: post)
      end)
    end
  end

  test "network failures return a diagnostic without exposing a request URL" do
    for failure <- [
          :timeout,
          :nxdomain,
          {:connection, "https://api.telegram.org/bottest-token/sendMessage"}
        ] do
      post = fn _, _, _, _ -> {:error, %HTTPoison.Error{reason: failure}} end

      log =
        capture_log(fn ->
          assert {:error, reason} = TelegramNotifier.notify(@snapshot, http_post: post)
          assert reason =~ "Không kết nối được Telegram"
        end)

      refute log =~ "test-token"
    end
  end
end

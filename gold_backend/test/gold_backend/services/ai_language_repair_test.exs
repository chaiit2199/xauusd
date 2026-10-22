defmodule GoldBackend.Services.AiLanguageRepairTest do
  use ExUnit.Case, async: false

  alias GoldBackend.Services.AiDecision

  @english String.duplicate("Price is above SMA20 with positive MACD; wait for confirmation. ", 3)
  @vietnamese String.trim(
                String.duplicate(
                  "Giá nằm trên SMA20 với MACD dương; chờ xác nhận và theo dõi rủi ro. ",
                  3
                )
              )

  setup do
    previous = Application.get_env(:gold_backend, :ollama)
    Application.put_env(:gold_backend, :ollama, timeout_ms: 1_000, translation_timeout_ms: 2_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:gold_backend, :ollama, previous),
        else: Application.delete_env(:gold_backend, :ollama)
    end)

    %{
      context: %{
        indicators: %{},
        plan: %{entry: 2000},
        warmup: false,
        news_bias: %{digest: "Chưa có tin"},
        events: [],
        news: []
      }
    }
  end

  test "repairs English once using the same model and an independent translation timeout", %{
    context: context
  } do
    post = fn _url, body, _headers, options ->
      request = Jason.decode!(body)
      send(self(), {:request, request, options})

      case get_in(request, ["format", "properties", "action", "enum"]) do
        ["buy", "sell", "wait"] -> response("wait", @english)
        ["wait"] -> response("wait", @vietnamese)
      end
    end

    assert {:ok, :wait, @vietnamese} = AiDecision.analyze(context, http_post: post)
    assert_received {:request, original, first_options}
    assert_received {:request, repair, repair_options}
    assert repair["prompt"] =~ @english
    assert original["model"] == "deepseek-r1:1.5b"
    assert repair["model"] == original["model"]
    refute Map.has_key?(original, "system")
    refute Map.has_key?(repair, "system")
    assert original["options"]["num_predict"] == 800
    assert first_options[:recv_timeout] == 1_000
    assert repair_options[:recv_timeout] == 2_000
    refute_received {:request, _, _}
  end

  test "a valid Vietnamese response needs only one request", %{context: context} do
    post = fn _, _, _, _ ->
      send(self(), :called)
      response("buy", @vietnamese)
    end

    assert {:ok, :buy, _} = AiDecision.analyze(context, http_post: post)
    assert_received :called
    refute_received :called
  end

  test "repair still in English is rejected after two requests", %{context: context} do
    post = fn _, _, _, _ ->
      send(self(), :called)
      response("wait", @english)
    end

    assert {:error, "AI chưa trả nhận định tiếng Việt hợp lệ."} =
             AiDecision.analyze(context, http_post: post)

    assert_received :called
    assert_received :called
    refute_received :called
  end

  test "a translation that changes action is rejected", %{context: context} do
    post = fn _, body, _, _ ->
      case get_in(Jason.decode!(body), ["format", "properties", "action", "enum"]) do
        ["wait"] -> response("buy", @vietnamese)
        _ -> response("wait", @english)
      end
    end

    assert {:error, reason} = AiDecision.analyze(context, http_post: post)
    assert reason =~ "thay đổi quyết định"
  end

  test "network and truncated or malformed results are not language-repaired", %{context: context} do
    results = [
      {:error, %HTTPoison.Error{reason: :timeout}},
      {:ok,
       %HTTPoison.Response{
         status_code: 200,
         body: Jason.encode!(%{response: "{}", done_reason: "length"})
       }},
      {:ok, %HTTPoison.Response{status_code: 200, body: Jason.encode!(%{response: "not json"})}}
    ]

    for result <- results do
      post = fn _, _, _, _ ->
        send(self(), :called)
        result
      end

      assert {:error, _} = AiDecision.analyze(context, http_post: post)
      assert_received :called
      refute_received :called
    end
  end

  test "slow analysis does not consume the translation timeout", %{context: context} do
    Application.put_env(:gold_backend, :ollama, timeout_ms: 100, translation_timeout_ms: 300)

    post = fn _, body, _, options ->
      case get_in(Jason.decode!(body), ["format", "properties", "action", "enum"]) do
        ["wait"] ->
          send(self(), {:translation_timeout, options[:recv_timeout]})
          response("wait", @vietnamese)

        _ ->
          Process.sleep(20)
          response("wait", @english)
      end
    end

    assert {:ok, :wait, _} = AiDecision.analyze(context, http_post: post)
    assert_received {:translation_timeout, 300}
  end

  test "translation timeout names its own configuration and is not retried", %{context: context} do
    post = fn _, body, _, _ ->
      send(self(), :called)

      case get_in(Jason.decode!(body), ["format", "properties", "action", "enum"]) do
        ["wait"] -> {:error, %HTTPoison.Error{reason: :timeout}}
        _ -> response("wait", @english)
      end
    end

    assert {:error, reason} = AiDecision.analyze(context, http_post: post)
    assert reason =~ "OLLAMA_TRANSLATION_TIMEOUT_MS"
    assert_received :called
    assert_received :called
    refute_received :called
  end

  test "connection and receive timeouts in analysis do not trigger a translation", %{
    context: context
  } do
    for reason <- [:timeout, :connect_timeout, :etimedout] do
      post = fn _, _, _, _ ->
        send(self(), :called)
        {:error, %HTTPoison.Error{reason: reason}}
      end

      assert {:error, error} = AiDecision.analyze(context, http_post: post)
      assert error =~ "OLLAMA_TIMEOUT_MS"
      refute error =~ "OLLAMA_TRANSLATION_TIMEOUT_MS"
      assert_received :called
      refute_received :called
    end
  end

  test "worker budget covers both configured requests and connection overhead" do
    assert AiDecision.max_duration_ms([]) == 190_000

    assert AiDecision.max_duration_ms(timeout_ms: 180_000, translation_timeout_ms: 90_000) ==
             280_000
  end

  test "prompt avoids duplicate headlines and generation budget remains configurable", %{
    context: context
  } do
    Application.put_env(:gold_backend, :ollama, num_predict: 950)

    news =
      for i <- 1..15,
          do: %{
            title: "English headline #{i}",
            title_vi: "Tiêu đề tiếng Việt #{i}",
            published_at: nil
          }

    post = fn _, body, _, options ->
      send(self(), {:request, Jason.decode!(body), options})
      response("wait", @vietnamese)
    end

    assert {:ok, :wait, _} = AiDecision.analyze(%{context | news: news}, http_post: post)
    assert_received {:request, request, options}
    assert request["options"]["num_predict"] == 950
    assert request["prompt"] =~ "Tiêu đề tiếng Việt 6"
    refute request["prompt"] =~ "Tiêu đề tiếng Việt 7"
    refute request["prompt"] =~ "English headline"
    assert options[:timeout] == 5_000
  end

  test "language repair can read a complete JSON answer after thinking and a code fence", %{
    context: context
  } do
    post = fn _, body, _, _ ->
      case get_in(Jason.decode!(body), ["format", "properties", "action", "enum"]) do
        ["wait"] ->
          response("wait", @vietnamese)

        _ ->
          json = Jason.encode!(%{action: "wait", reason: @english})

          {:ok,
           %HTTPoison.Response{
             status_code: 200,
             body:
               Jason.encode!(%{response: "<think>internal text</think>\n```json\n#{json}\n```"})
           }}
      end
    end

    assert {:ok, :wait, @vietnamese} = AiDecision.analyze(context, http_post: post)
  end

  test "decomposed Vietnamese accents are normalized before validation" do
    reason = String.duplicate("Giá trên SMA20, MACD dương, chờ xác nhận thêm trước khi mua. ", 3)

    assert {:ok, :wait, normalized} =
             AiDecision.parse(%{"action" => "wait", "reason" => String.normalize(reason, :nfd)})

    assert normalized == reason |> String.normalize(:nfc) |> String.trim()
  end

  defp response(action, reason) do
    {:ok,
     %HTTPoison.Response{
       status_code: 200,
       body:
         Jason.encode!(%{
           response: Jason.encode!(%{action: action, reason: reason}),
           done_reason: "stop"
         })
     }}
  end
end

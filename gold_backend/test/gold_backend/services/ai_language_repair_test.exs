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
    Application.put_env(:gold_backend, :ollama, timeout_ms: 1_000)

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

  test "repairs English once with the original action and remaining time budget", %{
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
    assert_received {:request, _, first_options}
    assert_received {:request, repair, repair_options}
    assert repair["prompt"] =~ @english
    assert repair_options[:recv_timeout] <= first_options[:recv_timeout]
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

  test "no repair request starts after the original time budget expires", %{context: context} do
    Application.put_env(:gold_backend, :ollama, timeout_ms: 10)

    post = fn _, _, _, _ ->
      send(self(), :called)
      Process.sleep(20)
      response("wait", @english)
    end

    assert {:error, reason} = AiDecision.analyze(context, http_post: post)
    assert reason =~ "quá thời gian"
    assert_received :called
    refute_received :called
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

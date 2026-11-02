defmodule GoldBackend.Services.EntryAlertTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Services.{EntryAlert, AiDecision}
  @now ~U[2026-11-02 06:01:00Z]
  @brief %{
    "reason" =>
      "Cấu trúc giảm đã được xác nhận tại vùng cản, trong khi động lượng chưa đồng thuận.",
    "opportunity" => "Giá có thể tiếp tục giảm về vùng hỗ trợ nếu áp lực bán được duy trì.",
    "risk" => "Giao dịch ngược xu hướng lớn nên có thể bật lại; chưa có dữ liệu tin tức."
  }
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(GoldBackend.Repo)
    :ok
  end

  defp context do
    %{
      analysis_at: @now,
      plan: %{
        setup_id: "brief-test",
        action: "sell",
        trade_plan_status: "READY_TO_ENTER",
        entry: 3916.0,
        stop_loss: 3918.5,
        take_profit: 3911.0
      }
    }
  end

  defp run(extra) do
    c = context()

    EntryAlert.publish(
      %{cfd_plan: c.plan, entry_context: c},
      Keyword.merge(
        [
          brief: fn _ ->
            send(self(), :ai_done)
            {:ok, @brief}
          end,
          quote: fn ->
            assert_received :ai_done
            {:ok, %{price: 3915.9, timestamp: @now}}
          end,
          clock: fn -> @now end,
          revalidate: fn c, q, _ -> %{c | plan: %{c.plan | entry: q.price}} end,
          snapshot: fn c -> %{cfd_plan: c.plan} end,
          publish: fn s ->
            send(self(), {:sent, s})
            :ok
          end
        ],
        extra
      )
    )
  end

  test "AI wording is followed by fresh quote and revalidation before delivery" do
    assert :ok = run([])
    assert_received {:sent, %{cfd_plan: %{entry: 3915.9}, entry_brief: @brief}}
  end

  test "price moved, failed quote, expired context and changed setup do not send" do
    for options <- [
          [quote: fn -> {:error, :stale_quote} end],
          [clock: fn -> DateTime.add(@now, 900) end],
          [
            revalidate: fn c, _, _ ->
              %{c | plan: %{c.plan | trade_plan_status: "PRICE_MOVED"}}
            end
          ],
          [revalidate: fn c, _, _ -> %{c | plan: %{c.plan | setup_id: "other"}} end],
          [revalidate: fn c, _, _ -> %{c | plan: %{c.plan | stop_loss: 3919.0}} end]
        ] do
      assert {:error, :entry_alert_not_ready} = run(options)
      refute_received {:sent, _}
    end
  end

  test "failed AI does not mark delivery, allowing next evaluation to retry" do
    assert {:error, :entry_alert_not_ready} = run(brief: fn _ -> {:error, :timeout} end)
    refute_received {:sent, _}
    assert :ok = run([])
    assert_received {:sent, _}
  end

  test "brief rejects thinking, missing sections and model invented price levels" do
    assert :ok = AiDecision.validate_brief(@brief)

    for value <- [
          "<think>nội dung suy luận nội bộ</think>",
          "Giá bán dự kiến tại mức 3916 và mục tiêu thấp hơn.",
          "thinking nội dung suy luận"
        ] do
      assert {:error, _} = AiDecision.validate_brief(Map.put(@brief, "reason", value))
    end

    assert {:error, _} = AiDecision.validate_brief(Map.delete(@brief, "risk"))
  end

  test "AI receives only two UTC days of news, with thinking disabled" do
    c =
      Map.merge(context(), %{
        indicators: %{},
        events: [],
        news: [
          %{title: "Tin mới", published_at: "2026-11-02T05:00:00Z"},
          %{title: "Tin hôm qua", published_at: "2026-11-01T00:00:00Z"},
          %{title: "OLD_NEWS", published_at: "2026-10-31T23:59:59Z"},
          %{title: "FUTURE_NEWS", published_at: "2026-11-03T00:00:00Z"}
        ]
      })

    post = fn _, body, _, options ->
      request = Jason.decode!(body)
      assert request["think"] == false
      assert options[:recv_timeout] == 15_000
      assert request["prompt"] =~ "Tin mới"
      assert request["prompt"] =~ "Tin hôm qua"
      refute request["prompt"] =~ "OLD_NEWS"
      refute request["prompt"] =~ "FUTURE_NEWS"

      {:ok,
       %HTTPoison.Response{
         status_code: 200,
         body: Jason.encode!(%{response: Jason.encode!(@brief), thinking: "PRIVATE_REASONING"})
       }}
    end

    assert {:ok, @brief} = AiDecision.entry_brief(c, now: @now, http_post: post)
  end
end

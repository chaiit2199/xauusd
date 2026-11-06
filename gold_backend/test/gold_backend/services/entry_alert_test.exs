defmodule GoldBackend.Services.EntryAlertTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Services.{EntryAlert, AiDecision, EntryBriefCache}
  @now ~U[2026-11-02 06:01:00Z]
  @brief %{
    "reason" =>
      "Cấu trúc giảm đã được xác nhận tại vùng cản, trong khi động lượng chưa đồng thuận.",
    "opportunity" => "Giá có thể tiếp tục giảm về vùng hỗ trợ nếu áp lực bán được duy trì.",
    "risk" => "Giao dịch ngược xu hướng lớn nên có thể bật lại; chưa có dữ liệu tin tức."
  }
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(GoldBackend.Repo)
    EntryBriefCache.clear()
    :ok
  end

  defp context do
    %{
      analysis_at: @now,
      plan: %{
        setup_id: "brief-test",
        action: "sell",
        plan_status: "PLAN_READY",
        planning_action: "sell",
        reference_entry: 3916.0,
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
          brief: fn _ -> flunk("READY_TO_ENTER must not invoke AI") end,
          quote: fn ->
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

  test "cached AI wording still requires a fresh quote and revalidation" do
    EntryBriefCache.put(
      EntryAlert.cache_key(context(), @now),
      @brief,
      DateTime.add(@now, 60),
      @now
    )

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
      EntryBriefCache.clear()
      assert {:error, {_, _}} = run(options)
      refute_received {:sent, _}
    end
  end

  test "failed preparation cannot prevent a ready entry from sending without AI" do
    c = context()
    pending = %{c | plan: %{c.plan | action: "wait", trade_plan_status: "PLAN_READY"}}

    assert {:error, {:ai, :timeout}} =
             EntryAlert.publish(
               %{cfd_plan: pending.plan, entry_context: pending},
               clock: fn -> @now end,
               brief: fn _ -> {:error, :timeout} end
             )

    assert :ok = run([])
    assert_received {:sent, %{entry_brief: nil}}
  end

  test "invalid cached wording is omitted without preventing a valid entry" do
    EntryBriefCache.put(
      EntryAlert.cache_key(context(), @now),
      %{"reason" => "<think>"},
      DateTime.add(@now, 60),
      @now
    )

    assert :ok = run([])
    assert_received {:sent, %{entry_brief: nil}}
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
      assert options[:recv_timeout] == 90_000
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

  test "recognized numeric indicators are allowed, price and probability claims are rejected" do
    assert :ok =
             AiDecision.validate_brief(
               Map.put(
                 @brief,
                 "reason",
                 "M15 xác nhận giảm tại vùng cản, trong khi H1 và EMA20, RSI14 chưa đồng thuận."
               )
             )

    for reason <- [
          "Kỳ vọng giá giảm về 3900 sau khi chạm vùng cản phía trên.",
          "Cơ hội thắng khoảng 80% khi xu hướng tiếp tục giảm."
        ] do
      assert {:error, {:brief_field, "reason", :numeric_claim}} =
               AiDecision.validate_brief(Map.put(@brief, "reason", reason))
    end
  end

  test "PLAN_READY prepares once, READY_TO_ENTER reuses the brief and still fetches a quote" do
    live = context()
    pending = %{live | plan: %{live.plan | action: "wait", trade_plan_status: "PLAN_READY"}}

    options = [
      clock: fn -> @now end,
      brief: fn _ ->
        send(self(), :prepared_ai)
        {:ok, @brief}
      end,
      quote: fn -> flunk("preparing a plan must not send or fetch an entry quote") end
    ]

    assert :prepared =
             EntryAlert.publish(%{cfd_plan: pending.plan, entry_context: pending}, options)

    assert_received :prepared_ai
    assert EntryAlert.cache_key(pending, @now) == EntryAlert.cache_key(live, @now)

    assert :ok =
             run(
               brief: fn _ -> flunk("must reuse prepared brief") end,
               quote: fn ->
                 send(self(), :fresh_quote)
                 {:ok, %{price: 3915.9, timestamp: @now}}
               end
             )

    assert_received :fresh_quote
    assert_received {:sent, %{entry_brief: @brief}}
  end

  test "cache invalidates for new candles, news, levels, and expires at the candle boundary" do
    c = context()
    key = EntryAlert.cache_key(c, @now)

    refute key ==
             EntryAlert.cache_key(
               %{c | analysis_at: DateTime.add(@now, 900)},
               DateTime.add(@now, 900)
             )

    refute key == EntryAlert.cache_key(%{c | plan: %{c.plan | stop_loss: 3919.0}}, @now)

    refute key ==
             EntryAlert.cache_key(
               Map.put(c, :news, [%{title: "Tin mới", published_at: @now}]),
               @now
             )

    expiry = ~U[2026-11-02 06:15:00Z]
    EntryBriefCache.put(key, @brief, expiry, @now)
    assert {:ok, @brief} = EntryBriefCache.get(key, DateTime.add(expiry, -1))
    assert :miss = EntryBriefCache.get(key, expiry)
  end

  test "AI timeout configuration and failure reason are separate from full analysis" do
    old = Application.get_env(:gold_backend, :ollama, [])
    on_exit(fn -> Application.put_env(:gold_backend, :ollama, old) end)

    Application.put_env(
      :gold_backend,
      :ollama,
      Keyword.merge(old,
        entry_brief_timeout_ms: 42_000,
        entry_brief_num_predict: 320,
        timeout_ms: 300_000
      )
    )

    post = fn _, body, _, opts ->
      assert opts[:recv_timeout] == 42_000
      assert Jason.decode!(body)["options"]["num_predict"] == 320
      {:error, %HTTPoison.Error{reason: :timeout}}
    end

    assert {:error, :entry_brief_timeout} =
             AiDecision.entry_brief(context(), now: @now, http_post: post)
  end

  test "invalid JSON and token exhaustion have distinct diagnostic reasons" do
    for {body, expected} <- [
          {%{response: "broken"}, :entry_brief_json},
          {%{response: ""}, :entry_brief_empty},
          {%{response: "{}", done_reason: "length"}, :entry_brief_truncated}
        ] do
      post = fn _, _, _, _ ->
        {:ok, %HTTPoison.Response{status_code: 200, body: Jason.encode!(body)}}
      end

      assert {:error, ^expected} = AiDecision.entry_brief(context(), now: @now, http_post: post)
    end
  end

  test "diagnostics identify AI, quote, context and revalidation stages" do
    for {opts, stage} <- [
          {[quote: fn -> {:error, :stale_quote} end], :quote},
          {[clock: fn -> DateTime.add(@now, 900) end], :context},
          {[
             revalidate: fn c, _, _ ->
               %{c | plan: %{c.plan | trade_plan_status: "WAIT_RETEST"}}
             end
           ], :revalidation}
        ] do
      EntryBriefCache.clear()
      log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, {^stage, _}} = run(opts) end)
      assert log =~ ~s("stage":"#{stage}")
      refute_received {:sent, _}
    end
  end

  test "ready entry sends while plan AI is still running" do
    parent = self()
    live = context()
    pending = %{live | plan: %{live.plan | action: "wait", trade_plan_status: "PLAN_READY"}}

    prep =
      Task.async(fn ->
        receive do
          :go -> :ok
        end

        EntryAlert.publish(%{cfd_plan: pending.plan, entry_context: pending},
          clock: fn -> @now end,
          brief: fn _ ->
            send(parent, :ai_started)

            receive do
              :finish_ai -> {:ok, @brief}
            end
          end
        )
      end)

    Ecto.Adapters.SQL.Sandbox.allow(GoldBackend.Repo, self(), prep.pid)
    send(prep.pid, :go)
    assert_receive :ai_started

    ready =
      Task.async(fn ->
        receive do
          :go -> :ok
        end

        EntryAlert.publish(%{cfd_plan: live.plan, entry_context: live},
          clock: fn -> @now end,
          brief: fn _ ->
            send(parent, :duplicate_ai)
            {:ok, @brief}
          end,
          quote: fn ->
            send(parent, :fresh_quote)
            {:ok, %{price: 3915.9, timestamp: @now}}
          end,
          revalidate: fn c, q, _ -> %{c | plan: %{c.plan | entry: q.price}} end,
          snapshot: fn c -> %{cfd_plan: c.plan} end,
          publish: fn s ->
            send(parent, {:sent, s})
            :ok
          end
        )
      end)

    Ecto.Adapters.SQL.Sandbox.allow(GoldBackend.Repo, self(), ready.pid)
    send(ready.pid, :go)
    assert :ok = Task.await(ready)
    assert_received :fresh_quote
    assert_received {:sent, %{entry_brief: nil}}
    refute_received :duplicate_ai
    send(prep.pid, :finish_ai)
    assert :prepared = Task.await(prep)
    refute_received {:sent, _}
  end

  test "brief payload is bounded and normalizes news timestamps across month boundaries" do
    now = ~U[2026-11-01 06:00:00Z]

    news =
      for i <- 0..9,
          do: %{
            title: String.duplicate("Tin thực tế ", 40),
            title_vi: "",
            published_at: DateTime.add(now, -i * 3600)
          }

    input =
      AiDecision.entry_brief_input(
        Map.merge(context(), %{
          news: news,
          indicators: %{rsi_14: 50, giant: String.duplicate("x", 1000)}
        }),
        now
      )

    assert length(input.news) == 6
    assert hd(input.news).published_at == "2026-11-01T06:00:00Z"
    assert Enum.all?(input.news, &(String.length(&1.title) == 180))
    refute Map.has_key?(input.indicators, :giant)
    refute Map.has_key?(input.setup, :checks)
  end

  test "a valid brief does not produce the legacy action/reason decoder warning" do
    post = fn _, _, _, _ ->
      {:ok,
       %HTTPoison.Response{
         status_code: 200,
         body: Jason.encode!(%{response: Jason.encode!(@brief)})
       }}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, @brief} = AiDecision.entry_brief(context(), now: @now, http_post: post)
      end)

    refute log =~ "invalid output"
  end
end

defmodule GoldBackend.Services.PlanFirstTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Repo

  alias GoldBackend.Services.{
    StrategyPlan,
    SetupLifecycle,
    SetupRegistry,
    PlanPublisher,
    TelegramNotifier
  }

  @now ~U[2026-11-02 02:00:35Z]
  @i %{current_price: 3913.0, sma_20: 3910.0, macd: 1.0, rsi_14: 75.0, stochastic_k: 85.0}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    prior =
      for key <- [:telegram, :notification_hours],
          into: %{},
          do: {key, Application.get_env(:gold_backend, key)}

    Application.put_env(:gold_backend, :telegram, bot_token: "test-token", chat_id: "test-chat")
    Application.put_env(:gold_backend, :notification_hours, "all")

    on_exit(fn ->
      Enum.each(prior, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:gold_backend, key),
          else: Application.put_env(:gold_backend, key, value)
      end)
    end)

    :ok
  end

  defp setup_plan do
    SetupLifecycle.identify(%{
      action: "sell",
      state: "ready",
      blocked: false,
      setup_kind: "countertrend_reversal",
      entry: 3913.0,
      stop_loss: 3915.5,
      take_profit: 3908.0,
      take_profit_2: 3905.0,
      atr: 2.0,
      zone: %{id: "m15_resistance", low: 3912.0, mid: 3913.0, high: 3914.0},
      invalidation_price: 3914.0,
      candle_closed_at: "2026-11-02T02:00:00Z",
      reason: "Synthetic confirmed M15 SELL",
      barrier: nil,
      timeframe_seconds: 900
    })
  end

  defp build(setup, extra \\ []) do
    StrategyPlan.build(
      @i,
      setup.entry,
      Keyword.merge(
        [
          bias: %{side: "buy", reason: "H1 tăng", data_status: "ready"},
          m15_setup: setup,
          as_of: @now,
          calendar_status: "ok",
          calendar_valid_until: DateTime.to_iso8601(DateTime.add(@now, 600))
        ],
        extra
      )
    )
  end

  defp snapshot(plan),
    do: %{
      cfd_plan: plan,
      ai_action: "wait",
      ai_status: "error",
      ai_insight: nil,
      calendar_valid_until: DateTime.to_iso8601(DateTime.add(@now, 600)),
      signal_valid_until:
        if(plan.action != "wait", do: DateTime.to_iso8601(DateTime.add(@now, 120)))
    }

  defp post(_url, body, _headers, _opts) do
    send(self(), {:telegram, Jason.decode!(body)["text"]})
    {:ok, %HTTPoison.Response{status_code: 200, body: ~s({"ok":true})}}
  end

  test "confirmed countertrend SELL publishes a plan at 3913 without waiting for quote or AI" do
    p = build(setup_plan())
    assert p.plan_status == "PLAN_READY" and p.trade_plan_status == "PLAN_READY"
    assert p.planning_action == "sell" and p.action == "wait"
    assert p.trade_direction_label == "countertrend SELL"
    assert p.h1_bias_label == "H1 BUY"
    assert Enum.all?(p.plan_checks, &(&1.status == "pass"))
    assert [{:ok, :sent}] = PlanPublisher.publish(snapshot(p), now: @now, http_post: &post/4)
    assert_receive {:telegram, text}
    assert text =~ "PLAN_READY" and text =~ "countertrend SELL" and text =~ "3913"
    assert text =~ "chưa phải xác nhận vào ngay"
  end

  test "fresh quote alone advances eligible plan, keeping the frozen SL/TP" do
    s = setup_plan()
    pending = build(s)
    live = build(s, quote: %{price: 3912.9, timestamp: @now})
    assert live.action == "sell" and live.trade_plan_status == "READY_TO_ENTER"
    assert live.take_profit == pending.take_profit and live.stop_loss == pending.stop_loss
    # A 4.9-price remaining reward does not impose an artificial five-price gate.
    assert live.take_distance == 4.9
    PlanPublisher.publish(snapshot(pending), now: @now, http_post: &post/4)
    assert_receive {:telegram, _}

    assert [{:ok, :already_sent}, {:ok, :sent}] =
             PlanPublisher.publish(snapshot(live), now: @now, http_post: &post/4)

    assert_receive {:telegram, text}
    assert text =~ "READY_TO_ENTER"
    PlanPublisher.publish(snapshot(live), now: @now, http_post: &post/4)
    refute_receive {:telegram, _}
  end

  test "RR 1.2..1.5 and structural SL 3..5 are warnings, never stretched levels" do
    s = %{setup_plan() | stop_loss: 3916.3}
    p = build(s)
    assert p.plan_status == "PLAN_READY"
    assert p.stop_loss == 3916.3 and p.take_profit == 3908.0
    assert Enum.any?(p.soft_flags, &String.contains?(&1, "SL rộng"))
    assert Enum.any?(p.soft_flags, &String.contains?(&1, "R:R tham chiếu"))
  end

  test "hard reference rules and red news cannot publish a plan" do
    s = setup_plan()

    for changed <- [
          %{s | stop_loss: 3920.0},
          %{s | stop_loss: 3912.0},
          %{s | stop_loss: 3917.8},
          %{s | invalidation_price: nil},
          %{s | id: nil},
          %{s | blocked: true, state: "data_unavailable"},
          %{s | blocked: true, state: "invalidated"},
          %{s | expires_at: DateTime.to_iso8601(@now)}
        ] do
      p = build(changed)
      refute p.plan_status == "PLAN_READY", inspect(changed)
      assert p.action == "wait"
    end

    for extra <- [
          [calendar_status: "unavailable"],
          [blocking_event: %{title: "CPI"}],
          [warmup: true]
        ] do
      p = build(s, extra)
      assert p.planning_action == "wait"

      assert [] =
               PlanPublisher.publish(snapshot(p),
                 now: @now,
                 http_post: fn _, _, _, _ -> flunk("blocked plan sent") end
               )
    end
  end

  test "price movement retains plan, target hit ends it, stale target quotes cannot kill it" do
    s = setup_plan()
    moved = build(s, quote: %{price: 3911.0, timestamp: @now})
    assert moved.plan_status == "PLAN_READY" and moved.trade_plan_status == "PRICE_MOVED"
    assert moved.action == "wait"
    dead = build(s, quote: %{price: 3899.0, timestamp: @now})
    assert dead.plan_status == "INVALIDATED" and dead.action == "wait"
    stale = build(s, quote: %{price: 3899.0, timestamp: DateTime.add(@now, -121)})
    assert stale.plan_status == "PLAN_READY" and stale.current_entry_status == "unchecked"

    assert {:error, _} =
             TelegramNotifier.notify_event(snapshot(stale), "READY_TO_ENTER",
               now: @now,
               http_post: &post/4
             )
  end

  test "failed Telegram delivery is retried, and success is durable rather than tied to process memory" do
    data = snapshot(build(setup_plan()))
    fail = fn _, _, _, _ -> {:error, %HTTPoison.Error{reason: :timeout}} end
    assert [{:ok, {:error, _}}] = PlanPublisher.publish(data, now: @now, http_post: fail)
    assert [{:ok, :sent}] = PlanPublisher.publish(data, now: @now, http_post: &post/4)
    assert_receive {:telegram, _}
    assert [{:ok, :already_sent}] = PlanPublisher.publish(data, now: @now, http_post: &post/4)
    refute_receive {:telegram, _}
  end

  test "terminal setup is skipped and a different valid confirmation is selected in the same scan" do
    s = setup_plan()
    PlanPublisher.publish(snapshot(build(s)), now: @now, http_post: &post/4)
    assert_receive {:telegram, _}
    old = SetupLifecycle.validate_quote(s, %{price: 3899.0, timestamp: @now}, @now)

    alternative =
      s |> Map.put(:zone, %{s.zone | id: "new_m15_resistance"}) |> SetupLifecycle.identify()

    selected =
      SetupRegistry.resolve(
        Map.put(old, :alternatives, [alternative]),
        [],
        %{side: "buy"},
        @now,
        []
      )

    assert selected.id == alternative.id and selected.state == "ready"
    # A delayed task carrying the old PLAN_READY cannot resurrect it.
    assert [{:ok, :sent}] =
             PlanPublisher.publish(snapshot(build(s)), now: @now, http_post: &post/4)

    assert_receive {:telegram, terminal}
    assert terminal =~ "INVALIDATED"
    refute terminal =~ "PLAN_READY"

    assert [] =
             PlanPublisher.publish(
               snapshot(build(%{s | id: "never-published", state: "invalidated", blocked: true})),
               now: @now,
               http_post: &post/4
             )
  end
end

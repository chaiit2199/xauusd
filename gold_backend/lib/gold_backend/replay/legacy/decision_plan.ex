defmodule GoldBackend.Replay.Legacy.DecisionPlan do
  @moduledoc "User-facing structural plan, including the feasible entry interval and explicit cost basis."
  alias GoldBackend.Replay.Legacy.StrategyPolicy

  alias GoldBackend.Replay.Legacy.StrategyPolicy

  def build(plan, setup, indicators) do
    confirmed = is_binary(Map.get(setup, :id))
    zone = Map.get(setup, :zone) || watch_zone(Map.get(setup, :zones, []), plan.lean, plan.entry)
    entry_zone = if confirmed, do: entry_zone(setup, plan.spread), else: zone_range(zone)
    target = Map.get(setup, :take_profit)
    stop = Map.get(setup, :stop_loss)
    barrier = Map.get(setup, :barrier)

    reference_rr =
      if confirmed and is_number(target) and is_number(setup.entry) and
           valid_price?(setup, setup.entry),
         do:
           round2(
             GoldBackend.Replay.Legacy.EntryQuality.assess(setup, setup.entry, plan.spread).reward_risk
           )

    live = Map.get(plan, :price_basis) == "live_quote"

    %{
      side: plan.lean,
      source: "Gold API · XAU/USD · Giá tham chiếu",
      reference_entry: if(confirmed, do: setup.entry),
      reference_at: Map.get(setup, :formed_at),
      reference_reward_risk: reference_rr,
      current_entry_status: Map.get(plan, :current_entry_status, "unchecked"),
      current_entry: if(live, do: plan.entry),
      current_quote_at: Map.get(plan, :quote_at),
      technical_context: Map.get(setup, :technical_context),
      supporting_evidence:
        GoldBackend.Replay.Legacy.MarketStructure.evidence(
          Map.get(setup, :technical_context),
          plan.lean,
          zone
        ),
      candidate_count: Map.get(setup, :candidate_count, 0),
      branches: Map.get(setup, :branches, []),
      branches_at: Map.get(setup, :candle_closed_at),
      setup_kind: Map.get(setup, :setup_kind),
      entry_admission: Map.get(plan, :entry_admission),
      entry_policy: "rr_constrained",
      cost_sensitivity: cost_sensitivity(setup, plan.entry, plan.spread),
      evidence: [
        plan.bias.reason,
        "H1 đóng #{indicators.current_price}; SMA20 #{indicators.sma_20}; MACD #{indicators.macd}.",
        if(zone,
          do: "Vùng #{zone_name(zone.id)}: #{round2(zone.low)}–#{round2(zone.high)}.",
          else: "Chưa xác định được vùng giá phù hợp."
        ),
        setup.reason
      ],
      entry_zone: entry_zone,
      entry_zone_kind: if(confirmed, do: "eligible", else: "watch"),
      confirmation:
        if(plan.action in ["buy", "sell"],
          do: "M15 đã xác nhận; các điều kiện phát tín hiệu hiện đều đạt.",
          else: plan.block_reason || setup.reason
        ),
      trigger:
        "Một mẫu M15 hợp lệ là đủ. Lệnh hồi cần cùng hướng H1; breakout–retest được xét cả khi H1 trung tính nhưng đủ dữ liệu. Giá mới, lịch tin, điểm vô hiệu và R:R vẫn bắt buộc.",
      stop_loss: stop,
      stop_reason:
        if(is_number(stop),
          do: "Ngoài cực trị nến xác nhận và mép vùng giá, cộng đệm 0,10 ATR M15.",
          else: "Chờ nến xác nhận để cố định điểm vô hiệu và SL."
        ),
      take_profit: target,
      target_reason:
        if(barrier && is_number(target),
          do:
            "Mép gần vùng #{zone_name(barrier.id)} (#{round2(barrier.low)}–#{round2(barrier.high)}), đã biết trước nến xác nhận.",
          else: "Chưa có vùng cản đã xác nhận để chốt TP."
        ),
      reward_risk:
        if(live and confirmed and is_number(target) and valid_price?(setup, plan.entry),
          do:
            round2(
              GoldBackend.Replay.Legacy.EntryQuality.assess(setup, plan.entry, plan.spread).reward_risk
            ),
          else: nil
        ),
      reward_risk_basis:
        if(live,
          do: "R:R tại báo giá mới của nguồn; đánh giá lại khi giá thay đổi.",
          else:
            "Chưa kiểm tra entry hiện tại. R:R tham chiếu dùng giá đóng nến xác nhận; không chứng minh còn vào được."
        ),
      cost: %{
        spread: plan.spread,
        source: plan.spread_source,
        description:
          if(plan.spread_source == "assumed",
            do: "Spread giả định #{round2(plan.spread)} USD/oz; chưa gồm phí và trượt giá.",
            else: "Spread quan sát #{round2(plan.spread)} USD/oz; chưa gồm phí và trượt giá."
          )
      },
      formed_at: Map.get(setup, :formed_at),
      expires_at: Map.get(setup, :expires_at),
      cancellation: [
        "Hết hai nến M15 từ xác nhận.",
        if(Map.get(setup, :setup_kind) == "breakout_retest" and is_number(stop),
          do:
            "Giá chạm SL #{round2(stop)} hoặc nến M15 đóng #{if setup.action == "buy", do: "dưới hoặc bằng", else: "trên hoặc bằng"} điểm vô hiệu #{round2(Map.get(setup, :invalidation_price) || if(setup.action == "buy", do: zone.low, else: zone.high))}.",
          else: "Giá phá vùng cấu trúc hoặc chạm SL của setup."
        ),
        "Giá chạm mục tiêu trước khi sử dụng tín hiệu.",
        "H1 không còn phù hợp với nhánh setup hoặc setup đi qua cửa sổ tin quan trọng.",
        "Giá/dữ liệu quá hạn: tạm dừng và đánh giá lại."
      ],
      simulation_seconds: StrategyPolicy.simulation_seconds()
    }
  end

  def entry_zone(%{take_profit: target} = s, cost) when is_number(target) do
    r = StrategyPolicy.min_reward_risk()
    # The 0.30 ATR band is advisory in v6. The nearest barrier still constrains
    # the interval even if a future target policy chooses a more distant TP.
    barrier = Map.get(s, :barrier)

    target =
      if barrier do
        if s.action == "buy", do: min(target, barrier.low), else: max(target, barrier.high)
      else
        target
      end

    breakout = Map.get(s, :setup_kind) == "breakout_retest"

    if s.action == "buy" do
      low = if breakout, do: s.stop_loss + 0.01, else: max(s.stop_loss + 0.01, s.zone.low + 0.01)

      high =
        Enum.min([
          s.stop_loss + StrategyPolicy.max_stop_atr() * s.atr,
          (target + r * s.stop_loss) / (1 + r) - cost
        ])

      range(low, high)
    else
      low =
        Enum.max([
          s.stop_loss - StrategyPolicy.max_stop_atr() * s.atr,
          (target + r * s.stop_loss) / (1 + r) + cost
        ])

      high =
        if breakout, do: s.stop_loss - 0.01, else: min(s.stop_loss - 0.01, s.zone.high - 0.01)

      range(low, high)
    end
  end

  def entry_zone(_, _), do: nil

  # A scenario for reviewing cost fragility, never an extra signal gate.
  defp cost_sensitivity(
         %{action: side, stop_loss: stop, take_profit: target} = setup,
         entry,
         cost
       )
       when side in ["buy", "sell"] and is_number(stop) and is_number(target) do
    if valid_price?(setup, entry) do
      risk = abs(entry - stop)
      reward = if side == "buy", do: target - entry, else: entry - target
      minimum = StrategyPolicy.min_reward_risk()

      %{
        stress_cost: round2(cost * 2),
        stress_reward_risk: round2((reward - cost * 2) / (risk + cost * 2)),
        max_cost_for_min_rr: round2((reward - minimum * risk) / (1 + minimum))
      }
    end
  end

  defp cost_sensitivity(_, _, _), do: nil

  defp range(low, high) do
    low = Float.ceil(low * 1.0, 2)
    high = Float.floor(high * 1.0, 2)
    if low <= high, do: %{low: low, high: high}, else: nil
  end

  defp zone_range(nil), do: nil
  defp zone_range(z), do: %{low: round2(z.low), high: round2(z.high)}

  defp watch_zone(zones, side, price) when side in ["buy", "sell"] do
    zones
    |> Enum.filter(fn z -> if side == "buy", do: z.low < price, else: z.high > price end)
    |> Enum.min_by(&abs(&1.mid - price), fn -> nil end)
  end

  defp watch_zone(_, _, _), do: nil

  defp valid_price?(s, p),
    do:
      if(s.action == "buy",
        do: p > s.stop_loss and p < s.take_profit,
        else: p < s.stop_loss and p > s.take_profit
      )

  defp zone_name("m15_swing_high" <> _), do: "đỉnh M15 đã xác nhận"
  defp zone_name("m15_swing_low" <> _), do: "đáy M15 đã xác nhận"
  defp zone_name("breakout_" <> _), do: "vùng retest sau phá vỡ M15"
  defp zone_name("sma20_h1"), do: "SMA20 H1"
  defp zone_name("aoi_high_h1"), do: "AOI trên H1 · cực trị thân 50 nến + ATR14"
  defp zone_name("aoi_low_h1"), do: "AOI dưới H1 · cực trị thân 50 nến − ATR14"
  defp zone_name("previous_day_high"), do: "đỉnh ngày trước"
  defp zone_name("previous_day_low"), do: "đáy ngày trước"
  defp zone_name("swing_high" <> _), do: "đỉnh H1 đã xác nhận"
  defp zone_name("swing_low" <> _), do: "đáy H1 đã xác nhận"
  defp zone_name(id), do: id
  defp round2(n), do: Float.round(n * 1.0, 2)
end

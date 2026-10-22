defmodule GoldBackend.Services.NewsBiasTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.NewsBias

  test "scores bullish gold headlines" do
    bias =
      NewsBias.assess([
        %{title: "Gold rallies as Fed signals rate cut", source: "Kitco", title_vi: nil},
        %{title: "Safe-haven demand lifts bullion", source: "FXStreet", title_vi: nil}
      ])

    assert bias.tone == :gold_bullish
    assert bias.bullish >= 2
    assert bias.digest =~ "ủng hộ vàng"
  end

  test "marks high-impact USD prints without treating WGC forecasts as trade fuel" do
    now = ~U[2026-10-22 06:30:00Z]

    bias =
      NewsBias.assess(
        [
          %{
            title: "US CPI due today",
            source: "Investing",
            title_vi: nil,
            published_at: ~U[2026-10-22 06:00:00Z]
          },
          %{
            title: "World Gold Council 2027 forecast",
            source: "WGC",
            title_vi: nil
          }
        ],
        now
      )

    assert bias.high_impact
    assert bias.trade_block
    assert Enum.any?(bias.headlines, &String.contains?(&1, "tác động mạnh"))
    assert Enum.any?(bias.headlines, &String.contains?(&1, "dài hạn"))
  end

  test "old high-impact headlines remain context but no longer lock trading" do
    bias =
      NewsBias.assess(
        [
          %{
            title: "Fed decision moves gold",
            source: "Kitco",
            title_vi: nil,
            published_at: ~U[2026-10-22 03:00:00Z]
          }
        ],
        ~U[2026-10-22 06:30:00Z]
      )

    assert bias.high_impact
    refute bias.trade_block
    assert bias.digest =~ "ngoài cửa sổ"
  end
end

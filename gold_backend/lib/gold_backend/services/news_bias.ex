defmodule GoldBackend.Services.NewsBias do
  @moduledoc """
  Lightweight tone of recent gold headlines for the H1 ticket and AI note.

  Headlines are scored by keywords. Forecast/WGC pieces stay context-only.
  High-impact USD prints (CPI, NFP, FOMC) raise risk but do not flip the side.
  """

  @bullish ~r/\b(rate cut|dovish|weak(er)? dollar|safe[- ]haven|geopolitic|rally|surge|buys? gold|gold demand|lower yields?|soft(er)? (cpi|inflation)|ceasefire|risk[- ]off)\b|cắt giảm lãi|đôla yếu|trú ẩn|cầu vàng|lạm phát dịu/i

  @bearish ~r/\b(rate hike|hawkish|strong(er)? dollar|dxy|higher yields?|risk[- ]on|sells? gold|gold slump|hot (cpi|inflation)|payrolls? beat|jobs beat)\b|tăng lãi|đôla mạnh|lợi suất tăng|bán vàng|cpi nóng/i

  @high_impact ~r/\b(cpi|nfp|non[- ]?farm|fomc|fed\b|powell|payroll|ppi|lãi suất)\b/i

  @long_horizon ~r/20[2-9]\d|forecast|dự báo|world gold council|hội đồng vàng|\bwgc\b|ngân hàng trung ương.*năm/i

  def assess(articles) when is_list(articles) do
    scored =
      articles
      |> Enum.take(12)
      |> Enum.map(&score_article/1)

    bull = Enum.count(scored, &(&1.tone == :bullish))
    bear = Enum.count(scored, &(&1.tone == :bearish))
    high_impact = Enum.any?(scored, & &1.high_impact)

    tone =
      cond do
        bull > bear + 1 -> :gold_bullish
        bear > bull + 1 -> :gold_bearish
        bull > 0 or bear > 0 -> :mixed
        true -> :neutral
      end

    %{
      tone: tone,
      tone_label: tone_label(tone),
      bullish: bull,
      bearish: bear,
      high_impact: high_impact,
      headlines: Enum.map(scored, & &1.line),
      digest: digest(tone, bull, bear, high_impact, scored)
    }
  end

  def assess(_), do: assess([])

  defp score_article(article) do
    title =
      cond do
        is_binary(Map.get(article, :title_vi)) and article.title_vi != "" ->
          article.title_vi

        is_binary(Map.get(article, "title_vi")) and article["title_vi"] != "" ->
          article["title_vi"]

        is_binary(Map.get(article, :title)) ->
          article.title

        is_binary(Map.get(article, "title")) ->
          article["title"]

        true ->
          ""
      end

    source = Map.get(article, :source) || Map.get(article, "source") || "?"
    long? = Regex.match?(@long_horizon, title)
    high? = not long? and Regex.match?(@high_impact, title)

    tone =
      cond do
        long? -> :context
        Regex.match?(@bullish, title) and not Regex.match?(@bearish, title) -> :bullish
        Regex.match?(@bearish, title) and not Regex.match?(@bullish, title) -> :bearish
        true -> :neutral
      end

    %{
      tone: tone,
      high_impact: high?,
      line: "[#{bucket(tone, high?)} | #{source}] #{title}"
    }
  end

  defp bucket(:bullish, _), do: "ủng hộ vàng"
  defp bucket(:bearish, _), do: "đè vàng"
  defp bucket(:context, _), do: "dài hạn"
  defp bucket(_, true), do: "tác động mạnh"
  defp bucket(_, _), do: "dòng tin"

  defp tone_label(:gold_bullish), do: "Tin nghiêng ủng hộ vàng"
  defp tone_label(:gold_bearish), do: "Tin nghiêng đè vàng"
  defp tone_label(:mixed), do: "Tin trái chiều"
  defp tone_label(:neutral), do: "Tin trung tính / ít tín hiệu"

  defp digest(tone, bull, bear, high_impact, scored) do
    top =
      scored
      |> Enum.reject(&(&1.tone == :neutral and not &1.high_impact))
      |> Enum.take(4)
      |> Enum.map_join("; ", & &1.line)

    base = "#{tone_label(tone)} (ủng hộ #{bull}, đè #{bear})."

    impact =
      if high_impact,
        do: " Có tin USD tác động mạnh — ưu tiên đứng ngoài quanh giờ ra số.",
        else: ""

    if top == "", do: base <> impact, else: base <> impact <> " Tiêu điểm: #{top}"
  end
end

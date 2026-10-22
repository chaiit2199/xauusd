defmodule GoldBackend.Services.OllamaAnalyzer do
  @moduledoc """
  Asks a local Ollama model for a Vietnamese XAU/USD note.

  Defaults target a CPU VPS running `deepseek-r1:1.5b`:
  the HTTP socket waits 120s, the prompt asks for a short report grounded in
  the live H1 ticket, indicators, and scored headlines, and `num_predict`
  caps the answer so the reasoning model can finish.
  `keep_alive` leaves the weights in RAM between refresh cycles.
  """

  alias GoldBackend.Services.TradePlan

  @default_timeout 120_000

  require Logger

  def analyze_market(indicators, news_list, price_history_count, plan, news_bias \\ nil) do
    config = Application.get_env(:gold_backend, :ollama, [])
    timeout = Keyword.get(config, :timeout_ms, @default_timeout)

    body =
      Jason.encode!(%{
        model: Keyword.get(config, :model, "deepseek-r1:1.5b"),
        prompt: build_prompt(indicators, news_list, price_history_count, plan, news_bias),
        stream: false,
        keep_alive: "30m",
        options: %{
          temperature: 0.1,
          top_p: 0.9,
          num_predict: 900,
          num_ctx: 4096
        }
      })

    options = [timeout: timeout, recv_timeout: timeout]

    case HTTPoison.post(endpoint(config), body, [{"Content-Type", "application/json"}], options) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        decode_success(resp_body)

      {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} ->
        Logger.warning("Commentary HTTP #{status}: #{truncate(resp_body)}")
        {:error, "Bộ diễn giải trả HTTP #{status}."}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("Commentary engine unavailable: #{inspect(reason)}")
        {:error, "Không kết nối được bộ diễn giải. Phiếu lệnh vẫn là quyết định chính."}

      {:error, reason} ->
        Logger.warning("Commentary engine failed: #{inspect(reason)}")
        {:error, "Không kết nối được bộ diễn giải. Phiếu lệnh vẫn là quyết định chính."}
    end
  end

  defp endpoint(config) do
    Keyword.get(config, :url, "http://localhost:11434/api/generate")
  end

  defp decode_success(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"response" => text}} when is_binary(text) ->
        present_response(text)

      {:ok, _} ->
        {:error, "Bộ diễn giải không trả nội dung."}

      {:error, reason} ->
        {:error, "Không đọc được diễn giải: #{inspect(reason)}"}
    end
  end

  def align({:ok, text}, plan) do
    cleaned = scrub(text)

    if contradicts?(cleaned, plan.action) do
      Logger.warning("Commentary contradicted the H1 ticket and was replaced.")
      {:ok, TradePlan.commentary(plan)}
    else
      {:ok, cleaned}
    end
  end

  def align({:error, _reason}, plan), do: {:error, TradePlan.commentary(plan)}

  defp present_response(text) do
    visible = text |> String.replace(~r/<think>.*?<\/think>/s, "") |> scrub()

    cond do
      visible != "" ->
        {:ok, visible}

      String.contains?(text, "<think>") ->
        {:error, "Bộ diễn giải chưa kịp viết kết luận trong thời gian cho phép."}

      true ->
        {:error, "Bộ diễn giải trả nội dung rỗng."}
    end
  end

  defp scrub(text) do
    text
    |> String.replace(~r/deepseek[-\w:\.]*/i, "")
    |> String.replace(~r/\bollama\b/i, "")
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.trim()
  end

  defp contradicts?(text, "wait") do
    recommends_entry?(text, "mua") or recommends_entry?(text, "buy") or
      recommends_entry?(text, "bán") or
      recommends_entry?(text, "sell")
  end

  defp contradicts?(text, "sell"),
    do: recommends_entry?(text, "mua") or recommends_entry?(text, "buy")

  defp contradicts?(text, "buy"),
    do: recommends_entry?(text, "bán") or recommends_entry?(text, "sell")

  defp contradicts?(_text, _action), do: false

  defp recommends_entry?(text, side) do
    Regex.match?(
      ~r/(khuyến nghị|định kiến|bias|kịch bản|vào lệnh)\s*[:\-–]?\s*(?!không |chờ |thiên về )#{side}\b/iu,
      text
    )
  end

  defp build_prompt(indicators, news_list, price_count, plan, news_bias) do
    news_text = format_news(news_list)
    bands = indicators.bollinger_bands
    pivot = indicators.pivot_level
    news_digest = news_bias_digest(news_bias)

    """
    Bạn là desk risk CFD vàng (XAUUSD), khung H1, chu kỳ nhận định 5 phút.
    Viết tiếng Việt, ngắn, không cảm xúc. Không nêu tên mô hình. Không viết phần suy luận.
    Bạn KHÔNG được đảo quyết định bên dưới. Không được đề xuất chiều lệnh khác.
    Bắt buộc bám số liệu và tin đã cho — cấm nhận định chung chung không trích dẫn.

    QUY TẮC
    - Không bắt đáy khi Giá < SMA20 và MACD < 0.
    - Stochastic ở đáy hoặc RSI < 35 trong xu hướng giảm là động lượng giảm, không phải lệnh mua.
    - Chỉ mua khi Giá > SMA20 và MACD > 0.
    - Chỉ số xung đột thì định kiến bắt buộc là: Không giao dịch.
    - Cắt lỗ đã chốt bằng 2 lần ATR H1. Không được nới cắt lỗ quá 5 lần ATR.
    - Chốt lời đã chốt bằng 2 lần khoảng cách cắt lỗ.
    - Tin dự báo năm, ngân hàng trung ương, Hội đồng Vàng chỉ là bối cảnh. Không dùng để vào lệnh trong ngày.
    - CPI, NFP, FOMC, Fed, DXY tác động mạnh: nhắc không vào lệnh 30 phút trước và sau tin.
    - Nếu phiếu ghi Không giao dịch, phần định kiến phải là đúng câu đó. Cấm viết Mua hoặc Bán như lệnh cần vào.
    - Nếu tin ngược hướng kỹ thuật, nói rõ xung đột và ưu tiên đứng ngoài / giảm size.

    QUYẾT ĐỊNH ĐÃ CHỐT
    - Trạng thái: #{plan.market_state}
    - Định kiến: #{plan.action_label}
    - Thiên hướng: #{plan.lean_label}
    - Giá: #{plan.entry}
    - Cắt lỗ: #{plan.stop_loss}
    - Chốt lời: #{plan.take_profit}
    - R:R sau spread: 1:#{plan.reward_risk_after_spread}
    - Rủi ro: #{plan.risk_score}/10
    - Lý do: #{plan.block_reason || plan.summary}
    - Giọng tin máy chấm: #{news_digest}

    DỮ LIỆU H1 (#{price_count} tick trong cửa sổ 5 ngày — đủ cho SMA20/EMA50)
    - Giá #{indicators.current_price} | SMA20 #{indicators.sma_20} | EMA50 #{indicators.ema_50}
    - RSI #{indicators.rsi_14} | MACD #{indicators.macd} | Stochastic #{indicators.stochastic_k}
    - Bollinger #{bands.lower} – #{bands.upper} | ATR #{indicators.atr_14}
    - Pivot #{pivot.p} | R1 #{pivot.r1} | S1 #{pivot.s1} | ROC #{indicators.roc_10}%

    TIN 3 NGÀY (đã gắn nhãn)
    #{news_text}

    VIẾT ĐÚNG 6 MỤC
    1. Xu hướng H1, trích đúng SMA/EMA/MACD từ bảng trên.
    2. Trạng thái: #{plan.market_state}. Nói rõ giá bám biên dưới là giảm tiếp diễn nếu đúng như vậy.
    3. Định kiến: #{plan.action_label}.
    4. Tin tức: chọn 1–2 tiêu đề cụ thể (hoặc nói rõ không có tin đáng kể) và giải thích ảnh hưởng ngắn hạn tới XAUUSD / USD.
    5. Mức đã chốt: vùng giá #{plan.entry}, cắt lỗ #{plan.stop_loss}, chốt lời #{plan.take_profit}. Không đổi các con số này.
    6. Rủi ro #{plan.risk_score}/10 và lý do giữ hoặc không vào lệnh trong 5 phút tới.
    """
  end

  defp news_bias_digest(%{digest: digest}) when is_binary(digest), do: digest
  defp news_bias_digest(_), do: "Chưa chấm được tin."

  defp format_news([]), do: "- Không có tin trong 3 ngày."

  defp format_news(news_list) do
    Enum.map_join(news_list, "\n", fn article ->
      title =
        if is_binary(article.title_vi) and article.title_vi != "",
          do: article.title_vi,
          else: article.title

      "- [#{news_bucket(title)} | #{article.source}] #{title}"
    end)
  end

  defp news_bucket(title) do
    cond do
      Regex.match?(
        ~r/20[2-9]\d|forecast|dự báo|ngân hàng|hội đồng vàng|world gold council|wgc/i,
        title
      ) ->
        "dài hạn, không vào lệnh H1"

      Regex.match?(~r/cpi|nfp|non-farm|fomc|fed|payroll|ppi|dxy|lãi suất/i, title) ->
        "tác động mạnh"

      true ->
        "dòng tin"
    end
  end

  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 280)
  defp truncate(other), do: inspect(other)
end

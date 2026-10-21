defmodule GoldBackend.Services.NewsCrawlerTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.NewsCrawler

  test "html parser keeps gold articles and drops navigation" do
    html = """
    <a href="/jeweler-resources">Calculate precious metals value right here on kitco today</a>
    <a href="/news/article/2026-10-20/gold-forecast">Gold price forecast climbs as the dollar softens ahead of the Fed</a>
    <a href="https://example.com/privacy">Privacy policy and cookie preferences for this website</a>
    """

    articles =
      NewsCrawler.parse_body("Kitco Gold", "https://www.kitco.com/news", html)

    assert length(articles) == 1
    assert hd(articles).title =~ "Gold price forecast"
    assert hd(articles).url == "https://www.kitco.com/news/article/2026-10-20/gold-forecast"
    assert hd(articles).source == "Kitco Gold"
  end

  test "card links drop the author and date glued to the headline" do
    html = """
    <a href="/commodities/gold/news/gold-forecast">Bruce PowersOct 20, 2026Gold (XAU/USD) Price Forecast: breakout puts bulls back in control</a>
    """

    [article] =
      NewsCrawler.parse_body("FXEmpire Gold", "https://www.fxempire.com/commodities/gold", html)

    assert article.title == "Gold (XAU/USD) Price Forecast: breakout puts bulls back in control"
  end

  test "rss parser keeps gold items only" do
    xml = """
    <?xml version="1.0"?>
    <rss><channel>
      <item>
        <title>Gold holds bid as the dollar slips before CPI</title>
        <link>https://www.marketwatch.com/story/gold-holds-bid</link>
        <pubDate>Wed, 21 Oct 2026 10:00:00 GMT</pubDate>
      </item>
      <item>
        <title>Local football club wins a friendly in extra time</title>
        <link>https://www.marketwatch.com/story/football-club</link>
      </item>
    </channel></rss>
    """

    articles = NewsCrawler.parse_body("MarketWatch Gold", "https://feeds.example/rss", xml)

    assert length(articles) == 1
    assert hd(articles).url == "https://www.marketwatch.com/story/gold-holds-bid"
    assert hd(articles).published_at == ~U[2026-10-21 10:00:00Z]
  end
end

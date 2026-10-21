defmodule GoldBackendWeb.Router do
  use GoldBackendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/trading", GoldBackendWeb do
    pipe_through :api

    post "/crawl-news", TradingController, :trigger_crawl_news
    get "/overview", TradingController, :overview
    get "/analyze", TradingController, :analyze_and_get_data
  end
end

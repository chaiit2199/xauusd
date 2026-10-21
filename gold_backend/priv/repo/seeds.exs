alias GoldBackend.Services.GoldPriceFetcher

case GoldPriceFetcher.seed_history_if_empty() do
  {:ok, :exists} ->
    IO.puts("Gold price history already present, skip seed.")

  {:ok, count} ->
    IO.puts("Seeded #{count} hourly gold prices so indicators have a window.")

  {:error, reason} ->
    IO.puts("Seed skipped: #{inspect(reason)}")
end

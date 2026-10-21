defmodule GoldBackend.Services.NewsTranslator do
  @moduledoc """
  Fills `title_vi` for headlines that are still in English.

  Translations are stored on the article, so the next page load does not call
  the translator again. A failed call leaves the original title in place.
  """

  alias GoldBackend.Repo

  @vietnamese ~r/[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]/iu

  def ensure_vietnamese(articles, opts \\ []) when is_list(articles) do
    timeout = Keyword.get(opts, :timeout, 8_000)

    articles
    |> Task.async_stream(&maybe_translate/1,
      timeout: timeout,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Enum.zip(articles)
    |> Enum.map(fn
      {{:ok, article}, _original} -> article
      {_other, original} -> original
    end)
  end

  defp maybe_translate(%{title_vi: title_vi} = article)
       when is_binary(title_vi) and title_vi != "" do
    article
  end

  defp maybe_translate(%{title: title} = article) when is_binary(title) do
    cond do
      vietnamese?(title) ->
        article

      true ->
        case translate(title) do
          {:ok, vietnamese} -> store(article, vietnamese)
          :error -> article
        end
    end
  end

  defp maybe_translate(article), do: article

  defp translate(title) do
    query = URI.encode_www_form(String.slice(title, 0, 400))
    url = "https://api.mymemory.translated.net/get?q=#{query}&langpair=en|vi"

    case HTTPoison.get(url, [{"User-Agent", "gold-backend"}], timeout: 8_000, recv_timeout: 8_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        decode(body, title)

      _ ->
        :error
    end
  end

  defp decode(body, source) do
    with {:ok, payload} <- Jason.decode(body),
         text when is_binary(text) <- get_in(payload, ["responseData", "translatedText"]),
         cleaned = clean(text),
         true <- usable?(cleaned, source) do
      {:ok, cleaned}
    else
      _ -> :error
    end
  end

  defp usable?(text, source) do
    text != "" and text != source and not String.contains?(text, "MYMEMORY WARNING") and
      vietnamese?(text)
  end

  defp vietnamese?(text), do: String.match?(text, @vietnamese)

  defp clean(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp store(article, vietnamese) do
    case article |> Ecto.Changeset.change(%{title_vi: vietnamese}) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _} -> %{article | title_vi: vietnamese}
    end
  end
end

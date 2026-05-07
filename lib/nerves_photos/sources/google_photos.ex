defmodule NervesPhotos.Sources.GooglePhotos do
  @moduledoc false
  @behaviour NervesPhotos.PhotoSource
  require Logger

  @url_regex ~r|https://lh3\.googleusercontent\.com/[^\s"'\\<>=]+|

  @fetch_size "=w1920-h1440"

  @impl true
  def list_assets(%{share_url: share_url} = config) do
    req_options = Map.get(config, :req_options, [])
    req = Req.new(req_options)

    case Req.get(req, url: share_url) do
      {:ok, %{status: 200, body: body}} ->
        parse_share_page(body)

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_image(base_url, config) do
    req_options = Map.get(config, :req_options, [])
    req = Req.new(req_options)
    url = base_url <> @fetch_size

    case Req.get(req, url: url) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_share_page(html) do
    urls =
      @url_regex
      |> Regex.scan(html)
      |> List.flatten()
      |> Enum.uniq()

    if urls == [] do
      Logger.warning("GooglePhotos: no photo URLs found in share page")
      {:error, :no_photos_found}
    else
      assets = Enum.map(urls, &{&1, %{date: nil, location: nil}})
      {:ok, assets}
    end
  end
end

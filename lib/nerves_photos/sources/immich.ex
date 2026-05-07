defmodule NervesPhotos.Sources.Immich do
  @moduledoc false
  @behaviour NervesPhotos.PhotoSource

  @impl true
  def list_assets(%{url: url, api_key: api_key, album_id: album_id} = config) do
    req_options = Map.get(config, :req_options, [])

    req =
      Req.new([base_url: normalize_url(url), headers: [{"x-api-key", api_key}]] ++ req_options)

    case Req.get(req, url: "/api/albums/#{album_id}") do
      {:ok, %{status: 200, body: %{"assets" => []}}} ->
        {:error, :empty}

      {:ok, %{status: 200, body: %{"assets" => assets}}} ->
        {:ok, Enum.map(assets, &parse_asset/1)}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_image(source_id, %{url: url, api_key: api_key} = config) do
    req_options = Map.get(config, :req_options, [])

    req =
      Req.new([base_url: normalize_url(url), headers: [{"x-api-key", api_key}]] ++ req_options)

    case Req.get(req, url: "/api/assets/#{source_id}/thumbnail", params: [size: "preview"]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_asset(asset) do
    date =
      case DateTime.from_iso8601(asset["fileCreatedAt"] || "") do
        {:ok, dt, _} -> DateTime.to_date(dt)
        _ -> nil
      end

    exif = asset["exifInfo"] || %{}

    location =
      [exif["city"], exif["country"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
      |> then(fn s -> if s == "", do: nil, else: s end)

    {asset["id"], %{date: date, location: location}}
  end

  defp normalize_url(nil), do: nil

  defp normalize_url(url) do
    if String.starts_with?(url, ["http://", "https://"]), do: url, else: "http://#{url}"
  end
end

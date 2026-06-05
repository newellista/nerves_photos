defmodule NervesPhotos.Sources.GooglePhotosAPI do
  @moduledoc false
  @behaviour NervesPhotos.PhotoSource
  require Logger

  alias NervesPhotos.GoogleOAuth

  @api_base "https://photoslibrary.googleapis.com/v1"
  @fetch_size "=w1920-h1080"

  @impl true
  def list_assets(
        %{client_id: cid, client_secret: cs, refresh_token: rt, album_id: album_id} = config
      ) do
    with {:ok, token} <- GoogleOAuth.refresh_access_token(cid, cs, rt, req_opts(config)) do
      fetch_all_items(token, album_id, nil, [], config)
    end
  end

  @impl true
  def fetch_image(media_item_id, %{client_id: cid, client_secret: cs, refresh_token: rt} = config) do
    with {:ok, token} <- GoogleOAuth.refresh_access_token(cid, cs, rt, req_opts(config)),
         {:ok, base_url} <- fetch_base_url(token, media_item_id, config) do
      req = Req.new(req_options(config))

      case Req.get(req, url: base_url <> @fetch_size) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_all_items(token, album_id, page_token, acc, config) do
    body = %{albumId: album_id, pageSize: 100}
    body = if page_token, do: Map.put(body, :pageToken, page_token), else: body
    req = Req.new(req_options(config))

    case Req.post(req,
           url: "#{@api_base}/mediaItems:search",
           headers: [authorization: "Bearer #{token}"],
           json: body
         ) do
      {:ok, %{status: 200, body: resp}} ->
        items = Map.get(resp, "mediaItems", [])
        all = acc ++ Enum.map(items, &to_asset/1)

        case Map.get(resp, "nextPageToken") do
          nil -> {:ok, all}
          next -> fetch_all_items(token, album_id, next, all, config)
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_base_url(token, media_item_id, config) do
    req = Req.new(req_options(config))

    case Req.get(req,
           url: "#{@api_base}/mediaItems/#{media_item_id}",
           headers: [authorization: "Bearer #{token}"]
         ) do
      {:ok, %{status: 200, body: %{"baseUrl" => base_url}}} -> {:ok, base_url}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_asset(%{"id" => id, "mediaMetadata" => %{"creationTime" => ts}}) do
    date =
      case DateTime.from_iso8601(ts) do
        {:ok, dt, _} -> DateTime.to_date(dt)
        _ -> nil
      end

    {id, %{date: date, location: nil}}
  end

  defp to_asset(%{"id" => id}), do: {id, %{date: nil, location: nil}}

  defp req_options(config), do: Map.get(config, :req_options, [])

  defp req_opts(config) do
    case Map.get(config, :req_options) do
      nil -> []
      opts -> [req_options: opts]
    end
  end
end

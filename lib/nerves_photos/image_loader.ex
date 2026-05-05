defmodule NervesPhotos.ImageLoader do
  @moduledoc false
  use GenServer
  require Logger

  alias Scenic.Assets.Stream, as: ScenicStream

  @stream_key "photo:current"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def load(asset_id, reply_to \\ nil, stream_key \\ @stream_key) do
    GenServer.cast(__MODULE__, {:load, asset_id, reply_to || self(), stream_key})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       connection_info_fn:
         opts[:connection_info_fn] || (&NervesPhotos.ImmichClient.connection_info/0),
       req_options: opts[:req_options] || [],
       put_fn: opts[:put_fn] || (&stream_put/2)
     }}
  end

  @impl true
  def handle_cast({:load, asset_id, reply_to, stream_key}, state) do
    Task.start(fn -> do_load(asset_id, reply_to, stream_key, state) end)
    {:noreply, state}
  end

  defp do_load(asset_id, reply_to, stream_key, state) do
    case fetch_preview(asset_id, state) do
      {:ok, image_bytes} ->
        handle_put(state.put_fn.(stream_key, image_bytes), asset_id, reply_to, stream_key)

      {:error, reason} ->
        Logger.warning("ImageLoader: failed to load #{asset_id}: #{inspect(reason)}")
        send(reply_to, {:image_load_error, asset_id})
    end
  end

  defp handle_put(:ok, _asset_id, reply_to, stream_key) do
    send(reply_to, {:image_loaded, stream_key})
  end

  defp handle_put({:error, reason}, asset_id, reply_to, _stream_key) do
    Logger.warning("ImageLoader: stream put failed for #{asset_id}: #{inspect(reason)}")
    send(reply_to, {:image_load_error, asset_id})
  end

  defp fetch_preview(asset_id, state) do
    {url, api_key} = state.connection_info_fn.()

    req =
      Req.new([base_url: url, headers: [{"x-api-key", api_key}]] ++ state.req_options)

    case Req.get(req, url: "/api/assets/#{asset_id}/thumbnail", params: [size: "preview"]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_put(stream_key, image_bytes) do
    case ScenicStream.Image.from_binary(image_bytes) do
      {:ok, img} -> ScenicStream.put(stream_key, img)
      {:error, :invalid} -> {:error, :invalid_image}
    end
  end
end

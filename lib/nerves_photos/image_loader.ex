defmodule NervesPhotos.ImageLoader do
  @moduledoc false
  use GenServer
  require Logger

  alias Scenic.Assets.Stream, as: ScenicStream

  @stream_key "photo:current"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def load(
        {_module, _source_id, _config, _meta} = asset,
        reply_to \\ nil,
        stream_key \\ @stream_key
      ) do
    GenServer.cast(__MODULE__, {:load, asset, reply_to || self(), stream_key})
  end

  @impl true
  def init(opts) do
    {:ok, %{put_fn: opts[:put_fn] || (&stream_put/2)}}
  end

  @impl true
  def handle_cast({:load, asset, reply_to, stream_key}, state) do
    Task.start(fn -> do_load(asset, reply_to, stream_key, state) end)
    {:noreply, state}
  end

  defp do_load({module, source_id, config, _meta} = asset, reply_to, stream_key, state) do
    case module.fetch_image(source_id, config) do
      {:ok, image_bytes} ->
        case state.put_fn.(stream_key, image_bytes) do
          :ok ->
            send(reply_to, {:image_loaded, stream_key})

          {:error, reason} ->
            Logger.warning("ImageLoader: stream put failed for #{source_id}: #{inspect(reason)}")
            send(reply_to, {:image_load_error, asset})
        end

      {:error, reason} ->
        Logger.warning("ImageLoader: failed to load #{source_id}: #{inspect(reason)}")
        send(reply_to, {:image_load_error, asset})
    end
  end

  defp stream_put(stream_key, image_bytes) do
    case ScenicStream.Image.from_binary(image_bytes) do
      {:ok, img} -> ScenicStream.put(stream_key, img)
      {:error, :invalid} -> {:error, :invalid_image}
    end
  end
end

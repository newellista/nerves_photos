defmodule NervesPhotos.ImageLoader do
  @moduledoc false
  use GenServer
  require Logger

  alias Scenic.Assets.Stream, as: ScenicStream

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def load({_module, source_id, _config, _meta} = asset, reply_to \\ nil, stream_key \\ nil) do
    key = stream_key || source_id
    GenServer.cast(__MODULE__, {:load, asset, reply_to || self(), key})
  end

  @impl true
  def init(opts) do
    {:ok, %{put_fn: opts[:put_fn] || (&stream_put/2), generation: 0}}
  end

  @impl true
  def handle_cast({:load, asset, reply_to, stream_key}, state) do
    gen = state.generation + 1
    loader = self()
    Task.start(fn -> do_load(asset, reply_to, stream_key, state, gen, loader) end)
    {:noreply, %{state | generation: gen}}
  end

  @impl true
  def handle_call({:current_generation}, _from, state) do
    {:reply, state.generation, state}
  end

  defp do_load(
         {module, source_id, config, _meta} = asset,
         reply_to,
         stream_key,
         state,
         gen,
         loader
       ) do
    case module.fetch_image(source_id, config) do
      {:ok, image_bytes} ->
        if GenServer.call(loader, {:current_generation}) == gen do
          case state.put_fn.(stream_key, image_bytes) do
            {:ok, width, height} ->
              send(reply_to, {:image_loaded, stream_key, width, height})

            {:error, reason} ->
              Logger.warning(
                "ImageLoader: stream put failed for #{source_id}: #{inspect(reason)}"
              )

              send(reply_to, {:image_load_error, asset})
          end
        end

      {:error, reason} ->
        Logger.warning("ImageLoader: failed to load #{source_id}: #{inspect(reason)}")
        send(reply_to, {:image_load_error, asset})
    end
  end

  defp stream_put(stream_key, image_bytes) do
    case ScenicStream.Image.from_binary(image_bytes) do
      {:ok, {_, {width, height, _}, _} = img} ->
        case ScenicStream.put(stream_key, img) do
          :ok -> {:ok, width, height}
          {:error, _} = err -> err
        end

      {:error, :invalid} ->
        {:error, :invalid_image}
    end
  end
end

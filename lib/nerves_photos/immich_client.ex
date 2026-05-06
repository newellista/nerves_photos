defmodule NervesPhotos.ImmichClient do
  @moduledoc false
  use GenServer
  require Logger

  @backoff_initial 1_000
  @backoff_max 60_000
  @recheck_interval 5_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def current, do: GenServer.call(__MODULE__, :current)
  def advance, do: GenServer.call(__MODULE__, :advance)
  def queue_position, do: GenServer.call(__MODULE__, :queue_position)
  def connection_info, do: GenServer.call(__MODULE__, :connection_info)

  @impl true
  def init(opts) do
    fetch = fn key, setting ->
      case Keyword.fetch(opts, key) do
        {:ok, val} -> val
        :error -> NervesPhotos.SettingsStore.get(setting)
      end
    end

    state = %{
      url: fetch.(:url, :immich_url) |> normalize_url(),
      api_key: fetch.(:api_key, :immich_api_key),
      album_id: fetch.(:album_id, :immich_album_id),
      req_options: opts[:req_options] || [],
      queue: [],
      index: 0,
      status: :loading
    }

    if configured?(state) do
      send(self(), :fetch_album)
    else
      Process.send_after(self(), :recheck_config, @recheck_interval)
    end

    {:ok, %{state | status: if(configured?(state), do: :loading, else: :not_configured)}}
  end

  @impl true
  def handle_call(:current, _from, %{status: :not_configured} = state) do
    {:reply, :not_configured, state}
  end

  def handle_call(:advance, _from, %{status: :not_configured} = state) do
    {:reply, :not_configured, state}
  end

  def handle_call(:queue_position, _from, %{status: :not_configured} = state) do
    {:reply, {0, 0}, state}
  end

  def handle_call(:current, _from, %{queue: [], status: :disconnected} = state) do
    {:reply, :disconnected, state}
  end

  def handle_call(:current, _from, %{queue: [], status: :empty} = state) do
    {:reply, :empty, state}
  end

  def handle_call(:current, _from, %{queue: []} = state) do
    {:reply, :loading, state}
  end

  def handle_call(:current, _from, state) do
    {:reply, current_photo(state), state}
  end

  def handle_call(:advance, _from, %{queue: [], status: :disconnected} = state) do
    {:reply, :disconnected, state}
  end

  def handle_call(:advance, _from, %{queue: [], status: :empty} = state) do
    {:reply, :empty, state}
  end

  def handle_call(:advance, _from, %{queue: []} = state) do
    {:reply, :loading, state}
  end

  def handle_call(:advance, _from, state) do
    next_index = state.index + 1

    if next_index >= length(state.queue) do
      send(self(), :fetch_album)
      new_state = %{state | index: 0}
      {:reply, current_photo(new_state), new_state}
    else
      new_state = %{state | index: next_index}
      {:reply, current_photo(new_state), new_state}
    end
  end

  def handle_call(:queue_position, _from, state) do
    {:reply, {state.index + 1, length(state.queue)}, state}
  end

  def handle_call(:connection_info, _from, state) do
    {:reply, {state.url, state.api_key}, state}
  end

  @impl true
  def handle_info(:fetch_album, state) do
    case fetch_album(state) do
      {:ok, assets} ->
        queue = Enum.shuffle(assets)
        {:noreply, %{state | queue: queue, index: 0, status: :ok}}

      {:error, :empty} ->
        Logger.info("ImmichClient: album is empty, retrying in 5 minutes")
        Process.send_after(self(), :fetch_album, 5 * 60 * 1_000)
        {:noreply, %{state | status: :empty}}

      {:error, reason} ->
        Logger.warning("ImmichClient: fetch failed: #{inspect(reason)}")
        backoff = Map.get(state, :backoff, @backoff_initial)
        Process.send_after(self(), :fetch_album, backoff)

        new_state =
          state
          |> Map.put(:status, :disconnected)
          |> Map.put(:backoff, min(backoff * 2, @backoff_max))

        {:noreply, new_state}
    end
  end

  def handle_info(:recheck_config, state) do
    new_state = %{
      state
      | url: state.url || NervesPhotos.SettingsStore.get(:immich_url),
        api_key: state.api_key || NervesPhotos.SettingsStore.get(:immich_api_key),
        album_id: state.album_id || NervesPhotos.SettingsStore.get(:immich_album_id)
    }

    if configured?(new_state) do
      send(self(), :fetch_album)
      {:noreply, %{new_state | status: :loading}}
    else
      Process.send_after(self(), :recheck_config, @recheck_interval)
      {:noreply, new_state}
    end
  end

  defp configured?(state) do
    is_binary(state.url) and is_binary(state.api_key) and is_binary(state.album_id)
  end

  defp fetch_album(state) do
    req =
      Req.new(
        [
          base_url: state.url,
          headers: [{"x-api-key", state.api_key}]
        ] ++ state.req_options
      )

    case Req.get(req, url: "/api/albums/#{state.album_id}") do
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

  defp current_photo(%{queue: queue, index: index}) do
    Enum.at(queue, index)
  end

  defp normalize_url(nil), do: nil

  defp normalize_url(url) do
    if String.starts_with?(url, ["http://", "https://"]), do: url, else: "http://#{url}"
  end
end

defmodule NervesPhotos.ImmichClient do
  use GenServer
  require Logger

  @backoff_initial 1_000
  @backoff_max 60_000

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
    state = %{
      url: opts[:url] || NervesPhotos.SettingsStore.get(:immich_url),
      api_key: opts[:api_key] || NervesPhotos.SettingsStore.get(:immich_api_key),
      album_id: opts[:album_id] || NervesPhotos.SettingsStore.get(:immich_album_id),
      req_options: opts[:req_options] || [],
      queue: [],
      index: 0,
      status: :loading
    }

    send(self(), :fetch_album)
    {:ok, state}
  end

  @impl true
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
        new_state = state |> Map.put(:status, :disconnected) |> Map.put(:backoff, min(backoff * 2, @backoff_max))
        {:noreply, new_state}
    end
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
end

defmodule NervesPhotos.PhotoQueue do
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

  @impl true
  def init(opts) do
    sources_opt = Keyword.get(opts, :sources, :from_store)
    source_module_fn = Keyword.get(opts, :source_module_fn, &source_module/1)

    sources =
      if sources_opt == :from_store do
        NervesPhotos.SettingsStore.get(:photo_sources) || []
      else
        sources_opt
      end

    state = %{
      sources: sources,
      queue: [],
      index: 0,
      status: :loading,
      backoff: @backoff_initial,
      source_module_fn: source_module_fn
    }

    if sources == [] do
      Process.send_after(self(), :recheck_config, @recheck_interval)
      {:ok, %{state | status: :not_configured}}
    else
      send(self(), :fetch_all)
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:current, _from, %{status: :not_configured} = state),
    do: {:reply, :not_configured, state}

  def handle_call(:advance, _from, %{status: :not_configured} = state),
    do: {:reply, :not_configured, state}

  def handle_call(:queue_position, _from, %{status: :not_configured} = state),
    do: {:reply, {0, 0}, state}

  def handle_call(:current, _from, %{queue: []} = state),
    do: {:reply, state.status, state}

  def handle_call(:advance, _from, %{queue: []} = state),
    do: {:reply, state.status, state}

  def handle_call(:queue_position, _from, %{queue: []} = state),
    do: {:reply, {0, 0}, state}

  def handle_call(:current, _from, state),
    do: {:reply, Enum.at(state.queue, state.index), state}

  def handle_call(:advance, _from, state) do
    next = state.index + 1

    if next >= length(state.queue) do
      send(self(), :fetch_all)
      new_state = %{state | index: 0}
      {:reply, Enum.at(new_state.queue, 0), new_state}
    else
      new_state = %{state | index: next}
      {:reply, Enum.at(new_state.queue, next), new_state}
    end
  end

  def handle_call(:queue_position, _from, state),
    do: {:reply, {state.index + 1, length(state.queue)}, state}

  @impl true
  def handle_info(:recheck_config, state) do
    sources = NervesPhotos.SettingsStore.get(:photo_sources) || []

    if sources == [] do
      Process.send_after(self(), :recheck_config, @recheck_interval)
      {:noreply, state}
    else
      send(self(), :fetch_all)
      {:noreply, %{state | sources: sources, status: :loading}}
    end
  end

  def handle_info(:fetch_all, state) do
    results =
      Task.async_stream(
        state.sources,
        fn source -> {source, state.source_module_fn.(source).list_assets(source)} end,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    successes =
      for {:ok, {source, {:ok, assets}}} <- results do
        module = state.source_module_fn.(source)
        Enum.map(assets, fn {id, meta} -> {module, id, source, meta} end)
      end
      |> List.flatten()

    failures =
      for {:ok, {source, {:error, reason}}} <- results do
        {source, reason}
      end

    Enum.each(failures, fn {source, reason} ->
      Logger.warning(
        "PhotoQueue: source #{inspect(Map.get(source, :type))} failed: #{inspect(reason)}"
      )
    end)

    cond do
      successes != [] ->
        queue = Enum.shuffle(successes)
        {:noreply, %{state | queue: queue, index: 0, status: :ok, backoff: @backoff_initial}}

      Enum.all?(results, fn
        {:ok, {_src, {:error, :empty}}} -> true
        _ -> false
      end) ->
        Logger.info("PhotoQueue: all sources empty, retrying in 5 minutes")
        Process.send_after(self(), :fetch_all, 5 * 60 * 1_000)
        {:noreply, %{state | status: :empty}}

      true ->
        backoff = state.backoff
        Logger.warning("PhotoQueue: all sources failed, retrying in #{backoff}ms")
        Process.send_after(self(), :fetch_all, backoff)
        {:noreply, %{state | status: :disconnected, backoff: min(backoff * 2, @backoff_max)}}
    end
  end

  defp source_module(%{type: "immich"}), do: NervesPhotos.Sources.Immich
  defp source_module(%{type: "google_photos"}), do: NervesPhotos.Sources.GooglePhotos

  defp source_module(source),
    do: raise("PhotoQueue: unknown source type #{inspect(source)}")
end

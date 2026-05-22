defmodule NervesPhotos.FrameCompositor do
  use GenServer
  require Logger

  @fade_steps 20
  @fade_interval_ms 16

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || NervesPhotos.Scene.Main)
  end

  @impl true
  def init(opts) do
    port_pid = opts[:port_pid] || NervesPhotos.CairoPort

    state = %{
      port: port_pid,
      phase: :idle,
      current_slot: 0,
      next_slot: 1,
      metadata: nil,
      transition_step: 0,
      transition_steps: @fade_steps,
      disconnected: false,
      empty_album: false,
      has_photo: false,
      advance_fn: opts[:advance_fn] || (&NervesPhotos.PhotoQueue.advance/0),
      queue_position_fn: opts[:queue_position_fn] || (&NervesPhotos.PhotoQueue.queue_position/0),
      weather_fn: opts[:weather_fn] || (&NervesPhotos.WeatherFetcher.current/0),
      settings_fn: opts[:settings_fn] || (&NervesPhotos.SettingsStore.get/1)
    }

    case NervesPhotos.CairoPort.init_display(port_pid) do
      {:ok, _dims} -> {:ok, state}
      {:error, reason} -> {:stop, {:display_init_failed, reason}}
    end
  end

  @impl true
  def handle_info({:slide_timer, :next_photo}, %{phase: :idle} = state) do
    case state.advance_fn.() do
      {module, source_id, config, metadata} ->
        compositor = self()
        next_slot = state.next_slot
        port = state.port

        Task.start(fn ->
          case module.fetch_image(source_id, config) do
            {:ok, bytes} ->
              case NervesPhotos.CairoPort.load_image(port, next_slot, bytes) do
                {:ok, _dims} -> send(compositor, {:image_loaded, next_slot})
                {:error, _} -> send(compositor, {:image_load_error, source_id})
              end

            {:error, _} ->
              send(compositor, {:image_load_error, source_id})
          end
        end)

        {:noreply, Map.merge(state, %{phase: :loading, metadata: metadata})}

      :disconnected ->
        {:noreply, Map.put(state, :disconnected, true)}

      :empty ->
        {:noreply, Map.put(state, :empty_album, true)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:slide_timer, :next_photo}, state), do: {:noreply, state}

  def handle_info({:image_loaded, slot}, state) do
    transition_type = state.settings_fn.(:transition_type) || :fade_to_black
    transition_steps = if transition_type == :none, do: 0, else: @fade_steps

    state =
      Map.merge(state, %{
        phase: :transitioning,
        next_slot: slot,
        transition_step: 0,
        transition_steps: transition_steps,
        has_photo: true,
        disconnected: false,
        empty_album: false
      })

    send(self(), :transition_tick)
    {:noreply, state}
  end

  def handle_info({:image_load_error, _}, state) do
    NervesPhotos.CairoPort.free_slot(state.port, state.next_slot)
    send(self(), {:slide_timer, :next_photo})
    {:noreply, Map.put(state, :phase, :idle)}
  end

  def handle_info(
        :transition_tick,
        %{phase: :transitioning, transition_step: step, transition_steps: total} = state
      )
      when step <= total do
    t = if total == 0, do: 1.0, else: step / total

    weather = state.weather_fn.()
    {pos, total_q} = state.queue_position_fn.()
    crop_mode = state.settings_fn.(:crop_mode) || :letterbox
    transition_type = state.settings_fn.(:transition_type) || :fade_to_black

    overlays = build_overlays(state, weather, pos, total_q)

    NervesPhotos.CairoPort.render_frame(state.port, %{
      transition_type: transition_type,
      t: t,
      crop_mode: crop_mode,
      overlays: overlays
    })

    Process.send_after(self(), :transition_tick, @fade_interval_ms)
    {:noreply, %{state | transition_step: step + 1}}
  end

  def handle_info(:transition_tick, %{phase: :transitioning} = state) do
    NervesPhotos.CairoPort.free_slot(state.port, state.current_slot)

    state =
      Map.merge(state, %{
        phase: :idle,
        current_slot: state.next_slot,
        next_slot: state.current_slot
      })

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp build_overlays(state, weather, pos, total_q) do
    %{}
    |> maybe_add_metadata(state.metadata)
    |> maybe_add_weather(weather)
    |> maybe_add_debug(pos, total_q)
    |> Map.put(:show_disconnected, state.disconnected)
    |> Map.put(:show_empty_album, state.empty_album)
  end

  defp maybe_add_metadata(overlays, nil), do: overlays

  defp maybe_add_metadata(overlays, %{date: date, location: location}) do
    date_str = date && Calendar.strftime(date, "%-d %B %Y")

    overlays
    |> Map.put(:date, date_str)
    |> Map.put(:location, location)
  end

  defp maybe_add_weather(overlays, :unavailable), do: overlays

  defp maybe_add_weather(overlays, {:ok, %{temp_f: temp, condition: condition}}) do
    overlays
    |> Map.put(:temp, "#{round(temp)}°F")
    |> Map.put(:condition, condition)
  end

  defp maybe_add_debug(overlays, pos, total_q) do
    if Application.get_env(:nerves_photos, :show_debug, false) do
      Map.put(overlays, :debug, "#{pos}/#{total_q}")
    else
      overlays
    end
  end
end

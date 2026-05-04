defmodule NervesPhotos.Scene.Main do
  @moduledoc false
  use Scenic.Scene
  require Logger

  alias NervesPhotos.Component.DebugBar
  alias NervesPhotos.Component.MetadataOverlay
  alias NervesPhotos.Component.WeatherOverlay
  alias Scenic.Graph
  import Scenic.Primitives

  @stream_key "photo:current"
  @fade_steps 20
  @fade_interval_ms 16

  @impl Scenic.Scene
  def init(scene, _params, opts) do
    viewport = opts[:viewport]
    {:ok, %{size: {width, height}}} = Scenic.ViewPort.info(viewport)

    graph =
      Graph.build(font: :roboto, font_size: 20)
      |> rect({width, height}, fill: :black, id: :background)

    scene =
      scene
      |> assign(
        width: width,
        height: height,
        metadata: nil,
        disconnected: false,
        empty_album: false,
        has_photo: false,
        transition: :idle,
        fade_step: 0,
        fade_opacity: 0.0
      )
      |> push_graph(graph)

    {:ok, scene}
  end

  @impl GenServer
  def handle_info({:slide_timer, :next_photo}, %{assigns: %{transition: :idle}} = scene) do
    case NervesPhotos.ImmichClient.advance() do
      {asset_id, metadata} ->
        NervesPhotos.ImageLoader.load(asset_id, self())
        {:noreply, assign(scene, metadata: metadata, transition: :loading)}

      :disconnected ->
        {:noreply, assign(scene, disconnected: true)}

      :empty ->
        {:noreply, assign(scene, empty_album: true)}

      :loading ->
        {:noreply, scene}
    end
  end

  def handle_info({:slide_timer, :next_photo}, scene), do: {:noreply, scene}

  def handle_info({:image_loaded, _key}, scene) do
    scene =
      assign(scene, disconnected: false, has_photo: true, transition: :fading_out, fade_step: 0)

    send(self(), :transition_tick)
    {:noreply, scene}
  end

  def handle_info({:image_load_error, _asset_id}, scene) do
    send(self(), {:slide_timer, :next_photo})
    {:noreply, assign(scene, transition: :idle)}
  end

  def handle_info(
        :transition_tick,
        %{assigns: %{transition: :fading_out, fade_step: step}} = scene
      )
      when step <= @fade_steps do
    opacity = step / @fade_steps
    scene = assign(scene, fade_opacity: opacity, fade_step: step + 1)
    Process.send_after(self(), :transition_tick, @fade_interval_ms)
    {:noreply, render(scene)}
  end

  def handle_info(:transition_tick, %{assigns: %{transition: :fading_out}} = scene) do
    scene = assign(scene, transition: :fading_in, fade_step: 0)
    send(self(), :transition_tick)
    {:noreply, render(scene)}
  end

  def handle_info(
        :transition_tick,
        %{assigns: %{transition: :fading_in, fade_step: step}} = scene
      )
      when step <= @fade_steps do
    opacity = 1.0 - step / @fade_steps
    scene = assign(scene, fade_opacity: opacity, fade_step: step + 1)
    Process.send_after(self(), :transition_tick, @fade_interval_ms)
    {:noreply, render(scene)}
  end

  def handle_info(:transition_tick, %{assigns: %{transition: :fading_in}} = scene) do
    scene = assign(scene, transition: :idle, fade_opacity: 0.0)
    {:noreply, render(scene)}
  end

  def handle_info(_msg, scene), do: {:noreply, scene}

  defp render(scene) do
    %{
      width: width,
      height: height,
      metadata: metadata,
      disconnected: disconnected,
      empty_album: empty_album,
      has_photo: has_photo,
      fade_opacity: fade_opacity
    } = scene.assigns

    weather = NervesPhotos.WeatherFetcher.current()
    {current, total} = NervesPhotos.ImmichClient.queue_position()
    show_debug = Application.get_env(:nerves_photos, :show_debug, false)
    meta = metadata || %{date: nil, location: nil}
    fade_alpha = round(fade_opacity * 255)

    graph =
      Graph.build(font: :roboto, font_size: 20)
      |> rect({width, height}, fill: :black, id: :background)
      |> then(fn g ->
        if has_photo do
          rect(g, {width, height}, fill: {:stream, @stream_key}, id: :photo)
        else
          g
        end
      end)
      |> then(fn g ->
        if fade_alpha > 0 do
          rect(g, {width, height}, fill: {:color_rgba, {0, 0, 0, fade_alpha}}, id: :fade_overlay)
        else
          g
        end
      end)
      |> MetadataOverlay.add_to_graph(
        Map.merge(meta, %{width: width, height: height}),
        id: :metadata
      )
      |> WeatherOverlay.add_to_graph(
        %{weather: weather, width: width, height: height},
        id: :weather
      )
      |> then(fn g ->
        if empty_album do
          msg_x = div(width, 2) - 100

          g
          |> rect({200, 36},
            fill: {:color_rgba, {0, 0, 0, 160}},
            translate: {msg_x, div(height, 2) - 18},
            radius: 8
          )
          |> text("No photos found in album",
            fill: :white,
            font_size: 16,
            translate: {msg_x + 12, div(height, 2) + 7}
          )
        else
          g
        end
      end)
      |> then(fn g ->
        if disconnected do
          label_x = div(width, 2) - 70

          g
          |> rect({140, 30},
            fill: {:color_rgba, {0, 0, 0, 160}},
            translate: {label_x, 16},
            radius: 15
          )
          |> text("Reconnecting...",
            fill: {:color, {255, 204, 68}},
            font_size: 16,
            translate: {label_x + 10, 37}
          )
        else
          g
        end
      end)
      |> then(fn g ->
        if show_debug do
          DebugBar.add_to_graph(
            g,
            %{current: current, total: total, width: width, height: height},
            id: :debug
          )
        else
          g
        end
      end)

    push_graph(scene, graph)
  end
end

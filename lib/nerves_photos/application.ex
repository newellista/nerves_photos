defmodule NervesPhotos.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ets.new(:nerves_photos_sessions, [:named_table, :public, read_concurrency: true])
    children = target_children()
    opts = [strategy: :one_for_one, name: NervesPhotos.Supervisor]
    Supervisor.start_link(children, opts)
  end

  cond do
    Mix.env() == :test ->
      defp target_children, do: []

    Mix.target() == :host ->
      defp target_children do
        [
          NervesPhotos.SettingsStore,
          NervesPhotos.UserStore,
          NervesPhotos.SettingsServer
        ]
      end

    true ->
      defp target_children do
        core = [
          NervesPhotos.SettingsStore,
          NervesPhotos.UserStore,
          NervesPhotos.ConnectivityMonitor,
          NervesPhotos.SettingsServer,
          NervesPhotos.PhotoQueue,
          NervesPhotos.WeatherFetcher,
          NervesPhotos.SlideTimer
        ]

        if Application.get_env(:nerves_photos, :headless_mode, false) do
          core ++ [NervesPhotos.Scene.Headless]
        else
          viewport_config = Application.get_env(:nerves_photos, :viewport)
          core ++ [NervesPhotos.ImageLoader, {Scenic, [viewport_config]}]
        end
      end
  end
end

defmodule NervesPhotos.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ets.new(:nerves_photos_sessions, [:named_table, :public, read_concurrency: true])
    hide_cursor()
    children = target_children()
    opts = [strategy: :one_for_one, name: NervesPhotos.Supervisor]
    Supervisor.start_link(children, opts)
  end

  cond do
    Mix.env() == :test ->
      defp hide_cursor, do: :ok
      defp target_children, do: []

    Mix.target() == :host ->
      defp hide_cursor, do: :ok

      defp target_children do
        [
          NervesPhotos.SettingsStore,
          NervesPhotos.UserStore,
          NervesPhotos.GoogleOAuthState,
          NervesPhotos.SettingsServer
        ]
      end

    true ->
      defp hide_cursor, do: File.write("/dev/tty1", "\e[?25l")

      defp target_children do
        core = [
          NervesPhotos.SettingsStore,
          NervesPhotos.UserStore,
          NervesPhotos.GoogleOAuthState,
          NervesPhotos.ConnectivityMonitor,
          NervesPhotos.SettingsServer,
          NervesPhotos.PhotoQueue,
          NervesPhotos.WeatherFetcher,
          NervesPhotos.SlideTimer
        ]

        if Application.get_env(:nerves_photos, :headless_mode, false) do
          core ++ [NervesPhotos.Scene.Headless]
        else
          compositor_children = [
            NervesPhotos.CairoPort,
            NervesPhotos.FrameCompositor
          ]

          core ++
            [
              %{
                id: NervesPhotos.CompositorSupervisor,
                start:
                  {Supervisor, :start_link,
                   [
                     compositor_children,
                     [strategy: :rest_for_one, name: NervesPhotos.CompositorSupervisor]
                   ]},
                type: :supervisor
              }
            ]
        end
      end
  end
end

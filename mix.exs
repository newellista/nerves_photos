defmodule NervesPhotos.MixProject do
  use Mix.Project

  @app :nerves_photos
  @version "0.1.0"
  @all_targets [:bbb, :grisp2, :osd32mp1, :mangopi_mq_pro, :qemu_aarch64, :rpi, :rpi0, :rpi0_2, :rpi3, :rpi4, :rpi5, :x86_64]

  def project do
    setup_nerves_env()

    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      archives: [nerves_bootstrap: "~> 1.15"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {NervesPhotos.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  def aliases do
    [
      "deps.get": ["deps.get", "cmd patch --forward -p1 -d deps/scenic_driver_local < patches/scenic_driver_local.patch || true"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
    {:nerves_runtime, "~> 0.13.12"},

      # Dependencies for all targets except :host
    {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5.0"},
      {:nerves_time, "~> 0.4.0"},
      {:vintage_net, "~> 0.13.9"},
      {:vintage_net_wifi, "~> 0.12.8"},

      # UI / Scenic
    {:scenic, "~> 0.11.0"},
      # rpi0/rpi4/rpi5 use DRM; rpi3 uses BCM (VideoCore IV userland)
      {:scenic_driver_local, "~> 0.11", targets: [:rpi0, :rpi3, :rpi4, :rpi5], make_env: %{"SCENIC_LOCAL_TARGET" => "drm"}},
      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_rpi0, "~> 2.0", runtime: false, targets: :rpi0},
      {:nerves_system_rpi3, "~> 2.0", runtime: false, targets: :rpi3},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5},

      # Web settings UI
      {:plug, "~> 1.0"},
      {:plug_cowboy, "~> 2.7"},

      # Dev tooling
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false}
      ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  defp setup_nerves_env() do
    case System.get_env("MIX_TARGET") do
      "rpi5" ->
        System.put_env("SCENIC_LOCAL_TARGET", "drm")
        System.put_env("SCENIC_LOCAL_GL", "gles3")

      "rpi4" ->
        System.put_env("SCENIC_LOCAL_TARGET", "drm")
        System.put_env("SCENIC_LOCAL_GL", "gles3")

      "rpi3" ->
        System.put_env("SCENIC_LOCAL_TARGET", "bcm")

      "rpi0" ->
        System.put_env("SCENIC_LOCAL_TARGET", "drm")

      _ ->
        :ok
    end
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []
end

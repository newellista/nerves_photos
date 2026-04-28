defmodule NervesPhotos.MixProject do
  use Mix.Project

  @app :nerves_photos
  @version "0.1.0"
  @all_targets [:bbb, :grisp2, :osd32mp1, :mangopi_mq_pro, :qemu_aarch64, :rpi, :rpi0, :rpi0_2, :rpi2, :rpi3, :rpi4, :rpi5, :x86_64]

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
      {:scenic_driver_local, "~> 0.11", targets: @all_targets, make_env: %{"SCENIC_LOCAL_TARGET" => "drm"}},
      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_rpi0, "~> 2.0", runtime: false, targets: :rpi0},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5}
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
  # Check if we are targeting rpi0 AND if the Nerves.Env module is loaded
    if System.get_env("MIX_TARGET") == "rpi0" and Code.ensure_loaded?(Nerves.Env) do
      System.put_env("SCENIC_LOCAL_TARGET", "drm")

    # Use the function/1 version to ensure it handles the target correctly
      system_path = Nerves.Env.system_path(:rpi0)

      if system_path && File.exists?(system_path) do
        libdrm_path = Path.join([system_path, "staging", "usr", "include", "libdrm"])

        current_cflags = System.get_env("CFLAGS") || ""
        System.put_env("CFLAGS", "#{current_cflags} -I#{libdrm_path}")
        System.put_env("ERL_CFLAGS", "-I#{libdrm_path}")
      end
    end
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []
end

# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1777414603"

config :nerves_photos, :viewport, %{
  name: :main_viewport,
  size: {1920, 1080},
  default_scene: NervesPhotos.Scene.Main,
  drivers: [
    %{module: Scenic.Driver.Local}
  ]
}

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end

# rpi2/rpi3 system images don't include Mesa3D, so scenic_driver_local can't
# compile for them. Force headless mode so the app starts without Scenic.
if Mix.target() in [:rpi2, :rpi3] do
  config :nerves_photos, headless_mode: true
end

if Mix.env() == :test do
  import_config "test.exs"
end

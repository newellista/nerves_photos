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

config :scenic, :assets, module: NervesPhotos.Assets

config :nerves_photos, :viewport, %{
  name: :main_viewport,
  size: {1920, 1080},
  default_scene: NervesPhotos.Scene.Main,
  drivers: [
    %{module: Scenic.Driver.Local}
  ]
}

# Dev/test fallback only. Production releases override this via config/runtime.exs,
# which generates a unique key on first boot and persists it to /data.
config :nerves_photos,
  secret_key_base: "nerves_photos_default_secret_key_base_change_before_shipping_xxxxxxxxxxx"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end

if Mix.env() == :test do
  import_config "test.exs"
end

defmodule NervesPhotos.SettingsServer do
  @moduledoc false
  def child_spec(_opts) do
    port = Application.get_env(:nerves_photos, :http_port, 80)

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: NervesPhotos.SettingsRouter,
      options: [port: port]
    )
  end
end

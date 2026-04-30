defmodule NervesPhotos.SettingsServer do
  def child_spec(_opts) do
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: NervesPhotos.SettingsRouter,
      options: [port: 80]
    )
  end
end

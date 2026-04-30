defmodule NervesPhotos.SettingsRouter do
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded]
  plug :dispatch

  get "/settings" do
    settings = NervesPhotos.SettingsStore.all()
    send_resp(conn, 200, render_form(settings))
  end

  post "/settings" do
    params = conn.body_params

    if url = params["immich_url"], do: NervesPhotos.SettingsStore.put(:immich_url, url)
    if key = params["immich_api_key"], do: NervesPhotos.SettingsStore.put(:immich_api_key, key)
    if album = params["immich_album_id"], do: NervesPhotos.SettingsStore.put(:immich_album_id, album)

    if interval = params["slide_interval_ms"] do
      case Integer.parse(interval) do
        {s, ""} when s > 0 -> NervesPhotos.SettingsStore.put(:slide_interval_ms, s * 1_000)
        _ -> nil
      end
    end

    if ssid = params["wifi_ssid"] do
      psk = params["wifi_psk"] || ""
      NervesPhotos.SettingsStore.put(:wifi_ssid, ssid)
      NervesPhotos.SettingsStore.put(:wifi_psk, psk)
      VintageNet.configure("wlan0", %{
        type: VintageNetWiFi,
        vintage_net_wifi: %{networks: [%{ssid: ssid, psk: psk, key_mgmt: :wpa_psk}]},
        ipv4: %{method: :dhcp}
      })
    end

    conn
    |> put_resp_header("location", "/settings")
    |> send_resp(303, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp render_form(s) do
    interval_s = div(Map.get(s, :slide_interval_ms, 30_000), 1_000)
    """
    <!DOCTYPE html>
    <html>
    <head><title>NervesPhotos Settings</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body { font-family: sans-serif; max-width: 480px; margin: 40px auto; padding: 0 16px; }
      label { display: block; margin-top: 16px; font-size: 14px; color: #555; }
      input { width: 100%; padding: 8px; margin-top: 4px; box-sizing: border-box; font-size: 16px; }
      button { margin-top: 24px; width: 100%; padding: 12px; background: #2563eb; color: white;
               border: none; font-size: 16px; cursor: pointer; }
      h2 { margin-top: 32px; font-size: 16px; color: #888; text-transform: uppercase; }
    </style>
    </head>
    <body>
    <h1>NervesPhotos Settings</h1>
    <form method="POST" action="/settings">
      <h2>Immich</h2>
      <label>Server URL
        <input name="immich_url" value="#{Map.get(s, :immich_url) || ""}">
      </label>
      <label>API Key
        <input name="immich_api_key" value="#{Map.get(s, :immich_api_key) || ""}">
      </label>
      <label>Album ID
        <input name="immich_album_id" value="#{Map.get(s, :immich_album_id) || ""}">
      </label>
      <h2>Display</h2>
      <label>Slide interval (seconds)
        <input name="slide_interval_ms" type="number" min="5" value="#{interval_s}">
      </label>
      <h2>WiFi</h2>
      <label>SSID
        <input name="wifi_ssid" value="#{Map.get(s, :wifi_ssid) || ""}">
      </label>
      <label>Password
        <input name="wifi_psk" type="password">
      </label>
      <button type="submit">Save &amp; Reboot</button>
    </form>
    </body>
    </html>
    """
  end
end

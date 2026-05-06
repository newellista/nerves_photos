defmodule NervesPhotos.SettingsRouter do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded])
  plug(:dispatch)

  get "/settings" do
    settings = NervesPhotos.SettingsStore.all()

    wifi_mode =
      if pid = Process.whereis(NervesPhotos.ConnectivityMonitor) do
        GenServer.call(pid, :mode)
      end

    send_resp(conn, 200, render_form(settings, wifi_mode))
  end

  post "/settings" do
    params = conn.body_params

    if url = params["immich_url"], do: NervesPhotos.SettingsStore.put(:immich_url, url)
    if key = params["immich_api_key"], do: NervesPhotos.SettingsStore.put(:immich_api_key, key)

    if album = params["immich_album_id"],
      do: NervesPhotos.SettingsStore.put(:immich_album_id, album)

    if interval = params["slide_interval_ms"] do
      case Integer.parse(interval) do
        {s, ""} when s > 0 -> NervesPhotos.SettingsStore.put(:slide_interval_ms, s * 1_000)
        _ -> nil
      end
    end

    NervesPhotos.SettingsStore.put(:weather_zip, params["weather_zip"] || "")

    if ssid = params["wifi_ssid"] do
      psk = params["wifi_psk"] || ""
      old_ssid = NervesPhotos.SettingsStore.get(:wifi_ssid)
      old_psk = NervesPhotos.SettingsStore.get(:wifi_psk) || ""
      wifi_changed = ssid != old_ssid || psk != ""
      effective_psk = if psk != "", do: psk, else: old_psk

      NervesPhotos.SettingsStore.put(:wifi_ssid, ssid)
      if psk != "", do: NervesPhotos.SettingsStore.put(:wifi_psk, psk)

      if wifi_changed do
        if pid = Process.whereis(NervesPhotos.ConnectivityMonitor) do
          GenServer.cast(pid, {:connect, ssid, effective_psk})
        end
      end
    end

    for mod <- [NervesPhotos.ImmichClient, NervesPhotos.WeatherFetcher, NervesPhotos.SlideTimer] do
      if pid = Process.whereis(mod), do: GenServer.stop(pid, :normal)
    end

    conn
    |> put_resp_header("location", "/settings")
    |> send_resp(303, "")
  end

  get "/current/photo" do
    case NervesPhotos.ImmichClient.current() do
      {asset_id, _metadata} ->
        {url, api_key} = NervesPhotos.ImmichClient.connection_info()
        req_opts = Application.get_env(:nerves_photos, :req_options, [])

        req =
          Req.new([base_url: url, headers: [{"x-api-key", api_key}], retry: false] ++ req_opts)

        case Req.get(req, url: "/api/assets/#{asset_id}/thumbnail", params: [size: "preview"]) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            conn
            |> put_resp_header("content-type", "image/jpeg")
            |> send_resp(200, body)

          _ ->
            send_resp(conn, 503, "photo fetch failed")
        end

      _ ->
        send_resp(conn, 503, "no photo available")
    end
  end

  get "/current" do
    interval_ms = NervesPhotos.SettingsStore.get(:slide_interval_ms) || 30_000
    show_debug = Application.get_env(:nerves_photos, :show_debug, false)

    weather = safe_call(NervesPhotos.WeatherFetcher, :current, :unavailable)
    immich_current = safe_call(NervesPhotos.ImmichClient, :current, :loading)
    {current_pos, total} = safe_call(NervesPhotos.ImmichClient, :queue_position, {0, 0})

    {has_photo, metadata, scene_status} =
      case immich_current do
        {_id, meta} -> {true, meta, :ok}
        status -> {false, %{date: nil, location: nil}, status}
      end

    send_resp(
      conn,
      200,
      render_current(%{
        has_photo: has_photo,
        metadata: metadata,
        scene_status: scene_status,
        weather: weather,
        interval_ms: interval_ms,
        show_debug: show_debug,
        current_pos: current_pos,
        total: total
      })
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp wifi_banner(:ap) do
    """
    <div class="banner banner-warn">
      Setup mode active. Connect to WiFi network <strong>NervesPhotos-Setup</strong>
      and visit <strong>http://192.168.4.1/settings</strong> to configure.
    </div>
    """
  end

  defp wifi_banner(:connecting),
    do: "<div class=\"banner banner-info\">Connecting to WiFi&hellip;</div>"

  defp wifi_banner(:client), do: "<div class=\"banner banner-ok\">WiFi connected.</div>"
  defp wifi_banner(_), do: ""

  defp render_current(%{
         has_photo: has_photo,
         metadata: metadata,
         scene_status: scene_status,
         weather: weather,
         interval_ms: interval_ms,
         show_debug: show_debug,
         current_pos: current_pos,
         total: total
       }) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>NervesPhotos &mdash; Current</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background: black; width: 100vw; height: 100vh; overflow: hidden; }
        #scene { position: relative; width: 100%; height: 100%; }
        #photo { position: absolute; width: 100%; height: 100%; object-fit: contain; }
        .overlay { position: absolute; }
        #metadata {
          bottom: 8px; left: 16px;
          width: 400px; height: 70px;
          background: rgba(0,0,0,0.55); padding: 12px 8px;
        }
        .meta-date { color: white; font-size: 18px; font-family: sans-serif; }
        .meta-location { color: rgba(255,255,255,0.71); font-size: 15px;
                         font-family: sans-serif; margin-top: 2px; }
        #weather {
          bottom: 8px; right: 16px;
          width: 184px; height: 70px;
          background: rgba(0,0,0,0.55); padding: 12px;
        }
        .weather-temp { color: white; font-size: 20px; font-family: sans-serif; }
        .weather-cond { color: rgba(255,255,255,0.71); font-size: 14px;
                        font-family: sans-serif; margin-top: 4px; }
        #reconnecting {
          top: 16px; left: 50%; transform: translateX(-50%);
          background: rgba(0,0,0,0.63); color: rgb(255,204,68);
          font-size: 16px; font-family: sans-serif;
          padding: 7px 16px; border-radius: 15px; white-space: nowrap;
        }
        .centered-msg {
          top: 50%; left: 50%; transform: translate(-50%,-50%);
          background: rgba(0,0,0,0.63); color: white;
          font-size: 16px; font-family: sans-serif;
          padding: 9px 16px; border-radius: 8px; white-space: nowrap;
        }
        #debug {
          bottom: 8px; left: 50%; transform: translateX(-50%);
          width: 80px; height: 28px;
          background: rgba(0,0,0,0.63); color: white;
          font-size: 16px; font-family: sans-serif;
          border-radius: 6px; display: flex; align-items: center; justify-content: center;
        }
      </style>
      <script>setTimeout(() => location.reload(), #{interval_ms})</script>
    </head>
    <body>
    <div id="scene">
      #{if has_photo, do: ~s(<img id="photo" src="/current/photo" alt="">), else: ""}
      #{render_metadata_overlay(metadata)}
      #{render_weather_overlay(weather)}
      #{render_scene_status(scene_status)}
      #{if show_debug, do: ~s(<div id="debug" class="overlay">#{current_pos}/#{total}</div>), else: ""}
    </div>
    </body>
    </html>
    """
  end

  defp render_metadata_overlay(meta) do
    date_html =
      if meta[:date],
        do: ~s(<div class="meta-date">#{format_photo_date(meta[:date])}</div>),
        else: ""

    loc_html =
      if meta[:location],
        do: ~s(<div class="meta-location">#{Plug.HTML.html_escape(meta[:location])}</div>),
        else: ""

    if date_html == "" and loc_html == "" do
      ""
    else
      ~s(<div id="metadata" class="overlay">#{date_html}#{loc_html}</div>)
    end
  end

  defp render_weather_overlay(:unavailable) do
    ~s(<div id="weather" class="overlay"><div class="weather-cond">No weather data</div></div>)
  end

  defp render_weather_overlay({:ok, %{temp_f: temp, condition: condition}}) do
    ~s(<div id="weather" class="overlay"><div class="weather-temp">#{round(temp)}°F</div><div class="weather-cond">#{Plug.HTML.html_escape(condition)}</div></div>)
  end

  defp render_scene_status(:ok), do: ""

  defp render_scene_status(:disconnected) do
    ~s(<div id="reconnecting" class="overlay">Reconnecting...</div>)
  end

  defp render_scene_status(:loading) do
    ~s(<div class="centered-msg overlay">Loading...</div>)
  end

  defp render_scene_status(:empty) do
    ~s(<div class="centered-msg overlay">No photos found in album</div>)
  end

  defp render_scene_status(:not_configured) do
    ~s(<div class="centered-msg overlay">Not configured</div>)
  end

  defp format_photo_date(date), do: Calendar.strftime(date, "%B %-d, %Y")

  # Guards against the process dying between whereis/1 and the call, which can
  # happen during the restart window after POST /settings stops services.
  defp safe_call(name, msg, default) do
    case Process.whereis(name) do
      nil ->
        default

      pid ->
        try do
          GenServer.call(pid, msg, 2_000)
        catch
          :exit, _ -> default
        end
    end
  end

  defp render_form(s, wifi_mode) do
    interval_s = div(Map.get(s, :slide_interval_ms, 30_000), 1_000)
    wifi_banner = wifi_banner(wifi_mode)

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
      .banner { padding: 12px; border-radius: 4px; margin-bottom: 16px; font-size: 14px; }
      .banner-warn { background: #fef3c7; color: #92400e; }
      .banner-info { background: #dbeafe; color: #1e40af; }
      .banner-ok   { background: #d1fae5; color: #065f46; }
    </style>
    </head>
    <body>
    <h1>NervesPhotos Settings</h1>
    #{wifi_banner}
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
      <h2>Weather</h2>
      <label>ZIP Code (leave blank to use IP location)
        <input name="weather_zip" value="#{Map.get(s, :weather_zip) || ""}">
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
      <button type="submit">Save</button>
    </form>
    </body>
    </html>
    """
  end
end

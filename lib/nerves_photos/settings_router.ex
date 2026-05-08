defmodule NervesPhotos.SettingsRouter do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason)
  plug(:dispatch)

  @valid_source_types ~w(immich google_photos)
  @source_param_keys ~w(type url api_key album_id share_url)

  get "/settings" do
    settings = NervesPhotos.SettingsStore.all()

    wifi_mode =
      if pid = Process.whereis(NervesPhotos.ConnectivityMonitor) do
        GenServer.call(pid, :mode)
      end

    send_resp(conn, 200, render_page(settings, wifi_mode))
  end

  post "/settings" do
    params = conn.body_params

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

    for mod <- [NervesPhotos.PhotoQueue, NervesPhotos.WeatherFetcher, NervesPhotos.SlideTimer] do
      if pid = Process.whereis(mod), do: GenServer.stop(pid, :normal)
    end

    conn
    |> put_resp_header("location", "/settings")
    |> send_resp(303, "")
  end

  get "/settings/photo_sources" do
    sources = NervesPhotos.SettingsStore.get(:photo_sources) || []

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(sources))
  end

  post "/settings/photo_sources" do
    source = atomize_source_params(conn.body_params)

    if source[:type] in @valid_source_types do
      current = NervesPhotos.SettingsStore.get(:photo_sources) || []
      NervesPhotos.SettingsStore.put(:photo_sources, current ++ [source])

      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(201, Jason.encode!(source))
    else
      send_resp(conn, 422, Jason.encode!(%{error: "unknown source type"}))
    end
  end

  delete "/settings/photo_sources/:index" do
    sources = NervesPhotos.SettingsStore.get(:photo_sources) || []

    case Integer.parse(conn.params["index"]) do
      {idx, ""} when idx >= 0 and idx < length(sources) ->
        updated = List.delete_at(sources, idx)
        NervesPhotos.SettingsStore.put(:photo_sources, updated)

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(updated))

      {idx, ""} when idx >= 0 ->
        send_resp(conn, 404, Jason.encode!(%{error: "index out of bounds"}))

      _ ->
        send_resp(conn, 400, Jason.encode!(%{error: "invalid index"}))
    end
  end

  put "/settings/photo_sources/:index" do
    sources = NervesPhotos.SettingsStore.get(:photo_sources) || []
    source = atomize_source_params(conn.body_params)

    case Integer.parse(conn.params["index"]) do
      {idx, ""} when idx >= 0 and idx < length(sources) ->
        if source[:type] in @valid_source_types do
          merged = Map.merge(Enum.at(sources, idx), source)
          updated = List.replace_at(sources, idx, merged)
          NervesPhotos.SettingsStore.put(:photo_sources, updated)

          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(200, Jason.encode!(merged))
        else
          send_resp(conn, 422, Jason.encode!(%{error: "unknown source type"}))
        end

      {idx, ""} when idx >= 0 ->
        send_resp(conn, 404, Jason.encode!(%{error: "index out of bounds"}))

      _ ->
        send_resp(conn, 400, Jason.encode!(%{error: "invalid index"}))
    end
  end

  get "/current/photo" do
    case safe_call(NervesPhotos.PhotoQueue, :current, nil) do
      {module, source_id, config, _meta} ->
        case module.fetch_image(source_id, config) do
          {:ok, body} when is_binary(body) ->
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
    photo_current = safe_call(NervesPhotos.PhotoQueue, :current, :loading)
    {current_pos, total} = safe_call(NervesPhotos.PhotoQueue, :queue_position, {0, 0})

    {has_photo, metadata, scene_status} =
      case photo_current do
        {_module, _id, _config, meta} -> {true, meta, :ok}
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

  defp render_page(s, wifi_mode) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>NervesPhotos Settings</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: sans-serif; background: #f8f9fa; min-height: 100vh; }
        .page { display: flex; min-height: 100vh; }
        .sidebar { width: 200px; background: #1e293b; flex-shrink: 0; padding-top: 24px; }
        .sidebar-title { color: #64748b; font-size: 11px; letter-spacing: 1px; text-transform: uppercase; padding: 0 20px 12px; }
        .nav-item { display: block; padding: 10px 20px; color: #94a3b8; cursor: pointer; font-size: 14px; border-left: 3px solid transparent; }
        .nav-item.active { color: #e2e8f0; background: #334155; border-left-color: #3b82f6; }
        .nav-item.disabled { color: #475569; cursor: default; }
        .nav-soon { font-size: 11px; color: #475569; margin-left: 4px; }
        .content { flex: 1; padding: 32px; max-width: 520px; }
        .section-title { font-size: 18px; font-weight: 600; color: #1e293b; margin-bottom: 24px; }
        label { display: block; margin-top: 16px; font-size: 13px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; }
        input[type=text], input[type=number], input[type=password] { width: 100%; padding: 8px 10px; margin-top: 4px; box-sizing: border-box; font-size: 15px; border: 1px solid #cbd5e1; border-radius: 4px; }
        .btn-primary { margin-top: 24px; padding: 9px 20px; background: #3b82f6; color: white; border: none; font-size: 14px; border-radius: 4px; cursor: pointer; }
        .btn-secondary { padding: 7px 14px; background: #e2e8f0; color: #475569; border: none; font-size: 13px; border-radius: 4px; cursor: pointer; }
        .btn-danger { padding: 7px 10px; background: transparent; color: #ef4444; border: 1px solid #fecaca; font-size: 12px; border-radius: 4px; cursor: pointer; }
        .banner { padding: 12px; border-radius: 4px; margin-bottom: 16px; font-size: 14px; }
        .banner-warn { background: #fef3c7; color: #92400e; }
        .banner-info { background: #dbeafe; color: #1e40af; }
        .banner-ok   { background: #d1fae5; color: #065f46; }
        .source-row { background: white; border: 1px solid #e2e8f0; border-radius: 6px; margin-bottom: 8px; }
        .source-header { display: flex; justify-content: space-between; align-items: center; padding: 10px 14px; }
        .source-type { font-size: 13px; font-weight: 600; }
        .source-type-immich { color: #3b82f6; }
        .source-type-google { color: #10b981; }
        .source-desc { font-size: 12px; color: #94a3b8; margin-left: 8px; }
        .source-actions { display: flex; gap: 8px; }
        .inline-form { border-top: 1px solid #e2e8f0; padding: 14px; }
        .add-source-btn { display: block; width: 100%; padding: 10px; margin-top: 8px; background: white; border: 1px dashed #cbd5e1; border-radius: 6px; color: #64748b; font-size: 13px; text-align: center; cursor: pointer; }
        .add-source-btn:hover { background: #f1f5f9; }
        .wifi-status { font-size: 13px; color: #64748b; margin-top: 8px; }
      </style>
    </head>
    <body>
    <div class="page">
      #{render_sidebar("display")}
      <div class="content">
        #{wifi_banner(wifi_mode)}
        <div id="section-display">#{render_display_section(s)}</div>
        <div id="section-wifi" style="display:none">#{render_wifi_section(s, wifi_mode)}</div>
        <div id="section-sources" style="display:none">#{render_sources_section(s)}</div>
        <div id="section-users" style="display:none">#{render_users_placeholder()}</div>
      </div>
    </div>
    #{render_settings_js()}
    </body>
    </html>
    """
  end

  defp render_sidebar(active) do
    items = [
      {"display", "Display"},
      {"wifi", "WiFi"},
      {"sources", "Photo Sources"}
    ]

    nav_links =
      Enum.map_join(items, "\n", fn {id, label} ->
        class = if id == active, do: "nav-item active", else: "nav-item"
        "<a class=\"#{class}\" onclick=\"showSection('#{id}')\">#{label}</a>"
      end)

    """
    <div class="sidebar">
      <div class="sidebar-title">Settings</div>
      #{nav_links}
      <a class="nav-item disabled">Users <span class="nav-soon">(soon)</span></a>
    </div>
    """
  end

  defp render_display_section(s) do
    interval_s = div(Map.get(s, :slide_interval_ms, 30_000), 1_000)
    zip = Plug.HTML.html_escape(Map.get(s, :weather_zip) || "")

    """
    <div class="section-title">Display</div>
    <form method="POST" action="/settings">
      <label>Slide Interval (seconds)
        <input type="number" name="slide_interval_ms" min="5" value="#{interval_s}">
      </label>
      <label>Weather ZIP Code
        <input type="text" name="weather_zip" value="#{zip}" placeholder="Leave blank for IP location">
      </label>
      <button type="submit" class="btn-primary">Save</button>
    </form>
    """
  end

  defp render_wifi_section(s, wifi_mode) do
    ssid = Plug.HTML.html_escape(Map.get(s, :wifi_ssid) || "")

    status_text =
      case wifi_mode do
        :client -> "Connected"
        :connecting -> "Connecting..."
        :ap -> "Access Point (setup mode)"
        _ -> "Unknown"
      end

    """
    <div class="section-title">WiFi</div>
    <form method="POST" action="/settings">
      <label>Network Name (SSID)
        <input type="text" name="wifi_ssid" value="#{ssid}">
      </label>
      <label>Password
        <input type="password" name="wifi_psk" placeholder="Leave blank to keep current">
      </label>
      <div class="wifi-status">Status: #{status_text}</div>
      <button type="submit" class="btn-primary">Save</button>
    </form>
    """
  end

  defp render_sources_section(s) do
    sources = Map.get(s, :photo_sources) || []

    source_rows =
      sources
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {source, idx} ->
        {type_label, type_class, desc} =
          case source[:type] do
            "immich" ->
              host = URI.parse(source[:url] || "").host || source[:url] || ""
              {"Immich", "source-type-immich", Plug.HTML.html_escape(host)}

            "google_photos" ->
              {"Google Photos", "source-type-google", "Shared album"}

            other ->
              {Plug.HTML.html_escape(other || ""), "", ""}
          end

        """
        <div class="source-row" id="source-row-#{idx}">
          <div class="source-header">
            <div>
              <span class="source-type #{type_class}">#{type_label}</span>
              <span class="source-desc">#{desc}</span>
            </div>
            <div class="source-actions">
              <button class="btn-secondary" type="button" onclick="toggleEdit(#{idx})">Edit</button>
              <button class="btn-danger" type="button" onclick="deleteSource(#{idx})">Delete</button>
            </div>
          </div>
          <div id="edit-form-#{idx}" style="display:none" class="inline-form">
            #{render_edit_form(source, idx)}
          </div>
        </div>
        """
      end)

    empty_msg =
      if sources == [],
        do: ~s(<p style="color:#94a3b8;font-size:14px">No photo sources configured yet.</p>),
        else: ""

    """
    <div class="section-title">Photo Sources</div>
    #{empty_msg}
    #{source_rows}
    <div id="add-immich-btn" class="add-source-btn" onclick="toggleAddForm('immich')">+ Add Immich Album</div>
    <div id="add-google-btn" class="add-source-btn" onclick="toggleAddForm('google')">+ Add Google Photos Album</div>
    <div id="add-immich-form" style="display:none" class="source-row">
      <div class="inline-form">
        #{render_add_immich_form()}
      </div>
    </div>
    <div id="add-google-form" style="display:none" class="source-row">
      <div class="inline-form">
        #{render_add_google_form()}
      </div>
    </div>
    """
  end

  defp render_edit_form(source, idx) do
    case source[:type] do
      "immich" ->
        url = Plug.HTML.html_escape(source[:url] || "")
        album_id = Plug.HTML.html_escape(source[:album_id] || "")

        """
        <div style="font-size:13px;font-weight:600;color:#3b82f6;margin-bottom:12px">Edit Immich Album</div>
        <form onsubmit="submitEditForm(event, #{idx})">
          <input type="hidden" name="type" value="immich">
          <label>Server URL
            <input type="text" name="url" value="#{url}">
          </label>
          <label>API Key
            <input type="text" name="api_key" placeholder="Leave blank to keep current">
          </label>
          <label>Album ID
            <input type="text" name="album_id" value="#{album_id}">
          </label>
          <div style="display:flex;gap:8px;margin-top:16px">
            <button type="submit" class="btn-primary">Save</button>
            <button type="button" class="btn-secondary" onclick="toggleEdit(#{idx})">Cancel</button>
          </div>
        </form>
        """

      "google_photos" ->
        share_url = Plug.HTML.html_escape(source[:share_url] || "")

        """
        <div style="font-size:13px;font-weight:600;color:#10b981;margin-bottom:12px">Edit Google Photos Album</div>
        <form onsubmit="submitEditForm(event, #{idx})">
          <input type="hidden" name="type" value="google_photos">
          <label>Share URL
            <input type="text" name="share_url" value="#{share_url}">
          </label>
          <div style="display:flex;gap:8px;margin-top:16px">
            <button type="submit" class="btn-primary">Save</button>
            <button type="button" class="btn-secondary" onclick="toggleEdit(#{idx})">Cancel</button>
          </div>
        </form>
        """

      _ ->
        ""
    end
  end

  defp render_add_immich_form do
    """
    <div style="font-size:13px;font-weight:600;color:#3b82f6;margin-bottom:12px">Add Immich Album</div>
    <form onsubmit="submitAddForm(event, 'immich')">
      <input type="hidden" name="type" value="immich">
      <label>Server URL
        <input type="text" name="url" placeholder="http://192.168.1.10:2283">
      </label>
      <label>API Key
        <input type="text" name="api_key" placeholder="Your Immich API key">
      </label>
      <label>Album ID
        <input type="text" name="album_id" placeholder="Album UUID">
      </label>
      <div style="display:flex;gap:8px;margin-top:16px">
        <button type="submit" class="btn-primary">Save</button>
        <button type="button" class="btn-secondary" onclick="toggleAddForm('immich')">Cancel</button>
      </div>
    </form>
    """
  end

  defp render_add_google_form do
    """
    <div style="font-size:13px;font-weight:600;color:#10b981;margin-bottom:12px">Add Google Photos Album</div>
    <form onsubmit="submitAddForm(event, 'google')">
      <input type="hidden" name="type" value="google_photos">
      <label>Share URL
        <input type="text" name="share_url" placeholder="https://photos.app.goo.gl/...">
      </label>
      <div style="display:flex;gap:8px;margin-top:16px">
        <button type="submit" class="btn-primary">Save</button>
        <button type="button" class="btn-secondary" onclick="toggleAddForm('google')">Cancel</button>
      </div>
    </form>
    """
  end

  defp render_users_placeholder, do: ""
  defp render_settings_js, do: ""

  defp atomize_source_params(params) do
    for k <- @source_param_keys,
        v = params[k],
        v != nil,
        into: %{},
        do: {String.to_existing_atom(k), v}
  end
end

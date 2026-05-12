defmodule NervesPhotos.SettingsRouter do
  @moduledoc false
  use Plug.Router
  import Plug.Conn

  plug(:put_secret_key_base)

  plug(Plug.Session,
    store: :ets,
    key: "_nerves_photos_session",
    signing_salt: "nerves_photos_sess",
    table: :nerves_photos_sessions
  )

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason)
  plug(Plug.CSRFProtection)
  plug(NervesPhotos.AuthPlug)
  plug(:dispatch)

  @valid_source_types ~w(immich google_photos)
  @source_param_keys ~w(type url api_key album_id share_url)

  match("/login", do: NervesPhotos.AuthRouter.call(conn, []))
  match("/logout", do: NervesPhotos.AuthRouter.call(conn, []))
  forward("/settings/users", to: NervesPhotos.AuthRouter)

  get "/settings" do
    settings = NervesPhotos.SettingsStore.all()

    wifi_mode =
      if pid = Process.whereis(NervesPhotos.ConnectivityMonitor) do
        GenServer.call(pid, :mode)
      end

    send_resp(conn, 200, render_page(settings, wifi_mode, conn.assigns.current_user))
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
    case Bodyguard.permit(NervesPhotos.Policy, :delete_source, conn.assigns.current_user) do
      :ok ->
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

      {:error, _} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    end
  end

  put "/settings/photo_sources/:index" do
    case Bodyguard.permit(NervesPhotos.Policy, :manage_sources, conn.assigns.current_user) do
      :ok ->
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

      {:error, _} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    end
  end

  forward("/current", to: NervesPhotos.CurrentRouter)

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

  defp render_page(s, wifi_mode, current_user) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>NervesPhotos Settings</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="csrf-token" content="#{csrf}">
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: sans-serif; background: #f8f9fa; min-height: 100vh; }
        .page { display: flex; min-height: 100vh; }
        .sidebar { width: 200px; background: #1e293b; flex-shrink: 0; padding-top: 24px; display: flex; flex-direction: column; }
        .sidebar-title { color: #64748b; font-size: 11px; letter-spacing: 1px; text-transform: uppercase; padding: 0 20px 12px; }
        .nav-item { display: block; padding: 10px 20px; color: #94a3b8; cursor: pointer; font-size: 14px; border-left: 3px solid transparent; }
        .nav-item.active { color: #e2e8f0; background: #334155; border-left-color: #3b82f6; }
        .nav-item.disabled { color: #475569; cursor: default; }
        .nav-soon { font-size: 11px; color: #475569; margin-left: 4px; }
        .content { flex: 1; padding: 32px; max-width: 520px; }
        .section-title { font-size: 18px; font-weight: 600; color: #1e293b; margin-bottom: 24px; }
        label { display: block; margin-top: 16px; font-size: 13px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; }
        input[type=text], input[type=number], input[type=password] { width: 100%; padding: 8px 10px; margin-top: 4px; box-sizing: border-box; font-size: 15px; border: 1px solid #cbd5e1; border-radius: 4px; }
        .btn-primary { padding: 9px 20px; background: #3b82f6; color: white; border: none; font-size: 14px; border-radius: 4px; cursor: pointer; }
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
      #{render_sidebar("display", current_user)}
      <div class="content">
        #{wifi_banner(wifi_mode)}
        <div id="section-display">#{render_display_section(s)}</div>
        <div id="section-wifi" style="display:none">#{render_wifi_section(s, wifi_mode)}</div>
        <div id="section-sources" style="display:none">#{render_sources_section(s)}</div>
        <div id="section-users" style="display:none"></div>
      </div>
    </div>
    #{render_settings_js()}
    </body>
    </html>
    """
  end

  def render_sidebar(active, current_user, kind \\ :settings) do
    items = [
      {"display", "Display"},
      {"wifi", "WiFi"},
      {"sources", "Photo Sources"}
    ]

    nav_links =
      Enum.map_join(items, "\n", fn {id, label} ->
        class = if id == active, do: "nav-item active", else: "nav-item"

        if kind == :settings do
          "<a class=\"#{class}\" onclick=\"showSection('#{id}')\">#{label}</a>"
        else
          "<a class=\"#{class}\" href=\"/settings\">#{label}</a>"
        end
      end)

    users_link =
      if current_user && current_user.role == :admin do
        class = if active == "users", do: "nav-item active", else: "nav-item"
        ~s(<a class="#{class}" href="/settings/users">Users</a>)
      else
        ""
      end

    csrf = Plug.CSRFProtection.get_csrf_token()

    logout_name =
      if current_user && current_user.username,
        do: " (#{Plug.HTML.html_escape(current_user.username)})",
        else: ""

    """
    <div class="sidebar">
      <div class="sidebar-title">Settings</div>
      #{nav_links}
      #{users_link}
      <form method="POST" action="/logout" style="padding:10px 20px;margin-top:auto">
        <input type="hidden" name="_csrf_token" value="#{csrf}">
        <button type="submit" style="background:none;border:none;color:#64748b;font-size:12px;cursor:pointer;padding:0;text-align:left">
          Sign out#{logout_name}
        </button>
      </form>
    </div>
    """
  end

  defp render_display_section(s) do
    interval_s = div(Map.get(s, :slide_interval_ms, 30_000), 1_000)
    zip = Plug.HTML.html_escape(Map.get(s, :weather_zip) || "")
    csrf = Plug.CSRFProtection.get_csrf_token()

    """
    <div class="section-title">Display</div>
    <form method="POST" action="/settings">
      <input type="hidden" name="_csrf_token" value="#{csrf}">
      <label>Slide Interval (seconds)
        <input type="number" name="slide_interval_ms" min="5" value="#{interval_s}">
      </label>
      <label>Weather ZIP Code
        <input type="text" name="weather_zip" value="#{zip}" placeholder="Leave blank for IP location">
      </label>
      <button type="submit" class="btn-primary" style="margin-top:24px">Save</button>
    </form>
    """
  end

  defp render_wifi_section(s, wifi_mode) do
    ssid = Plug.HTML.html_escape(Map.get(s, :wifi_ssid) || "")
    csrf = Plug.CSRFProtection.get_csrf_token()

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
      <input type="hidden" name="_csrf_token" value="#{csrf}">
      <label>Network Name (SSID)
        <input type="text" name="wifi_ssid" value="#{ssid}">
      </label>
      <label>Password
        <input type="password" name="wifi_psk" placeholder="Leave blank to keep current">
      </label>
      <div class="wifi-status">Status: #{Plug.HTML.html_escape(status_text)}</div>
      <button type="submit" class="btn-primary" style="margin-top:24px">Save</button>
    </form>
    """
  end

  defp render_source_row({source, idx}) do
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
  end

  defp render_sources_section(s) do
    sources = Map.get(s, :photo_sources) || []

    source_rows =
      sources
      |> Enum.with_index()
      |> Enum.map_join("\n", &render_source_row/1)

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
    <form onsubmit="submitAddForm(event)">
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
    <form onsubmit="submitAddForm(event)">
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

  defp render_settings_js do
    """
    <script>
    var SECTIONS = ['display','wifi','sources','users'];

    function getCsrfToken() {
      var meta = document.querySelector('meta[name="csrf-token"]');
      return meta ? meta.getAttribute('content') : '';
    }

    function showSection(id) {
      SECTIONS.forEach(function(s) {
        var el = document.getElementById('section-' + s);
        if (el) el.style.display = s === id ? 'block' : 'none';
      });
      document.querySelectorAll('.nav-item').forEach(function(el) {
        el.classList.remove('active');
      });
      var active = document.querySelector('[onclick="showSection(\\'' + id + '\\')"]');
      if (active) active.classList.add('active');
    }

    function toggleEdit(idx) {
      var form = document.getElementById('edit-form-' + idx);
      if (!form) return;
      var isOpen = form.style.display !== 'none';
      closeAllForms();
      if (!isOpen) form.style.display = 'block';
    }

    function toggleAddForm(type) {
      var id = type === 'immich' ? 'add-immich-form' : 'add-google-form';
      var form = document.getElementById(id);
      if (!form) return;
      var isOpen = form.style.display !== 'none';
      closeAllForms();
      if (!isOpen) form.style.display = 'block';
    }

    function closeAllForms() {
      document.querySelectorAll('[id^="edit-form-"]').forEach(function(el) {
        el.style.display = 'none';
      });
      ['add-immich-form','add-google-form'].forEach(function(id) {
        var el = document.getElementById(id);
        if (el) el.style.display = 'none';
      });
    }

    function deleteSource(idx) {
      if (!confirm('Delete this photo source?')) return;
      fetch('/settings/photo_sources/' + idx, {
        method: 'DELETE',
        headers: {'x-csrf-token': getCsrfToken()}
      })
        .then(function(r) {
          if (r.ok) { location.reload(); }
          else { r.json().then(function(e) { alert(e.error || 'Delete failed'); }); }
        })
        .catch(function() { alert('Network error. Please try again.'); });
    }

    function submitAddForm(event) {
      event.preventDefault();
      var form = event.target;
      var data = {};
      new FormData(form).forEach(function(v, k) { data[k] = v; });
      fetch('/settings/photo_sources', {
        method: 'POST',
        headers: {'Content-Type': 'application/json', 'x-csrf-token': getCsrfToken()},
        body: JSON.stringify(data)
      }).then(function(r) {
        if (r.ok) { location.reload(); }
        else { r.json().then(function(e) { alert(e.error || 'Save failed'); }); }
      }).catch(function() { alert('Network error. Please try again.'); });
    }

    function submitEditForm(event, idx) {
      event.preventDefault();
      var form = event.target;
      var data = {};
      new FormData(form).forEach(function(v, k) { if (v !== '') data[k] = v; });
      fetch('/settings/photo_sources/' + idx, {
        method: 'PUT',
        headers: {'Content-Type': 'application/json', 'x-csrf-token': getCsrfToken()},
        body: JSON.stringify(data)
      }).then(function(r) {
        if (r.ok) { location.reload(); }
        else { r.json().then(function(e) { alert(e.error || 'Save failed'); }); }
      }).catch(function() { alert('Network error. Please try again.'); });
    }
    </script>
    """
  end

  defp atomize_source_params(params) do
    for k <- @source_param_keys,
        v = params[k],
        v != nil,
        into: %{},
        do: {String.to_existing_atom(k), v}
  end

  defp put_secret_key_base(conn, _opts) do
    put_in(conn.secret_key_base, Application.get_env(:nerves_photos, :secret_key_base))
  end
end

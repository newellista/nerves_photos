# Settings UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single monolithic `/settings` form with a sidebar-navigated layout containing discrete Display, WiFi, Photo Sources, and Users (placeholder) sections.

**Architecture:** All changes are confined to `lib/nerves_photos/settings_router.ex` and its test file. `render_form/2` is replaced by `render_page/2` which composes section-rendering helpers. A new `PUT /settings/photo_sources/:index` route is added. All JS is inlined; no external dependencies.

**Tech Stack:** Elixir, Plug.Router, Cowboy, inline HTML strings, `Plug.HTML.html_escape/1`, `Jason`, `ExUnit` + `Plug.Test`

---

### Task 1: Add `PUT /settings/photo_sources/:index` route and tests

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` (add route after the `delete` route, ~line 97)
- Modify: `test/nerves_photos/settings_router_test.exs` (add describe block after DELETE tests)

- [ ] **Step 1: Write the failing tests**

Add this describe block to `test/nerves_photos/settings_router_test.exs` after the `DELETE` describe block:

```elixir
describe "PUT /settings/photo_sources/:index" do
  setup do
    path = "/tmp/nerves_photos_test_put_#{:erlang.unique_integer([:positive])}.json"
    start_supervised!({NervesPhotos.SettingsStore, [path: path]})

    NervesPhotos.SettingsStore.put(:photo_sources, [
      %{type: "immich", url: "http://a", api_key: "k1", album_id: "a1"},
      %{type: "google_photos", share_url: "https://photos.app.goo.gl/x"}
    ])

    :ok
  end

  test "replaces source at given index" do
    body = Jason.encode!(%{type: "immich", url: "http://new", api_key: "k2", album_id: "a2"})

    conn =
      conn(:put, "/settings/photo_sources/0", body)
      |> put_req_header("content-type", "application/json")
      |> NervesPhotos.SettingsRouter.call(@opts)

    assert conn.status == 200
    sources = NervesPhotos.SettingsStore.get(:photo_sources)
    assert length(sources) == 2
    assert hd(sources)[:url] == "http://new"
    assert hd(sources)[:album_id] == "a2"
  end

  test "returns updated source as JSON" do
    body = Jason.encode!(%{type: "immich", url: "http://new", api_key: "k2", album_id: "a2"})

    conn =
      conn(:put, "/settings/photo_sources/0", body)
      |> put_req_header("content-type", "application/json")
      |> NervesPhotos.SettingsRouter.call(@opts)

    assert conn.status == 200
    result = Jason.decode!(conn.resp_body)
    assert result["url"] == "http://new"
  end

  test "returns 404 for out-of-bounds index" do
    body = Jason.encode!(%{type: "immich", url: "http://new", api_key: "k2", album_id: "a2"})

    conn =
      conn(:put, "/settings/photo_sources/5", body)
      |> put_req_header("content-type", "application/json")
      |> NervesPhotos.SettingsRouter.call(@opts)

    assert conn.status == 404
  end

  test "returns 422 for unknown source type" do
    body = Jason.encode!(%{type: "dropbox", path: "/photos"})

    conn =
      conn(:put, "/settings/photo_sources/0", body)
      |> put_req_header("content-type", "application/json")
      |> NervesPhotos.SettingsRouter.call(@opts)

    assert conn.status == 422
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/steve.newell/projects/personal/nerves_photos/.worktrees/feature-multi-source-photos
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -20
```

Expected: 4 failures — no `PUT /settings/photo_sources/:index` route exists yet.

- [ ] **Step 3: Add the route to the router**

In `lib/nerves_photos/settings_router.ex`, add this block after the `delete "/settings/photo_sources/:index"` clause (after line 97):

```elixir
put "/settings/photo_sources/:index" do
  sources = NervesPhotos.SettingsStore.get(:photo_sources) || []
  idx = String.to_integer(conn.params["index"])
  source = for {k, v} <- conn.body_params, into: %{}, do: {String.to_atom(k), v}

  cond do
    idx < 0 or idx >= length(sources) ->
      send_resp(conn, 404, Jason.encode!(%{error: "index out of bounds"}))

    source[:type] not in @valid_source_types ->
      send_resp(conn, 422, Jason.encode!(%{error: "unknown source type"}))

    true ->
      updated = List.replace_at(sources, idx, source)
      NervesPhotos.SettingsStore.put(:photo_sources, updated)

      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, Jason.encode!(source))
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: all tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/steve.newell/projects/personal/nerves_photos/.worktrees/feature-multi-source-photos
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: add PUT /settings/photo_sources/:index route"
```

---

### Task 2: Replace `render_form/2` with sidebar page skeleton

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex`
  - Change `GET /settings` handler to call `render_page/2`
  - Delete `render_form/2`
  - Add `render_page/2` and `render_sidebar/1` with shared CSS and page chrome
  - Add stub section functions that return empty strings (filled in later tasks)

- [ ] **Step 1: Write a failing test for the sidebar structure**

Add this describe block to `test/nerves_photos/settings_router_test.exs`:

```elixir
describe "GET /settings sidebar layout" do
  setup do
    path = "/tmp/nerves_photos_test_settings_ui_#{:erlang.unique_integer([:positive])}.json"
    start_supervised!({NervesPhotos.SettingsStore, [path: path]})
    :ok
  end

  test "renders sidebar with all four nav items" do
    conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.status == 200
    assert conn.resp_body =~ "Display"
    assert conn.resp_body =~ "WiFi"
    assert conn.resp_body =~ "Photo Sources"
    assert conn.resp_body =~ "Users"
  end

  test "display section is visible by default, others hidden" do
    conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
    body = conn.resp_body
    assert body =~ ~s(id="section-display")
    assert body =~ ~s(id="section-wifi" style="display:none")
    assert body =~ ~s(id="section-sources" style="display:none")
    assert body =~ ~s(id="section-users" style="display:none")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs --only "GET /settings sidebar" 2>&1 | tail -15
```

Expected: failures — current page renders old monolithic form, no sidebar nav.

- [ ] **Step 3: Replace `render_form/2` with `render_page/2` and `render_sidebar/1`**

In `lib/nerves_photos/settings_router.ex`:

1. Change the `GET /settings` handler (lines 11–20) to:

```elixir
get "/settings" do
  settings = NervesPhotos.SettingsStore.all()

  wifi_mode =
    if pid = Process.whereis(NervesPhotos.ConnectivityMonitor) do
      GenServer.call(pid, :mode)
    end

  send_resp(conn, 200, render_page(settings, wifi_mode))
end
```

2. Delete `render_form/2` (lines 299–351).

3. Add these private functions before the closing `end` of the module:

```elixir
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
      ~s(<a class="#{class}" onclick="showSection('#{id}')">#{label}</a>)
    end)

  """
  <div class="sidebar">
    <div class="sidebar-title">Settings</div>
    #{nav_links}
    <a class="nav-item disabled">Users <span class="nav-soon">(soon)</span></a>
  </div>
  """
end

defp render_display_section(_s), do: ""
defp render_wifi_section(_s, _wifi_mode), do: ""
defp render_sources_section(_s), do: ""
defp render_users_placeholder, do: ""
defp render_settings_js, do: ""
```

- [ ] **Step 4: Run the new sidebar tests**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -15
```

Expected: sidebar layout tests pass. No other tests should regress (they don't test `render_form` output directly).

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: replace monolithic settings form with sidebar page skeleton"
```

---

### Task 3: Implement Display section

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` — fill in `render_display_section/1`

- [ ] **Step 1: Write failing test**

Add to the `GET /settings sidebar layout` describe block in the test file:

```elixir
test "display section contains slide interval and weather zip fields" do
  NervesPhotos.SettingsStore.put(:slide_interval_ms, 60_000)
  NervesPhotos.SettingsStore.put(:weather_zip, "90210")

  conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
  body = conn.resp_body
  assert body =~ ~s(name="slide_interval_ms")
  assert body =~ ~s(value="60")
  assert body =~ ~s(name="weather_zip")
  assert body =~ "90210"
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: failure — `render_display_section/1` returns `""`.

- [ ] **Step 3: Implement `render_display_section/1`**

Replace the stub `defp render_display_section(_s), do: ""` with:

```elixir
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
```

- [ ] **Step 4: Run tests**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: implement settings Display section"
```

---

### Task 4: Implement WiFi section

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` — fill in `render_wifi_section/2`

- [ ] **Step 1: Write failing test**

Add to the `GET /settings sidebar layout` describe block:

```elixir
test "wifi section contains ssid field and status" do
  NervesPhotos.SettingsStore.put(:wifi_ssid, "MyNetwork")

  conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
  body = conn.resp_body
  assert body =~ ~s(name="wifi_ssid")
  assert body =~ "MyNetwork"
  assert body =~ ~s(name="wifi_psk")
  assert body =~ "Status:"
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: failure — `render_wifi_section/2` returns `""`.

- [ ] **Step 3: Implement `render_wifi_section/2`**

Replace the stub `defp render_wifi_section(_s, _wifi_mode), do: ""` with:

```elixir
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
```

- [ ] **Step 4: Run tests**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: implement settings WiFi section"
```

---

### Task 5: Implement Photo Sources section — list and delete

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` — fill in `render_sources_section/1` with source list rows (no add/edit forms yet)

- [ ] **Step 1: Write failing tests**

Add a new describe block to the test file:

```elixir
describe "GET /settings photo sources section" do
  setup do
    path = "/tmp/nerves_photos_test_sources_ui_#{:erlang.unique_integer([:positive])}.json"
    start_supervised!({NervesPhotos.SettingsStore, [path: path]})
    :ok
  end

  test "shows empty state when no sources configured" do
    conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "No photo sources configured"
  end

  test "renders one row per configured source" do
    NervesPhotos.SettingsStore.put(:photo_sources, [
      %{type: "immich", url: "http://192.168.1.10:2283", api_key: "k", album_id: "a"},
      %{type: "google_photos", share_url: "https://photos.app.goo.gl/x"}
    ])

    conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
    body = conn.resp_body
    assert body =~ "Immich"
    assert body =~ "192.168.1.10"
    assert body =~ "Google Photos"
  end

  test "each source row has a delete button targeting the correct index" do
    NervesPhotos.SettingsStore.put(:photo_sources, [
      %{type: "immich", url: "http://srv", api_key: "k", album_id: "a"}
    ])

    conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "/settings/photo_sources/0"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -15
```

Expected: failures — `render_sources_section/1` returns `""`.

- [ ] **Step 3: Implement `render_sources_section/1`**

Replace the stub `defp render_sources_section(_s), do: ""` with:

```elixir
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
            {Plug.HTML.html_escape(other), "", ""}
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

  empty_msg = if sources == [], do: ~s(<p style="color:#94a3b8;font-size:14px">No photo sources configured yet.</p>), else: ""

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

defp render_edit_form(_source, _idx), do: ""
defp render_add_immich_form, do: ""
defp render_add_google_form, do: ""
```

- [ ] **Step 4: Run tests**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -15
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: implement Photo Sources section list with delete buttons"
```

---

### Task 6: Implement Add Immich and Add Google Photos inline forms

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` — fill in `render_add_immich_form/0` and `render_add_google_form/0`

- [ ] **Step 1: Write failing tests**

Add to the `GET /settings photo sources section` describe block:

```elixir
test "add immich form contains required fields" do
  conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
  body = conn.resp_body
  assert body =~ ~s(id="add-immich-form")
  assert body =~ ~s(name="url")
  assert body =~ ~s(name="api_key")
  assert body =~ ~s(name="album_id")
end

test "add google photos form contains share_url field" do
  conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
  body = conn.resp_body
  assert body =~ ~s(id="add-google-form")
  assert body =~ ~s(name="share_url")
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: 2 failures — add forms render empty strings.

- [ ] **Step 3: Implement the add form helpers**

Replace `defp render_add_immich_form, do: ""` with:

```elixir
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
```

Replace `defp render_add_google_form, do: ""` with:

```elixir
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
```

- [ ] **Step 4: Run tests**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: implement Add Immich and Add Google Photos inline forms"
```

---

### Task 7: Implement inline Edit form for existing sources

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` — fill in `render_edit_form/2`

- [ ] **Step 1: Write failing tests**

Add to the `GET /settings photo sources section` describe block:

```elixir
test "edit form for immich source pre-fills all fields" do
  NervesPhotos.SettingsStore.put(:photo_sources, [
    %{type: "immich", url: "http://192.168.1.10:2283", api_key: "mykey", album_id: "abc-uuid"}
  ])

  conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
  body = conn.resp_body
  assert body =~ ~s(id="edit-form-0")
  assert body =~ "http://192.168.1.10:2283"
  assert body =~ "abc-uuid"
end

test "edit form for google photos source pre-fills share_url" do
  NervesPhotos.SettingsStore.put(:photo_sources, [
    %{type: "google_photos", share_url: "https://photos.app.goo.gl/test123"}
  ])

  conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
  body = conn.resp_body
  assert body =~ ~s(id="edit-form-0")
  assert body =~ "https://photos.app.goo.gl/test123"
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: 2 failures — `render_edit_form/2` returns `""`.

- [ ] **Step 3: Implement `render_edit_form/2`**

Replace `defp render_edit_form(_source, _idx), do: ""` with:

```elixir
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
```

- [ ] **Step 4: Run tests**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: implement inline edit form for photo sources"
```

---

### Task 8: Implement JavaScript for section switching and inline forms

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` — fill in `render_settings_js/0`

- [ ] **Step 1: Write failing tests**

Add to the `GET /settings sidebar layout` describe block:

```elixir
test "page includes section-switching JavaScript" do
  conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
  body = conn.resp_body
  assert body =~ "function showSection"
  assert body =~ "function toggleEdit"
  assert body =~ "function toggleAddForm"
  assert body =~ "function deleteSource"
  assert body =~ "function submitAddForm"
  assert body =~ "function submitEditForm"
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: failure — `render_settings_js/0` returns `""`.

- [ ] **Step 3: Implement `render_settings_js/0`**

Replace `defp render_settings_js, do: ""` with:

```elixir
defp render_settings_js do
  """
  <script>
  var SECTIONS = ['display','wifi','sources','users'];

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
    fetch('/settings/photo_sources/' + idx, {method: 'DELETE'})
      .then(function() { location.reload(); });
  }

  function submitAddForm(event, type) {
    event.preventDefault();
    var form = event.target;
    var data = {};
    new FormData(form).forEach(function(v, k) { data[k] = v; });
    fetch('/settings/photo_sources', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(data)
    }).then(function(r) {
      if (r.ok) { location.reload(); }
      else { r.json().then(function(e) { alert(e.error || 'Save failed'); }); }
    });
  }

  function submitEditForm(event, idx) {
    event.preventDefault();
    var form = event.target;
    var data = {};
    new FormData(form).forEach(function(v, k) { if (v !== '') data[k] = v; });
    fetch('/settings/photo_sources/' + idx, {
      method: 'PUT',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(data)
    }).then(function(r) {
      if (r.ok) { location.reload(); }
      else { r.json().then(function(e) { alert(e.error || 'Save failed'); }); }
    });
  }
  </script>
  """
end
```

- [ ] **Step 4: Run tests**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: add inline JS for section switching and form actions"
```

---

### Task 9: Implement Users placeholder section and final cleanup

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` — fill in `render_users_placeholder/0`

- [ ] **Step 1: Write failing test**

Add to the `GET /settings sidebar layout` describe block:

```elixir
test "users section shows coming soon message" do
  conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
  assert conn.resp_body =~ "Coming soon"
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_router_test.exs 2>&1 | tail -10
```

Expected: failure — `render_users_placeholder/0` returns `""`.

- [ ] **Step 3: Implement `render_users_placeholder/0`**

Replace `defp render_users_placeholder, do: ""` with:

```elixir
defp render_users_placeholder do
  """
  <div class="section-title" style="color:#94a3b8">Users</div>
  <p style="color:#94a3b8;font-size:14px">Coming soon. User management will be added in a future release.</p>
  """
end
```

- [ ] **Step 4: Run the full test suite**

```bash
MIX_TARGET=host mix test 2>&1 | tail -15
```

Expected: all tests pass, 0 failures.

- [ ] **Step 5: Manual smoke test**

```bash
MIX_TARGET=host mix run --no-halt &
sleep 2
open http://localhost:4000/settings
```

Verify manually:
- All three active sections render and switch via sidebar clicks
- Display section shows slide interval and ZIP code; Save redirects back
- WiFi section shows SSID field and status; Save redirects back
- Photo Sources: Add Immich / Add Google Photos buttons expand inline forms
- Edit on an existing source expands inline form pre-filled with values
- Delete on an existing source removes it and reloads
- Users entry is visible in sidebar but greyed-out with "soon" label and shows coming-soon message when section is activated
- Only one inline form open at a time

Kill the server when done:
```bash
pkill -f "mix run --no-halt"
```

- [ ] **Step 6: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: add Users placeholder section, complete settings UI redesign"
```

# /current Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `GET /current` and `GET /current/photo` routes to `NervesPhotos.SettingsRouter` that render an HTML preview of the current Scenic photo frame scene in a browser.

**Architecture:** Both routes live in the existing `SettingsRouter` Plug module — no new modules. `/current/photo` proxies the current asset JPEG from Immich using the same credentials `ImmichClient` holds. `/current` returns a full-viewport HTML page with CSS-positioned overlays matching the Scenic scene geometry; the photo is loaded by the browser via `<img src="/current/photo">`. A `setTimeout(location.reload, interval_ms)` auto-refreshes the page in sync with the slide timer.

**Tech Stack:** Elixir, Plug.Router, Req, ExUnit + Plug.Test

---

### File Map

| Action | Path |
|---|---|
| Modify | `lib/nerves_photos/settings_router.ex` |
| Create | `test/nerves_photos/settings_router_test.exs` |

---

### Task 1: Add `GET /current/photo` proxy route

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex`
- Create: `test/nerves_photos/settings_router_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/nerves_photos/settings_router_test.exs`:

```elixir
defmodule NervesPhotos.SettingsRouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts NervesPhotos.SettingsRouter.init([])

  # Stub GenServers registered under the real module names so SettingsRouter
  # calls hit controlled state instead of real processes.

  defmodule ImmichStub do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: NervesPhotos.ImmichClient)
    def init(state), do: {:ok, state}
    def handle_call(:current, _, state), do: {:reply, state.current, state}
    def handle_call(:connection_info, _, state), do: {:reply, state.connection_info, state}
    def handle_call(:queue_position, _, state), do: {:reply, state.queue_position, state}
  end

  defmodule WeatherStub do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: NervesPhotos.WeatherFetcher)
    def init(state), do: {:ok, state}
    def handle_call(:current, _, state), do: {:reply, state.current, state}
  end

  # Stop any previously registered stubs before each test so start_supervised!
  # can register fresh ones under the same names.
  setup do
    for mod <- [NervesPhotos.ImmichClient, NervesPhotos.WeatherFetcher, NervesPhotos.SettingsStore] do
      if pid = Process.whereis(mod), do: GenServer.stop(pid)
    end

    Application.delete_env(:nerves_photos, :req_options)
    :ok
  end

  describe "GET /current/photo" do
    setup do
      start_supervised!(
        {ImmichStub,
         %{
           current: {"asset123", %{date: ~D[2024-06-01], location: "Paris, France"}},
           connection_info: {"http://immich.local", "test-key"},
           queue_position: {1, 5}
         }}
      )

      Application.put_env(:nerves_photos, :req_options,
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
          |> Plug.Conn.send_resp(200, <<0xFF, 0xD8, 0xFF, 0xE0>>)
        end
      )

      on_exit(fn -> Application.delete_env(:nerves_photos, :req_options) end)
      :ok
    end

    test "returns JPEG bytes with correct content-type" do
      conn = conn(:get, "/current/photo") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert conn.resp_body == <<0xFF, 0xD8, 0xFF, 0xE0>>
    end

    test "returns 503 when ImmichClient has no photo" do
      GenServer.stop(Process.whereis(NervesPhotos.ImmichClient))
      {:ok, _} = ImmichStub.start_link(%{current: :loading, connection_info: {"", ""}, queue_position: {0, 0}})

      conn = conn(:get, "/current/photo") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.status == 503
    end

    test "returns 503 when Immich fetch returns non-200" do
      Application.put_env(:nerves_photos, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 500, "error") end
      )

      conn = conn(:get, "/current/photo") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.status == 503
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```
mix test test/nerves_photos/settings_router_test.exs --seed 0
```

Expected: 3 failures — route returns 404 because `/current/photo` doesn't exist yet.

- [ ] **Step 3: Add `GET /current/photo` route to SettingsRouter**

In `lib/nerves_photos/settings_router.ex`, insert this route after the existing `post "/settings"` block and before `match _`:

```elixir
get "/current/photo" do
  case NervesPhotos.ImmichClient.current() do
    {asset_id, _metadata} ->
      {url, api_key} = NervesPhotos.ImmichClient.connection_info()
      req_opts = Application.get_env(:nerves_photos, :req_options, [])
      req = Req.new([base_url: url, headers: [{"x-api-key", api_key}]] ++ req_opts)

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
```

- [ ] **Step 4: Run tests to verify they pass**

```
mix test test/nerves_photos/settings_router_test.exs --seed 0
```

Expected: `3 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: add GET /current/photo proxy route"
```

---

### Task 2: Add `GET /current` HTML scene preview route

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex`
- Modify: `test/nerves_photos/settings_router_test.exs`

- [ ] **Step 1: Write failing tests for the HTML route**

Add this describe block to `test/nerves_photos/settings_router_test.exs`, after the `"GET /current/photo"` describe block:

```elixir
describe "GET /current" do
  setup do
    # SettingsStore must be running; pass a nonexistent path so it starts
    # with defaults (slide_interval_ms = 30_000) without writing any files.
    start_supervised!({NervesPhotos.SettingsStore, [path: "/tmp/nerves_photos_test_settings.json"]})

    start_supervised!(
      {ImmichStub,
       %{
         current: {"asset123", %{date: ~D[2024-06-01], location: "Paris, France"}},
         connection_info: {"http://immich.local", "test-key"},
         queue_position: {3, 20}
       }}
    )

    start_supervised!(
      {WeatherStub, %{current: {:ok, %{temp_f: 72.5, condition: "Sunny"}}}}
    )

    :ok
  end

  test "returns 200 with photo img tag" do
    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.status == 200
    assert conn.resp_body =~ ~s(<img id="photo" src="/current/photo")
  end

  test "includes metadata overlay with date and location" do
    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "June 1, 2024"
    assert conn.resp_body =~ "Paris, France"
  end

  test "includes weather overlay with temperature and condition" do
    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "73°F"
    assert conn.resp_body =~ "Sunny"
  end

  test "includes auto-refresh script with slide interval" do
    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "setTimeout"
    assert conn.resp_body =~ "location.reload"
    assert conn.resp_body =~ "30000"
  end

  test "shows Reconnecting banner and no photo when disconnected" do
    GenServer.stop(Process.whereis(NervesPhotos.ImmichClient))
    {:ok, _} = ImmichStub.start_link(%{current: :disconnected, connection_info: {"", ""}, queue_position: {0, 0}})

    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "Reconnecting..."
    refute conn.resp_body =~ ~s(<img id="photo")
  end

  test "shows Loading message when loading" do
    GenServer.stop(Process.whereis(NervesPhotos.ImmichClient))
    {:ok, _} = ImmichStub.start_link(%{current: :loading, connection_info: {"", ""}, queue_position: {0, 0}})

    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "Loading..."
    refute conn.resp_body =~ ~s(<img id="photo")
  end

  test "shows no photos message when album is empty" do
    GenServer.stop(Process.whereis(NervesPhotos.ImmichClient))
    {:ok, _} = ImmichStub.start_link(%{current: :empty, connection_info: {"", ""}, queue_position: {0, 0}})

    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "No photos found in album"
    refute conn.resp_body =~ ~s(<img id="photo")
  end

  test "shows not configured message" do
    GenServer.stop(Process.whereis(NervesPhotos.ImmichClient))
    {:ok, _} = ImmichStub.start_link(%{current: :not_configured, connection_info: {nil, nil}, queue_position: {0, 0}})

    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "Not configured"
    refute conn.resp_body =~ ~s(<img id="photo")
  end

  test "shows No weather data when weather is unavailable" do
    GenServer.stop(Process.whereis(NervesPhotos.WeatherFetcher))
    {:ok, _} = WeatherStub.start_link(%{current: :unavailable})

    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ "No weather data"
  end

  test "shows debug bar when show_debug is true" do
    Application.put_env(:nerves_photos, :show_debug, true)
    on_exit(fn -> Application.delete_env(:nerves_photos, :show_debug) end)

    conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
    assert conn.resp_body =~ ~s(id="debug")
    assert conn.resp_body =~ "3/20"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```
mix test test/nerves_photos/settings_router_test.exs --seed 0
```

Expected: 9 new failures — `/current` returns 404.

- [ ] **Step 3: Add `GET /current` route and all render helpers**

In `lib/nerves_photos/settings_router.ex`, insert this route after `get "/current/photo"` and before `match _`:

```elixir
get "/current" do
  interval_ms = NervesPhotos.SettingsStore.get(:slide_interval_ms) || 30_000
  weather = NervesPhotos.WeatherFetcher.current()
  show_debug = Application.get_env(:nerves_photos, :show_debug, false)
  {current_pos, total} = NervesPhotos.ImmichClient.queue_position()

  {has_photo, metadata, scene_status} =
    case NervesPhotos.ImmichClient.current() do
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
```

Add these private functions after the existing `defp render_form/2` at the bottom of `lib/nerves_photos/settings_router.ex`:

```elixir
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

defp render_metadata_overlay(%{date: nil, location: nil}), do: ""

defp render_metadata_overlay(%{date: date, location: location}) do
  date_html = if date, do: ~s(<div class="meta-date">#{format_photo_date(date)}</div>), else: ""
  loc_html = if location, do: ~s(<div class="meta-location">#{location}</div>), else: ""

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
  ~s(<div id="weather" class="overlay"><div class="weather-temp">#{round(temp)}°F</div><div class="weather-cond">#{condition}</div></div>)
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
```

- [ ] **Step 4: Run router tests to verify they pass**

```
mix test test/nerves_photos/settings_router_test.exs --seed 0
```

Expected: `12 tests, 0 failures`

- [ ] **Step 5: Run full test suite**

```
mix test
```

Expected: all tests pass. Fix any compilation warnings before continuing.

- [ ] **Step 6: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: add GET /current scene preview endpoint"
```

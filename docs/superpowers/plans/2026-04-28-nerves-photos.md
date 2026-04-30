# NervesPhotos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a full-screen Nerves photo frame that streams shuffled photos from an Immich album with weather and metadata overlays.

**Architecture:** Five GenServers (`ImmichClient`, `WeatherFetcher`, `SlideTimer`, `ImageLoader`, and the Scenic viewport) run under a `one_for_one` supervisor. `Scene.Main` is a pure renderer that reads state from GenServers on each slide tick. Photo transitions are crossfade on RPi5 and fade-to-black on RPi0, selected at compile time via `Mix.target()`.

**Tech Stack:** Elixir/Nerves, Scenic 0.11, `scenic_driver_local` (DRM), `Req` for HTTP, Immich REST API, Open-Meteo API, `ip-api.com` for geolocation.

---

## File Map

| File | Purpose |
|---|---|
| `lib/nerves_photos/application.ex` | Add all GenServers + Scenic viewport to supervisor |
| `lib/nerves_photos/immich_client.ex` | GenServer: album fetch, shuffle queue, advance |
| `lib/nerves_photos/weather_fetcher.ex` | GenServer: IP geolocation + Open-Meteo polling |
| `lib/nerves_photos/slide_timer.ex` | GenServer: interval ticker → Scene.Main |
| `lib/nerves_photos/image_loader.ex` | GenServer: fetch Immich preview → Scenic stream |
| `lib/nerves_photos/scene/main.ex` | Scenic scene: render photo + overlays + transitions |
| `lib/nerves_photos/component/weather_overlay.ex` | Scenic component: weather display |
| `lib/nerves_photos/component/sick_sun.ex` | Scenic component: unavailable-weather graphic |
| `lib/nerves_photos/component/metadata_overlay.ex` | Scenic component: date/location text |
| `lib/nerves_photos/component/debug_bar.ex` | Scenic component: queue position badge |
| `config/target.exs` | Read all env vars into app config |
| `.env.home` / `.env.work` | Add IMMICH_* and SHOW_DEBUG vars |
| `test/nerves_photos/immich_client_test.exs` | Unit tests for ImmichClient |
| `test/nerves_photos/weather_fetcher_test.exs` | Unit tests for WeatherFetcher |
| `test/nerves_photos/slide_timer_test.exs` | Unit tests for SlideTimer |
| `test/nerves_photos/image_loader_test.exs` | Unit tests for ImageLoader |
| `lib/nerves_photos/settings_store.ex` | GenServer: read/write settings to `/data` partition |
| `lib/nerves_photos/settings_router.ex` | Plug router: GET/POST `/settings` form; Task 12 adds GET `/screenshot` |
| `lib/nerves_photos/settings_server.ex` | Cowboy HTTP listener on port 80 |
| `test/nerves_photos/settings_store_test.exs` | Unit tests for SettingsStore |

---

## Task 1: Wire configuration

**Files:**
- Modify: `config/target.exs`
- Modify: `.env.home`
- Modify: `.env.work`

- [ ] **Step 1: Add env var reads to `config/target.exs`**

Append to the bottom of `config/target.exs` (before any existing `import_config` lines):

```elixir
config :nerves_photos,
  immich_url: System.get_env("IMMICH_URL"),
  immich_api_key: System.get_env("IMMICH_API_KEY"),
  immich_album_id: System.get_env("IMMICH_ALBUM_ID"),
  slide_interval_ms: String.to_integer(System.get_env("SLIDE_INTERVAL_MS", "30000")),
  show_debug: System.get_env("SHOW_DEBUG", "false") == "true"
```

- [ ] **Step 2: Add vars to `.env.home`**

Append to `.env.home`:

```bash
export IMMICH_URL="http://your-immich-server:2283"
export IMMICH_API_KEY="your-api-key-here"
export IMMICH_ALBUM_ID="your-album-uuid-here"
export SLIDE_INTERVAL_MS="30000"
export SHOW_DEBUG="false"
```

- [ ] **Step 3: Add same vars to `.env.work`**

Append identical lines to `.env.work`.

- [ ] **Step 4: Commit**

```bash
git add config/target.exs .env.home .env.work
git commit -m "feat: wire Immich and display configuration from env vars"
```

---

## Task 2: ImmichClient

Immich API reference: `GET /api/albums/{id}` returns album with `assets` array. Each asset has `id`, `fileCreatedAt`, and `exifInfo` (with `city`, `country`).

**Files:**
- Create: `lib/nerves_photos/immich_client.ex`
- Create: `test/nerves_photos/immich_client_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/nerves_photos/immich_client_test.exs`:

```elixir
defmodule NervesPhotos.ImmichClientTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.ImmichClient

  setup do
    Req.Test.stub(ImmichClient, fn conn ->
      uri = conn.request_path

      cond do
        String.contains?(uri, "/api/albums/") ->
          Req.Test.json(conn, %{
            "assets" => [
              %{
                "id" => "asset-1",
                "fileCreatedAt" => "2023-06-12T10:00:00.000Z",
                "exifInfo" => %{"city" => "Yosemite", "country" => "USA"}
              },
              %{
                "id" => "asset-2",
                "fileCreatedAt" => "2023-07-01T12:00:00.000Z",
                "exifInfo" => %{"city" => "Zion", "country" => "USA"}
              }
            ]
          })

        true ->
          Req.Test.json(conn, %{})
      end
    end)

    {:ok, pid} =
      start_supervised(
        {ImmichClient,
         url: "http://immich.test",
         api_key: "test-key",
         album_id: "album-1",
         req_options: [plug: {Req.Test, ImmichClient}]}
      )

    %{client: pid}
  end

  test "current/0 returns first asset with metadata" do
    {asset_id, meta} = ImmichClient.current()
    assert is_binary(asset_id)
    assert %{date: _, location: _} = meta
  end

  test "advance/0 cycles through assets" do
    {first_id, _} = ImmichClient.current()
    {second_id, _} = ImmichClient.advance()
    assert first_id != second_id
  end

  test "queue_position/0 returns {current_index, total}" do
    {index, total} = ImmichClient.queue_position()
    assert is_integer(index)
    assert total == 2
  end

  test "advance/0 re-shuffles when queue exhausted" do
    ImmichClient.advance()
    # third advance wraps around
    {_id, _meta} = ImmichClient.advance()
    {_index, total} = ImmichClient.queue_position()
    assert total == 2
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/nerves_photos/immich_client_test.exs
```

Expected: `** (UndefinedFunctionError) function NervesPhotos.ImmichClient.current/0 is undefined`

- [ ] **Step 3: Implement `ImmichClient`**

Create `lib/nerves_photos/immich_client.ex`:

```elixir
defmodule NervesPhotos.ImmichClient do
  use GenServer
  require Logger

  @backoff_initial 1_000
  @backoff_max 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def current, do: GenServer.call(__MODULE__, :current)
  def advance, do: GenServer.call(__MODULE__, :advance)
  def queue_position, do: GenServer.call(__MODULE__, :queue_position)

  @impl true
  def init(opts) do
    state = %{
      url: opts[:url] || Application.fetch_env!(:nerves_photos, :immich_url),
      api_key: opts[:api_key] || Application.fetch_env!(:nerves_photos, :immich_api_key),
      album_id: opts[:album_id] || Application.fetch_env!(:nerves_photos, :immich_album_id),
      req_options: opts[:req_options] || [],
      queue: [],
      index: 0,
      status: :loading
    }

    send(self(), :fetch_album)
    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, %{queue: [], status: :disconnected} = state) do
    {:reply, :disconnected, state}
  end

  def handle_call(:current, _from, %{queue: [], status: :empty} = state) do
    {:reply, :empty, state}
  end

  def handle_call(:current, _from, %{queue: []} = state) do
    {:reply, :loading, state}
  end

  def handle_call(:current, _from, state) do
    {:reply, current_photo(state), state}
  end

  def handle_call(:advance, _from, state) do
    next_index = state.index + 1

    if next_index >= length(state.queue) do
      send(self(), :fetch_album)
      new_state = %{state | index: 0}
      {:reply, current_photo(new_state), new_state}
    else
      new_state = %{state | index: next_index}
      {:reply, current_photo(new_state), new_state}
    end
  end

  def handle_call(:queue_position, _from, state) do
    {:reply, {state.index + 1, length(state.queue)}, state}
  end

  @impl true
  def handle_info(:fetch_album, state) do
    case fetch_album(state) do
      {:ok, assets} ->
        queue = Enum.shuffle(assets)
        {:noreply, %{state | queue: queue, index: 0, status: :ok}}

      {:error, :empty} ->
        Logger.info("ImmichClient: album is empty, retrying in 5 minutes")
        Process.send_after(self(), :fetch_album, 5 * 60 * 1_000)
        {:noreply, %{state | status: :empty}}

      {:error, reason} ->
        Logger.warning("ImmichClient: fetch failed: #{inspect(reason)}")
        backoff = Map.get(state, :backoff, @backoff_initial)
        Process.send_after(self(), :fetch_album, backoff)
        {:noreply, %{state | status: :disconnected, backoff: min(backoff * 2, @backoff_max)}}
    end
  end

  defp fetch_album(state) do
    req =
      Req.new(
        [
          base_url: state.url,
          headers: [{"x-api-key", state.api_key}]
        ] ++ state.req_options
      )

    case Req.get(req, url: "/api/albums/#{state.album_id}") do
      {:ok, %{status: 200, body: %{"assets" => []}}} ->
        {:error, :empty}

      {:ok, %{status: 200, body: %{"assets" => assets}}} ->
        {:ok, Enum.map(assets, &parse_asset/1)}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_asset(asset) do
    date =
      case DateTime.from_iso8601(asset["fileCreatedAt"] || "") do
        {:ok, dt, _} -> DateTime.to_date(dt)
        _ -> nil
      end

    exif = asset["exifInfo"] || %{}

    location =
      [exif["city"], exif["country"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
      |> then(fn s -> if s == "", do: nil, else: s end)

    {asset["id"], %{date: date, location: location}}
  end

  defp current_photo(%{queue: queue, index: index}) do
    Enum.at(queue, index)
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/nerves_photos/immich_client_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/immich_client.ex test/nerves_photos/immich_client_test.exs
git commit -m "feat: add ImmichClient GenServer with shuffle queue and backoff"
```

---

## Task 3: WeatherFetcher

Open-Meteo API: `GET https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}&current=temperature_2m,weathercode&temperature_unit=fahrenheit`

WMO weather codes reference (subset):
- 0 = Clear sky
- 1-3 = Mainly/partly cloudy
- 45, 48 = Fog
- 51-67 = Rain/drizzle
- 71-77 = Snow
- 80-82 = Rain showers
- 95-99 = Thunderstorm

ip-api.com: `GET http://ip-api.com/json` returns `{"lat": 37.7, "lon": -122.4, ...}`

**Files:**
- Create: `lib/nerves_photos/weather_fetcher.ex`
- Create: `test/nerves_photos/weather_fetcher_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/nerves_photos/weather_fetcher_test.exs`:

```elixir
defmodule NervesPhotos.WeatherFetcherTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.WeatherFetcher

  setup do
    Req.Test.stub(WeatherFetcher, fn conn ->
      cond do
        String.contains?(conn.host, "ip-api") ->
          Req.Test.json(conn, %{"lat" => 37.7, "lon" => -122.4})

        String.contains?(conn.host, "open-meteo") ->
          Req.Test.json(conn, %{
            "current" => %{
              "temperature_2m" => 68.0,
              "weathercode" => 1
            }
          })

        true ->
          Req.Test.json(conn, %{})
      end
    end)

    {:ok, _pid} =
      start_supervised(
        {WeatherFetcher, req_options: [plug: {Req.Test, WeatherFetcher}]}
      )

    :ok
  end

  test "current/0 returns ok tuple with weather data" do
    # Allow async init to complete
    Process.sleep(50)
    assert {:ok, %{temp_f: temp, condition: condition, icon_code: code}} = WeatherFetcher.current()
    assert is_float(temp) or is_integer(temp)
    assert is_binary(condition)
    assert is_integer(code)
  end

  test "current/0 returns :unavailable before data loads" do
    # Fresh GenServer before fetch completes
    {:ok, pid} =
      GenServer.start(WeatherFetcher, req_options: [plug: {Req.Test, WeatherFetcher}])
    # Call immediately before fetch_weather message is processed
    assert GenServer.call(pid, :current) == :unavailable
    GenServer.stop(pid)
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/nerves_photos/weather_fetcher_test.exs
```

Expected: `** (UndefinedFunctionError) function NervesPhotos.WeatherFetcher.current/0 is undefined`

- [ ] **Step 3: Implement `WeatherFetcher`**

Create `lib/nerves_photos/weather_fetcher.ex`:

```elixir
defmodule NervesPhotos.WeatherFetcher do
  use GenServer
  require Logger

  @poll_interval 15 * 60 * 1_000

  @wmo_codes %{
    0 => "Clear Sky",
    1 => "Mainly Clear",
    2 => "Partly Cloudy",
    3 => "Overcast",
    45 => "Fog",
    48 => "Fog",
    51 => "Light Drizzle",
    53 => "Drizzle",
    55 => "Heavy Drizzle",
    61 => "Light Rain",
    63 => "Rain",
    65 => "Heavy Rain",
    71 => "Light Snow",
    73 => "Snow",
    75 => "Heavy Snow",
    80 => "Rain Showers",
    81 => "Rain Showers",
    82 => "Heavy Showers",
    95 => "Thunderstorm",
    99 => "Thunderstorm"
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(opts) do
    send(self(), :fetch_weather)
    {:ok, %{weather: :unavailable, req_options: opts[:req_options] || []}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.weather, state}
  end

  @impl true
  def handle_info(:fetch_weather, state) do
    weather =
      with {:ok, coords} <- geolocate(state.req_options),
           {:ok, data} <- fetch_weather(coords, state.req_options) do
        {:ok, data}
      else
        err ->
          Logger.warning("WeatherFetcher: #{inspect(err)}")
          :unavailable
      end

    Process.send_after(self(), :fetch_weather, @poll_interval)
    {:noreply, %{state | weather: weather}}
  end

  defp geolocate(req_options) do
    req = Req.new([base_url: "http://ip-api.com"] ++ req_options)

    case Req.get(req, url: "/json") do
      {:ok, %{status: 200, body: %{"lat" => lat, "lon" => lon}}} -> {:ok, {lat, lon}}
      {:ok, resp} -> {:error, {:geo, resp.status}}
      {:error, e} -> {:error, e}
    end
  end

  defp fetch_weather({lat, lon}, req_options) do
    req = Req.new([base_url: "https://api.open-meteo.com"] ++ req_options)

    params = [
      latitude: lat,
      longitude: lon,
      current: "temperature_2m,weathercode",
      temperature_unit: "fahrenheit"
    ]

    case Req.get(req, url: "/v1/forecast", params: params) do
      {:ok, %{status: 200, body: %{"current" => current}}} ->
        code = current["weathercode"] || 0

        {:ok,
         %{
           temp_f: current["temperature_2m"],
           condition: Map.get(@wmo_codes, code, "Unknown"),
           icon_code: code
         }}

      {:ok, resp} ->
        {:error, {:weather, resp.status}}

      {:error, e} ->
        {:error, e}
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/nerves_photos/weather_fetcher_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/weather_fetcher.ex test/nerves_photos/weather_fetcher_test.exs
git commit -m "feat: add WeatherFetcher GenServer with Open-Meteo and ip-api.com"
```

---

## Task 4: SlideTimer

**Files:**
- Create: `lib/nerves_photos/slide_timer.ex`
- Create: `test/nerves_photos/slide_timer_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/nerves_photos/slide_timer_test.exs`:

```elixir
defmodule NervesPhotos.SlideTimerTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.SlideTimer

  test "sends :next_photo to target process after interval" do
    {:ok, _pid} = start_supervised({SlideTimer, interval_ms: 50, target: self()})
    assert_receive {:slide_timer, :next_photo}, 200
  end

  test "sends repeatedly" do
    {:ok, _pid} = start_supervised({SlideTimer, interval_ms: 50, target: self()})
    assert_receive {:slide_timer, :next_photo}, 200
    assert_receive {:slide_timer, :next_photo}, 200
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/nerves_photos/slide_timer_test.exs
```

Expected: `** (UndefinedFunctionError) function NervesPhotos.SlideTimer.start_link/1 is undefined`

- [ ] **Step 3: Implement `SlideTimer`**

Create `lib/nerves_photos/slide_timer.ex`:

```elixir
defmodule NervesPhotos.SlideTimer do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = opts[:interval_ms] || Application.get_env(:nerves_photos, :slide_interval_ms, 30_000)
    target = opts[:target] || NervesPhotos.Scene.Main
    schedule(interval)
    {:ok, %{interval: interval, target: target}}
  end

  @impl true
  def handle_info(:tick, state) do
    send(state.target, {:slide_timer, :next_photo})
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/nerves_photos/slide_timer_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/slide_timer.ex test/nerves_photos/slide_timer_test.exs
git commit -m "feat: add SlideTimer GenServer"
```

---

## Task 5: ImageLoader

Immich preview endpoint: `GET {base_url}/api/assets/{id}/thumbnail?size=preview`
with header `x-api-key: {key}`. Returns JPEG binary.

Scenic Assets Stream API (Scenic 0.11): `Scenic.Assets.Stream.put(key, {:image, jpeg_binary})`
where the key is a string. The DRM driver decodes the JPEG.

**Note:** Verify the exact `Scenic.Assets.Stream.put/2` signature against Scenic 0.11 docs/source before running tests. The format above is the most common usage pattern.

**Files:**
- Create: `lib/nerves_photos/image_loader.ex`
- Create: `test/nerves_photos/image_loader_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/nerves_photos/image_loader_test.exs`:

```elixir
defmodule NervesPhotos.ImageLoaderTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.ImageLoader

  @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

  setup do
    Req.Test.stub(ImageLoader, fn conn ->
      if String.contains?(conn.request_path, "/thumbnail") do
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
        |> Plug.Conn.send_resp(200, @fake_jpeg)
      else
        Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    {:ok, _pid} =
      start_supervised(
        {ImageLoader,
         url: "http://immich.test",
         api_key: "test-key",
         req_options: [plug: {Req.Test, ImageLoader}]}
      )

    :ok
  end

  test "load/2 sends {:image_loaded, key} to caller on success" do
    ImageLoader.load("asset-1", self())
    assert_receive {:image_loaded, "photo:current"}, 500
  end

  test "load/2 sends {:image_load_error, asset_id} on HTTP failure" do
    Req.Test.stub(ImageLoader, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    ImageLoader.load("bad-asset", self())
    assert_receive {:image_load_error, "bad-asset"}, 500
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/nerves_photos/image_loader_test.exs
```

Expected: `** (UndefinedFunctionError) function NervesPhotos.ImageLoader.load/2 is undefined`

- [ ] **Step 3: Implement `ImageLoader`**

Create `lib/nerves_photos/image_loader.ex`:

```elixir
defmodule NervesPhotos.ImageLoader do
  use GenServer
  require Logger

  @stream_key "photo:current"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def load(asset_id, reply_to \\ nil, stream_key \\ "photo:current") do
    GenServer.cast(__MODULE__, {:load, asset_id, reply_to || self(), stream_key})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       url: opts[:url] || Application.fetch_env!(:nerves_photos, :immich_url),
       api_key: opts[:api_key] || Application.fetch_env!(:nerves_photos, :immich_api_key),
       req_options: opts[:req_options] || []
     }}
  end

  @impl true
  def handle_cast({:load, asset_id, reply_to, stream_key}, state) do
    Task.start(fn ->
      case fetch_preview(asset_id, state) do
        {:ok, image_bytes} ->
          Scenic.Assets.Stream.put(stream_key, {:image, image_bytes})
          send(reply_to, {:image_loaded, stream_key})

        {:error, reason} ->
          Logger.warning("ImageLoader: failed to load #{asset_id}: #{inspect(reason)}")
          send(reply_to, {:image_load_error, asset_id})
      end
    end)

    {:noreply, state}
  end

  defp fetch_preview(asset_id, state) do
    req =
      Req.new(
        [
          base_url: state.url,
          headers: [{"x-api-key", state.api_key}]
        ] ++ state.req_options
      )

    case Req.get(req, url: "/api/assets/#{asset_id}/thumbnail", params: [size: "preview"]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/nerves_photos/image_loader_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/image_loader.ex test/nerves_photos/image_loader_test.exs
git commit -m "feat: add ImageLoader GenServer using Immich preview endpoint"
```

---

## Task 6: Wire up Application supervisor

**Files:**
- Modify: `lib/nerves_photos/application.ex`

- [ ] **Step 1: Add all children to the supervisor**

Replace the contents of `lib/nerves_photos/application.ex`:

```elixir
defmodule NervesPhotos.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = target_children()
    opts = [strategy: :one_for_one, name: NervesPhotos.Supervisor]
    Supervisor.start_link(children, opts)
  end

  if Mix.target() == :host do
    defp target_children do
      [
        NervesPhotos.ImmichClient,
        NervesPhotos.WeatherFetcher,
        NervesPhotos.SlideTimer
        # ImageLoader and Scenic omitted on host — no display
      ]
    end
  else
    defp target_children do
      viewport_config = Application.get_env(:nerves_photos, :viewport)

      [
        NervesPhotos.ImmichClient,
        NervesPhotos.WeatherFetcher,
        NervesPhotos.ImageLoader,
        NervesPhotos.SlideTimer,
        {Scenic, [viewport_config]}
      ]
    end
  end
end
```

- [ ] **Step 2: Run all tests to confirm nothing broken**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/nerves_photos/application.ex
git commit -m "feat: wire GenServers and Scenic viewport into application supervisor"
```

---

## Task 7: Scene.Main skeleton

Scenic 0.11 scene API reference:
- `use Scenic.Scene` — provides `push_graph/2`, `fetch_scene_state/1`
- `init(scene, params, opts)` — return `{:ok, scene}`
- `handle_info(msg, scene)` — return `{:noreply, scene}`
- `Scenic.Graph.build/1` — create graph
- `Scenic.Primitives.rect/3` — rectangle primitive
- `Scenic.Primitives.text/3` — text primitive
- `Scenic.Primitives.image/3` — image primitive, source can be `{:stream, key}`
- `push_graph(scene, graph)` — push updated graph to viewport

**Files:**
- Create: `lib/nerves_photos/scene/main.ex`

- [ ] **Step 1: Create scene skeleton that renders a black screen**

Create `lib/nerves_photos/scene/main.ex`:

```elixir
defmodule NervesPhotos.Scene.Main do
  use Scenic.Scene
  require Logger

  alias Scenic.Graph
  import Scenic.Primitives

  @stream_key "photo:current"

  @impl Scenic.Scene
  def init(scene, _params, opts) do
    viewport = opts[:viewport]
    {:ok, %{size: {width, height}}} = Scenic.ViewPort.info(viewport)

    # Register stream slot before first render
    Scenic.Assets.Stream.put(@stream_key, {:image, <<>>})

    graph =
      Graph.build(font: :roboto, font_size: 20)
      |> rect({width, height}, fill: :black, id: :background)
      |> image({width, height}, id: :photo,
           fill: {:stream, @stream_key},
           translate: {0, 0})

    scene =
      scene
      |> assign(
        width: width,
        height: height,
        metadata: nil,
        disconnected: false,
        empty_album: false,
        transition: :idle
      )
      |> push_graph(graph)

    {:ok, scene}
  end

  @impl Scenic.Scene
  def handle_info({:slide_timer, :next_photo}, scene) do
    case NervesPhotos.ImmichClient.advance() do
      {asset_id, metadata} ->
        NervesPhotos.ImageLoader.load(asset_id, self())
        {:noreply, assign(scene, metadata: metadata)}

      :disconnected ->
        {:noreply, assign(scene, disconnected: true)}

      :loading ->
        {:noreply, scene}
    end
  end

  def handle_info({:image_loaded, _key}, scene) do
    scene = assign(scene, disconnected: false)
    {:noreply, render(scene)}
  end

  def handle_info({:image_load_error, _asset_id}, scene) do
    # Skip to next photo silently
    send(self(), {:slide_timer, :next_photo})
    {:noreply, scene}
  end

  def handle_info(_msg, scene), do: {:noreply, scene}

  defp render(scene) do
    graph =
      Graph.build(font: :roboto, font_size: 20)
      |> rect({scene.assigns.width, scene.assigns.height}, fill: :black, id: :background)
      |> image({scene.assigns.width, scene.assigns.height},
           id: :photo,
           fill: {:stream, @stream_key},
           translate: {0, 0})

    push_graph(scene, graph)
  end
end
```

- [ ] **Step 2: Verify it compiles for host target**

```bash
mix compile
```

Expected: no errors (Scenic may warn about missing viewport on host — that is fine).

- [ ] **Step 3: Commit**

```bash
git add lib/nerves_photos/scene/main.ex
git commit -m "feat: add Scene.Main skeleton with basic photo rendering"
```

---

## Task 8: Overlay components

**Files:**
- Create: `lib/nerves_photos/component/metadata_overlay.ex`
- Create: `lib/nerves_photos/component/weather_overlay.ex`
- Create: `lib/nerves_photos/component/sick_sun.ex`
- Create: `lib/nerves_photos/component/debug_bar.ex`
- Modify: `lib/nerves_photos/scene/main.ex`

These are Scenic 0.11 components (`use Scenic.Component`). Components accept params and render a sub-graph. They are added to the main scene graph via `Scenic.Primitives.component/3`.

- [ ] **Step 1: Create MetadataOverlay component**

Create `lib/nerves_photos/component/metadata_overlay.ex`:

```elixir
defmodule NervesPhotos.Component.MetadataOverlay do
  use Scenic.Component

  import Scenic.Primitives
  alias Scenic.Graph

  # params: %{date: ~D[2023-06-12], location: "Yosemite, USA", width: 1920, height: 1080}
  @impl Scenic.Component
  def validate(params) when is_map(params), do: {:ok, params}
  def validate(_), do: :error

  @impl Scenic.Scene
  def init(scene, params, _opts) do
    graph = build_graph(params)
    {:ok, push_graph(scene, graph)}
  end

  defp build_graph(%{date: nil, location: nil}), do: Graph.build()

  defp build_graph(%{date: date, location: location, height: height}) do
    lines =
      [format_date(date), location]
      |> Enum.reject(&is_nil/1)

    Graph.build()
    |> rect({400, 70}, fill: {:color_rgba, {0, 0, 0, 140}},
         translate: {16, height - 78})
    |> draw_lines(lines, height)
  end

  defp draw_lines(graph, [], _height), do: graph

  defp draw_lines(graph, [line1], height) do
    graph
    |> text(line1, fill: :white, font_size: 18, translate: {24, height - 52})
  end

  defp draw_lines(graph, [line1, line2 | _], height) do
    graph
    |> text(line1, fill: :white, font_size: 18, translate: {24, height - 56},
         font_blur: 0)
    |> text(line2, fill: {:color_rgba, {255, 255, 255, 180}}, font_size: 15,
         translate: {24, height - 32})
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Calendar.strftime(date, "%B %-d, %Y")
end
```

- [ ] **Step 2: Create SickSun component**

Create `lib/nerves_photos/component/sick_sun.ex`:

```elixir
defmodule NervesPhotos.Component.SickSun do
  use Scenic.Component
  import Scenic.Primitives
  alias Scenic.Graph

  @impl Scenic.Component
  def validate(params) when is_map(params), do: {:ok, params}
  def validate(_), do: :error

  # Draws a simple sick-sun: circle with X eyes and wavy mouth
  @impl Scenic.Scene
  def init(scene, %{translate: {x, y}} = _params, _opts) do
    graph =
      Graph.build()
      # Sun body
      |> circle(18, fill: {:color, {255, 220, 50}}, translate: {x + 18, y + 18})
      # Left X eye - two crossing lines
      |> line({{x + 9, y + 11}, {x + 13, y + 15}}, stroke: {2, :black})
      |> line({{x + 13, y + 11}, {x + 9, y + 15}}, stroke: {2, :black})
      # Right X eye
      |> line({{x + 22, y + 11}, {x + 26, y + 15}}, stroke: {2, :black})
      |> line({{x + 26, y + 11}, {x + 22, y + 15}}, stroke: {2, :black})
      # Wavy frown mouth
      |> line({{x + 11, y + 23}, {x + 25, y + 23}}, stroke: {2, :black})

    {:ok, push_graph(scene, graph)}
  end
end
```

- [ ] **Step 3: Create WeatherOverlay component**

Create `lib/nerves_photos/component/weather_overlay.ex`:

```elixir
defmodule NervesPhotos.Component.WeatherOverlay do
  use Scenic.Component
  import Scenic.Primitives
  alias Scenic.Graph
  alias NervesPhotos.Component.SickSun

  @impl Scenic.Component
  def validate(params) when is_map(params), do: {:ok, params}
  def validate(_), do: :error

  # params: %{weather: {:ok, %{temp_f: 68.0, condition: "Partly Cloudy", icon_code: 2}}
  #          | :unavailable, width: 1920, height: 1080}
  @impl Scenic.Scene
  def init(scene, params, _opts) do
    graph = build_graph(params)
    {:ok, push_graph(scene, graph)}
  end

  defp build_graph(%{weather: :unavailable, width: width, height: height}) do
    x = width - 200
    y = height - 78

    Graph.build()
    |> rect({184, 70}, fill: {:color_rgba, {0, 0, 0, 140}}, translate: {x, y})
    |> component(SickSun, %{translate: {x + 8, y + 14}}, id: :sick_sun)
    |> text("No weather data", fill: {:color_rgba, {255, 255, 255, 180}},
         font_size: 13, translate: {x + 50, y + 38})
  end

  defp build_graph(%{weather: {:ok, %{temp_f: temp, condition: condition}},
                     width: width, height: height}) do
    x = width - 200
    y = height - 78
    temp_str = "#{round(temp)}°F"

    Graph.build()
    |> rect({184, 70}, fill: {:color_rgba, {0, 0, 0, 140}}, translate: {x, y})
    |> text(temp_str, fill: :white, font_size: 20, translate: {x + 12, y + 34})
    |> text(condition, fill: {:color_rgba, {255, 255, 255, 180}},
         font_size: 14, translate: {x + 12, y + 58})
  end
end
```

- [ ] **Step 4: Create DebugBar component**

Create `lib/nerves_photos/component/debug_bar.ex`:

```elixir
defmodule NervesPhotos.Component.DebugBar do
  use Scenic.Component
  import Scenic.Primitives
  alias Scenic.Graph

  @impl Scenic.Component
  def validate(params) when is_map(params), do: {:ok, params}
  def validate(_), do: :error

  # params: %{current: 23, total: 193, width: 1920, height: 1080}
  @impl Scenic.Scene
  def init(scene, %{current: current, total: total, width: width, height: height}, _opts) do
    label = "#{current}/#{total}"
    x = div(width, 2) - 40

    graph =
      Graph.build()
      |> rect({80, 28}, fill: {:color_rgba, {0, 0, 0, 160}},
           translate: {x, height - 36}, radius: 6)
      |> text(label, fill: :white, font_size: 16,
           translate: {x + 10, height - 16})

    {:ok, push_graph(scene, graph)}
  end
end
```

- [ ] **Step 5: Integrate overlays into `Scene.Main`**

Update the `render/1` function in `lib/nerves_photos/scene/main.ex` to add overlay components. Replace the existing `render/1` private function:

```elixir
defp render(scene) do
  %{width: width, height: height, metadata: metadata,
    disconnected: disconnected, empty_album: empty_album} = scene.assigns

  weather = NervesPhotos.WeatherFetcher.current()
  {current, total} = NervesPhotos.ImmichClient.queue_position()
  show_debug = Application.get_env(:nerves_photos, :show_debug, false)

  meta = metadata || %{date: nil, location: nil}

  graph =
    Graph.build(font: :roboto, font_size: 20)
    |> rect({width, height}, fill: :black, id: :background)
    |> image({width, height},
         id: :photo,
         fill: {:stream, @stream_key},
         translate: {0, 0})
    |> component(NervesPhotos.Component.MetadataOverlay,
         Map.merge(meta, %{width: width, height: height}),
         id: :metadata)
    |> component(NervesPhotos.Component.WeatherOverlay,
         %{weather: weather, width: width, height: height},
         id: :weather)
    |> then(fn g ->
      if empty_album do
        msg_x = div(width, 2) - 100

        g
        |> rect({200, 36}, fill: {:color_rgba, {0, 0, 0, 160}},
             translate: {msg_x, div(height, 2) - 18}, radius: 8)
        |> text("No photos found in album", fill: :white,
             font_size: 16, translate: {msg_x + 12, div(height, 2) + 7})
      else
        g
      end
    end)
    |> then(fn g ->
      if disconnected do
        label_x = div(width, 2) - 70

        g
        |> rect({140, 30}, fill: {:color_rgba, {0, 0, 0, 160}},
             translate: {label_x, 16}, radius: 15)
        |> text("Reconnecting...", fill: {:color, {255, 204, 68}},
             font_size: 16, translate: {label_x + 10, 37})
      else
        g
      end
    end)
    |> then(fn g ->
      if show_debug do
        g
        |> component(NervesPhotos.Component.DebugBar,
             %{current: current, total: total, width: width, height: height},
             id: :debug)
      else
        g
      end
    end)

  push_graph(scene, graph)
end
```

Also add `import Scenic.Primitives` and the alias at the top of the module if not present:

```elixir
alias NervesPhotos.Component.MetadataOverlay
alias NervesPhotos.Component.WeatherOverlay
alias NervesPhotos.Component.DebugBar
```

- [ ] **Step 6: Compile**

```bash
mix compile
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add lib/nerves_photos/component/ lib/nerves_photos/scene/main.ex
git commit -m "feat: add overlay components for metadata, weather, debug bar, and sick sun"
```

---

## Task 9: Photo transitions

Target-specific: crossfade on RPi5, fade-to-black on RPi0. Implemented as a `handle_info` tick loop in `Scene.Main`.

**Files:**
- Modify: `lib/nerves_photos/scene/main.ex`

- [ ] **Step 1: Add transition state to `init/3`**

In `Scene.Main.init/3`, add transition fields to the `assign/2` call:

```elixir
|> assign(
  width: width,
  height: height,
  metadata: nil,
  disconnected: false,
  transition: :idle,       # :idle | :fading_out | :fading_in
  fade_opacity: 0.0,       # 0.0..1.0 — used by fade-to-black (RPi0)
  front_slot: :slot_a,     # :slot_a | :slot_b — used by crossfade (RPi5)
  opacity_a: 1.0,          # slot_a opacity for crossfade
  opacity_b: 0.0           # slot_b opacity for crossfade
)
```

Also register both stream slots (RPi5 only needs two, but registering both is harmless):

```elixir
Scenic.Assets.Stream.put("photo:slot_a", {:image, <<>>})
Scenic.Assets.Stream.put("photo:slot_b", {:image, <<>>})
Scenic.Assets.Stream.put(@stream_key, {:image, <<>>})
```

- [ ] **Step 2: Add compile-time transition module selection**

Add at the top of `Scene.Main`, after the module declaration:

```elixir
if Mix.target() == :rpi5 do
  @transition :crossfade
else
  @transition :fade_to_black
end

@fade_steps 20
@fade_interval_ms 16  # ~60fps
```

- [ ] **Step 3: Replace `handle_info({:slide_timer, :next_photo})` with transition-aware version**

Replace the existing `:next_photo` handler. The back slot for crossfade is determined here so `ImageLoader` writes directly into the correct stream slot:

```elixir
def handle_info({:slide_timer, :next_photo}, %{assigns: %{transition: :idle}} = scene) do
  case NervesPhotos.ImmichClient.advance() do
    {asset_id, metadata} ->
      {scene, stream_key} = prepare_load_slot(scene)
      NervesPhotos.ImageLoader.load(asset_id, self(), stream_key)
      {:noreply, assign(scene, metadata: metadata, transition: :loading)}

    :disconnected ->
      {:noreply, assign(scene, disconnected: true)}

    :empty ->
      {:noreply, assign(scene, empty_album: true)}

    :loading ->
      {:noreply, scene}
  end
end

# Ignore timer ticks during active transition
def handle_info({:slide_timer, :next_photo}, scene), do: {:noreply, scene}
```

Add `prepare_load_slot/1` as a compile-time-branched private function after the `handle_info` clauses:

```elixir
if Mix.target() == :rpi5 do
  defp prepare_load_slot(scene) do
    back_slot = if scene.assigns.front_slot == :slot_a, do: :slot_b, else: :slot_a
    {assign(scene, back_slot: back_slot), "photo:#{back_slot}"}
  end
else
  defp prepare_load_slot(scene), do: {scene, "photo:current"}
end
```

- [ ] **Step 4: Handle image loaded — start transition**

Replace the existing `{:image_loaded, _key}` handler. By this point the image is already in the correct slot, so we just start the animation:

```elixir
def handle_info({:image_loaded, _key}, scene) do
  scene = assign(scene, disconnected: false, transition: :running, fade_step: 0)
  send(self(), :transition_tick)
  {:noreply, scene}
end
```

- [ ] **Step 5: Add fade-to-black tick handler**

```elixir
if Mix.target() != :rpi5 do
  def handle_info(:transition_tick, %{assigns: %{transition: :running, fade_step: step}} = scene)
      when step <= @fade_steps do
    opacity = step / @fade_steps
    scene = assign(scene, fade_opacity: opacity, fade_step: step + 1)
    Process.send_after(self(), :transition_tick, @fade_interval_ms)
    {:noreply, render(scene)}
  end

  def handle_info(:transition_tick, %{assigns: %{transition: :running}} = scene) do
    # Fully black — swap image, start fade in
    scene = assign(scene, transition: :fading_in, fade_step: 0)
    send(self(), :fade_in_tick)
    {:noreply, render(scene)}
  end

  def handle_info(:fade_in_tick, %{assigns: %{transition: :fading_in, fade_step: step}} = scene)
      when step <= @fade_steps do
    opacity = 1.0 - step / @fade_steps
    scene = assign(scene, fade_opacity: opacity, fade_step: step + 1)
    Process.send_after(self(), :fade_in_tick, @fade_interval_ms)
    {:noreply, render(scene)}
  end

  def handle_info(:fade_in_tick, %{assigns: %{transition: :fading_in}} = scene) do
    scene = assign(scene, transition: :idle, fade_opacity: 0.0)
    {:noreply, render(scene)}
  end
end
```

- [ ] **Step 6: Add crossfade tick handler**

```elixir
if Mix.target() == :rpi5 do
  def handle_info(:transition_tick, %{assigns: %{transition: :running, fade_step: step}} = scene)
      when step <= @fade_steps do
    t = step / @fade_steps
    {front_opacity, back_opacity} = {1.0 - t, t}

    scene =
      assign(scene,
        opacity_a: (if scene.assigns.front_slot == :slot_a, do: front_opacity, else: back_opacity),
        opacity_b: (if scene.assigns.front_slot == :slot_b, do: front_opacity, else: back_opacity),
        fade_step: step + 1
      )

    Process.send_after(self(), :transition_tick, @fade_interval_ms)
    {:noreply, render(scene)}
  end

  def handle_info(:transition_tick, %{assigns: %{transition: :running}} = scene) do
    # Transition complete — swap front slot
    new_front = scene.assigns.back_slot
    scene = assign(scene, transition: :idle, front_slot: new_front,
                   opacity_a: (if new_front == :slot_a, do: 1.0, else: 0.0),
                   opacity_b: (if new_front == :slot_b, do: 1.0, else: 0.0))
    {:noreply, render(scene)}
  end
end
```

- [ ] **Step 7: Update `render/1` to apply transition opacity**

In the `render/1` function, update the `:photo` image primitive to include opacity from transition state. For fade-to-black, add a black overlay rect:

```elixir
# In render/1, after the photo image primitive, add:
|> then(fn g ->
  case @transition do
    :fade_to_black ->
      alpha = round(scene.assigns.fade_opacity * 255)
      if alpha > 0 do
        rect(g, {scene.assigns.width, scene.assigns.height},
          fill: {:color_rgba, {0, 0, 0, alpha}}, id: :fade_overlay)
      else
        g
      end

    :crossfade ->
      # Two image layers with per-slot opacity
      alpha_a = round(scene.assigns.opacity_a * 255)
      alpha_b = round(scene.assigns.opacity_b * 255)
      g
      |> image({scene.assigns.width, scene.assigns.height},
           id: :photo_a,
           fill: {:stream, "photo:slot_a"},
           paint: {:color_rgba, {255, 255, 255, alpha_a}},
           translate: {0, 0})
      |> image({scene.assigns.width, scene.assigns.height},
           id: :photo_b,
           fill: {:stream, "photo:slot_b"},
           paint: {:color_rgba, {255, 255, 255, alpha_b}},
           translate: {0, 0})
  end
end)
```

**Note:** The exact Scenic 0.11 API for per-primitive opacity (`:paint` vs `:fill` alpha) should be verified against the `Scenic.Primitives` docs before committing. The pattern above follows common Scenic usage.

- [ ] **Step 8: Compile**

```bash
mix compile
```

Expected: no errors.

- [ ] **Step 9: Commit**

```bash
git add lib/nerves_photos/scene/main.ex
git commit -m "feat: add photo transitions — crossfade on RPi5, fade-to-black on RPi0"
```

---

## Task 10: Final integration check

- [ ] **Step 1: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 2: Compile for RPi0 target**

```bash
MIX_TARGET=rpi0 mix compile
```

Expected: no errors.

- [ ] **Step 3: Compile for RPi5 target**

```bash
MIX_TARGET=rpi5 mix compile
```

Expected: no errors.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: NervesPhotos photo frame — complete implementation"
```

---

## Task 11: Web settings UI (Plug + mDNS)

Allow changing Immich URL, API key, album, slide interval, and WiFi credentials from a browser on the same network, reachable at `http://nerves.local/settings`. Settings are persisted to the data partition and applied on reboot.

**New dependencies to add to `mix.exs`:**

```elixir
{:plug_cowboy, "~> 2.7"},
```

`mdns_lite` is already included in the project (it advertises SSH). A new `_http._tcp` service entry just needs to be added to its config.

**Files:**
- Create: `lib/nerves_photos/settings_server.ex` — Cowboy HTTP listener
- Create: `lib/nerves_photos/settings_router.ex` — Plug router (GET/POST `/settings`)
- Create: `lib/nerves_photos/settings_store.ex` — read/write settings to `/data/nerves_photos/settings.json`
- Modify: `lib/nerves_photos/application.ex` — add `SettingsServer` to supervisor (target only)
- Modify: `config/target.exs` — advertise `_http._tcp` port 80 via `mdns_lite`

**Settings persisted (JSON on `/data` partition):**

| Key | Description |
|---|---|
| `immich_url` | Base URL of Immich server |
| `immich_api_key` | Immich API key |
| `immich_album_id` | Album UUID |
| `slide_interval_ms` | Milliseconds between photos |
| `wifi_ssid` | WiFi network name |
| `wifi_psk` | WiFi password |

**At runtime:** `SettingsStore` is the authoritative source for settings. On startup it reads from `/data/nerves_photos/settings.json` if present, falling back to application env (the compiled-in env var values). GenServers that use settings (`ImmichClient`, `SlideTimer`) should read from `SettingsStore` rather than `Application.get_env` directly, so changes take effect after reboot without a reflash.

**Note on WiFi:** Writing new WiFi credentials calls `VintageNet.configure/2` directly — no reboot needed for network changes.

- [ ] **Step 1: Add `plug_cowboy` to `mix.exs` and run `mix deps.get`**

In `mix.exs` deps:
```elixir
{:plug_cowboy, "~> 2.7"},
```

```bash
mix deps.get
```

- [ ] **Step 2: Write failing tests for SettingsStore**

Create `test/nerves_photos/settings_store_test.exs`:

```elixir
defmodule NervesPhotos.SettingsStoreTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.SettingsStore

  setup do
    path = System.tmp_dir!() |> Path.join("nerves_photos_test_#{:erlang.unique_integer([:positive])}.json")
    {:ok, _} = start_supervised({SettingsStore, path: path})
    {:ok, path: path}
  end

  test "get/1 returns compiled-in default when no file exists" do
    assert is_binary(SettingsStore.get(:immich_url)) or is_nil(SettingsStore.get(:immich_url))
  end

  test "put/2 and get/1 round-trip a value" do
    :ok = SettingsStore.put(:slide_interval_ms, 10_000)
    assert SettingsStore.get(:slide_interval_ms) == 10_000
  end

  test "put/2 persists to disk and reloads after restart", %{path: path} do
    :ok = SettingsStore.put(:immich_url, "http://new-server:2283")

    # Stop and restart to verify reload from disk
    stop_supervised!(SettingsStore)
    {:ok, _} = start_supervised({SettingsStore, path: path})

    assert SettingsStore.get(:immich_url) == "http://new-server:2283"
  end
end
```

- [ ] **Step 3: Run to confirm failure**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_store_test.exs
```

Expected: `** (UndefinedFunctionError) function NervesPhotos.SettingsStore.get/1 is undefined`

- [ ] **Step 4: Implement `SettingsStore`**

Create `lib/nerves_photos/settings_store.ex`:

```elixir
defmodule NervesPhotos.SettingsStore do
  use GenServer

  @keys [:immich_url, :immich_api_key, :immich_album_id, :slide_interval_ms,
         :wifi_ssid, :wifi_psk]
  @default_path "/data/nerves_photos/settings.json"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})
  def all, do: GenServer.call(__MODULE__, :all)

  @impl true
  def init(opts) do
    path = opts[:path] || @default_path
    settings = load(path)
    {:ok, %{path: path, settings: settings}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.settings, key), state}
  end

  def handle_call({:put, key, value}, _from, state) when key in @keys do
    settings = Map.put(state.settings, key, value)
    :ok = persist(state.path, settings)
    {:reply, :ok, %{state | settings: settings}}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.settings, state}
  end

  defp load(path) do
    defaults = %{
      immich_url: Application.get_env(:nerves_photos, :immich_url),
      immich_api_key: Application.get_env(:nerves_photos, :immich_api_key),
      immich_album_id: Application.get_env(:nerves_photos, :immich_album_id),
      slide_interval_ms: Application.get_env(:nerves_photos, :slide_interval_ms, 30_000),
      wifi_ssid: nil,
      wifi_psk: nil
    }

    case File.read(path) do
      {:ok, json} ->
        saved =
          Jason.decode!(json, keys: :atoms)
          |> Map.take(@keys)
        Map.merge(defaults, saved)

      {:error, :enoent} ->
        defaults
    end
  end

  defp persist(path, settings) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(settings))
  end
end
```

- [ ] **Step 5: Run SettingsStore tests**

```bash
MIX_TARGET=host mix test test/nerves_photos/settings_store_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 6: Implement `SettingsRouter` (Plug)**

Create `lib/nerves_photos/settings_router.ex`:

```elixir
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
        {ms, ""} when ms > 0 -> NervesPhotos.SettingsStore.put(:slide_interval_ms, ms)
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
        <input name="immich_url" value="#{Map.get(s, :immich_url, "")}">
      </label>
      <label>API Key
        <input name="immich_api_key" value="#{Map.get(s, :immich_api_key, "")}">
      </label>
      <label>Album ID
        <input name="immich_album_id" value="#{Map.get(s, :immich_album_id, "")}">
      </label>
      <h2>Display</h2>
      <label>Slide interval (seconds)
        <input name="slide_interval_ms" type="number" min="5" value="#{interval_s}">
      </label>
      <h2>WiFi</h2>
      <label>SSID
        <input name="wifi_ssid" value="#{Map.get(s, :wifi_ssid, "")}">
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
```

- [ ] **Step 7: Implement `SettingsServer`**

Create `lib/nerves_photos/settings_server.ex`:

```elixir
defmodule NervesPhotos.SettingsServer do
  def child_spec(_opts) do
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: NervesPhotos.SettingsRouter,
      options: [port: 80]
    )
  end
end
```

- [ ] **Step 8: Add `SettingsStore` and `SettingsServer` to the supervisor**

In `lib/nerves_photos/application.ex`, update the target `defp target_children` block:

```elixir
# host branch — add SettingsStore only (no HTTP listener on port 80 on host)
defp target_children do
  [
    NervesPhotos.SettingsStore,
    NervesPhotos.ImmichClient,
    NervesPhotos.WeatherFetcher,
    NervesPhotos.SlideTimer
  ]
end

# target branch — add both
defp target_children do
  viewport_config = Application.get_env(:nerves_photos, :viewport)
  [
    NervesPhotos.SettingsStore,
    NervesPhotos.SettingsServer,
    NervesPhotos.ImmichClient,
    NervesPhotos.WeatherFetcher,
    NervesPhotos.ImageLoader,
    NervesPhotos.SlideTimer,
    {Scenic, [viewport_config]}
  ]
end
```

- [ ] **Step 9: Advertise HTTP via mDNS**

In `config/target.exs`, add to the existing `mdns_lite` services list:

```elixir
%{
  protocol: "http",
  transport: "tcp",
  port: 80
}
```

- [ ] **Step 10: Run full test suite**

```bash
MIX_TARGET=host mix test
```

Expected: all tests pass.

- [ ] **Step 11: Commit**

```bash
git add lib/nerves_photos/settings_store.ex \
        lib/nerves_photos/settings_router.ex \
        lib/nerves_photos/settings_server.ex \
        lib/nerves_photos/application.ex \
        config/target.exs \
        test/nerves_photos/settings_store_test.exs
git commit -m "feat: add web settings UI served at nerves.local/settings"
```

---

## Task 12: Screenshot endpoint (`GET /screenshot`)

Add `GET /screenshot` to the existing `SettingsRouter`. The endpoint reads `/dev/fb0` (fbdev emulation layer over DRM, active by default on `nerves_system_rpi5` via `drm_kms_helper`), wraps the raw pixels in a BMP envelope, and returns `image/bmp`. No new dependencies — pure Elixir binary construction.

Visiting `http://nerves.local/screenshot` in a browser shows a live snapshot of the screen without needing an HDMI connection.

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex` — add `GET /screenshot` route + private helpers

**How it works:**
- `/sys/class/graphics/fb0/virtual_size` gives `"width,height\n"`
- `/dev/fb0` gives raw pixels in XRGB8888 format: bytes `[B, G, R, X]` per pixel
- BMP 32bpp BGRA has the same layout (`X` channel treated as alpha=0), so no byte-swapping needed
- A 14-byte file header + 40-byte DIB header prefix the raw pixel data

- [ ] **Step 1: Add the `/screenshot` route to `SettingsRouter`**

In `lib/nerves_photos/settings_router.ex`, add before the `match _` catch-all:

```elixir
get "/screenshot" do
  case capture_screenshot() do
    {:ok, bmp} ->
      conn
      |> put_resp_content_type("image/bmp")
      |> send_resp(200, bmp)

    {:error, reason} ->
      send_resp(conn, 500, "screenshot unavailable: #{inspect(reason)}")
  end
end
```

Add private helpers at the bottom of the module (before the closing `end`):

```elixir
defp capture_screenshot do
  with {:ok, size_str} <- File.read("/sys/class/graphics/fb0/virtual_size"),
       [w_str, h_str] = String.split(String.trim(size_str), ","),
       {width, ""} <- Integer.parse(w_str),
       {height, ""} <- Integer.parse(h_str),
       {:ok, pixels} <- File.read("/dev/fb0") do
    {:ok, build_bmp(pixels, width, height)}
  end
end

defp build_bmp(pixels, width, height) do
  pixel_data_size = byte_size(pixels)
  file_size = 14 + 40 + pixel_data_size

  file_header =
    "BM" <>
      <<file_size::little-32, 0::32, 54::little-32>>

  dib_header =
    <<40::little-32,
      width::little-32,
      (-height)::little-signed-32,
      1::little-16,
      32::little-16,
      0::little-32,
      pixel_data_size::little-32,
      2835::little-32,
      2835::little-32,
      0::little-32,
      0::little-32>>

  file_header <> dib_header <> pixels
end
```

- [ ] **Step 2: Run full test suite to confirm no regressions**

```bash
MIX_TARGET=host mix test
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/nerves_photos/settings_router.ex
git commit -m "feat: add GET /screenshot endpoint returning BMP of framebuffer"
```

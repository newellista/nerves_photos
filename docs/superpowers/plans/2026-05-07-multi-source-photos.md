# Multi-Source Photos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-Immich-album architecture with a pluggable multi-source system supporting 0..many Immich albums and 0..many Google Photos shared album links merged into one shuffled queue.

**Architecture:** A `PhotoSource` behaviour defines two stateless callbacks (`list_assets/1`, `fetch_image/2`). `PhotoQueue` GenServer replaces `ImmichClient`, reads a `photo_sources` list from `SettingsStore`, fetches assets concurrently from all sources, and exposes the same `current/0`, `advance/0`, `queue_position/0` interface. Assets are represented as `{module, source_id, config, metadata}` 4-tuples so `ImageLoader` always has the right config to call `module.fetch_image/2` without any additional lookup.

**Tech Stack:** Elixir/OTP, Req (HTTP), Jason (JSON), ExUnit with Req.Test for HTTP mocking

---

## File Map

**New files:**
- `lib/nerves_photos/photo_source.ex` — behaviour (`list_assets/1`, `fetch_image/2`)
- `lib/nerves_photos/sources/immich.ex` — Immich album source
- `lib/nerves_photos/sources/google_photos.ex` — Google Photos shared album source
- `lib/nerves_photos/photo_queue.ex` — GenServer replacing ImmichClient
- `test/nerves_photos/sources/immich_test.exs`
- `test/nerves_photos/sources/google_photos_test.exs`
- `test/nerves_photos/photo_queue_test.exs`
- `test/fixtures/google_photos_share.html`

**Modified files:**
- `lib/nerves_photos/settings_store.ex` — remove immich_* keys, add photo_sources
- `lib/nerves_photos/image_loader.ex` — accept 4-tuple, delegate fetch to source module
- `lib/nerves_photos/settings_router.ex` — new photo_sources API, remove immich_* endpoints
- `lib/nerves_photos/scene/main.ex` — use PhotoQueue, handle 4-tuple asset
- `lib/nerves_photos/scene/headless.ex` — use PhotoQueue, handle 4-tuple asset
- `lib/nerves_photos/application.ex` — replace ImmichClient with PhotoQueue
- `config/target.exs` — remove IMMICH_* env vars
- `test/nerves_photos/image_loader_test.exs` — update for new interface
- `test/nerves_photos/settings_router_test.exs` — update for PhotoQueue stubs and new endpoints
- `test/nerves_photos/settings_store_test.exs` — update for schema change
- `test/nerves_photos/integration_test.exs` — rewrite for PhotoQueue
- `docs/user-guide.md` — update setup instructions
- `README.md` — update configuration section

**Deleted files:**
- `lib/nerves_photos/immich_client.ex`
- `test/nerves_photos/immich_client_test.exs`

---

## Task 1: `PhotoSource` behaviour

**Files:**
- Create: `lib/nerves_photos/photo_source.ex`

- [ ] **Step 1: Create the behaviour module**

```elixir
# lib/nerves_photos/photo_source.ex
defmodule NervesPhotos.PhotoSource do
  @moduledoc false

  @callback list_assets(config :: map()) ::
              {:ok, [{source_id :: String.t(), metadata :: map()}]} | {:error, term()}

  @callback fetch_image(source_id :: String.t(), config :: map()) ::
              {:ok, binary()} | {:error, term()}
end
```

- [ ] **Step 2: Verify it compiles**

```bash
mix compile
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/nerves_photos/photo_source.ex
git commit -m "feat: add PhotoSource behaviour"
```

---

## Task 2: `Sources.Immich` — list_assets/1

**Files:**
- Create: `lib/nerves_photos/sources/immich.ex`
- Create: `test/nerves_photos/sources/immich_test.exs`

The `config` map contains: `url`, `api_key`, `album_id`, and optionally `req_options` (for test injection, not present in production).

- [ ] **Step 1: Write failing tests for list_assets/1**

```elixir
# test/nerves_photos/sources/immich_test.exs
defmodule NervesPhotos.Sources.ImmichTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.Sources.Immich

  @config %{
    url: "http://immich.test",
    api_key: "test-key",
    album_id: "album-1"
  }

  describe "list_assets/1" do
    setup do
      Req.Test.stub(ImmichSourceTest, fn conn ->
        if conn.request_path =~ "/api/albums/" do
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
                "exifInfo" => %{}
              }
            ]
          })
        end
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, ImmichSourceTest})
      {:ok, config: config}
    end

    test "returns ok with asset list on success", %{config: config} do
      assert {:ok, assets} = Immich.list_assets(config)
      assert length(assets) == 2
      assert {"asset-1", %{date: %Date{}, location: "Yosemite, USA"}} = List.first(assets)
    end

    test "returns asset with nil location when exifInfo is empty", %{config: config} do
      assert {:ok, assets} = Immich.list_assets(config)
      assert {"asset-2", %{date: _, location: nil}} = List.last(assets)
    end

    test "returns error on empty album" do
      Req.Test.stub(ImmichSourceEmptyTest, fn conn ->
        Req.Test.json(conn, %{"assets" => []})
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, ImmichSourceEmptyTest})
      assert {:error, :empty} = Immich.list_assets(config)
    end

    test "returns error on HTTP failure" do
      Req.Test.stub(ImmichSourceErrorTest, fn conn ->
        Plug.Conn.send_resp(conn, 500, "error")
      end)

      config = Map.put(@config, :req_options, [plug: {Req.Test, ImmichSourceErrorTest}, retry: false])
      assert {:error, {:http, 500}} = Immich.list_assets(config)
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/nerves_photos/sources/immich_test.exs
```
Expected: compilation error (module not found).

- [ ] **Step 3: Implement list_assets/1**

```elixir
# lib/nerves_photos/sources/immich.ex
defmodule NervesPhotos.Sources.Immich do
  @moduledoc false
  @behaviour NervesPhotos.PhotoSource

  @impl true
  def list_assets(%{url: url, api_key: api_key, album_id: album_id} = config) do
    req_options = Map.get(config, :req_options, [])
    req = Req.new([base_url: normalize_url(url), headers: [{"x-api-key", api_key}]] ++ req_options)

    case Req.get(req, url: "/api/albums/#{album_id}") do
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

  @impl true
  def fetch_image(_source_id, _config), do: {:error, :not_implemented}

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

  defp normalize_url(nil), do: nil

  defp normalize_url(url) do
    if String.starts_with?(url, ["http://", "https://"]), do: url, else: "http://#{url}"
  end
end
```

- [ ] **Step 4: Run list_assets tests to verify they pass**

```bash
mix test test/nerves_photos/sources/immich_test.exs --only describe:"list_assets/1"
```
Expected: 4 tests pass.

---

## Task 3: `Sources.Immich` — fetch_image/2

**Files:**
- Modify: `lib/nerves_photos/sources/immich.ex`
- Modify: `test/nerves_photos/sources/immich_test.exs`

- [ ] **Step 1: Add failing tests for fetch_image/2**

Add to `test/nerves_photos/sources/immich_test.exs` (inside the module, after the existing describe block):

```elixir
  describe "fetch_image/2" do
    setup do
      @fake_jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

      Req.Test.stub(ImmichFetchTest, fn conn ->
        if conn.request_path =~ "/thumbnail" do
          conn
          |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
          |> Plug.Conn.send_resp(200, @fake_jpeg)
        else
          Plug.Conn.send_resp(conn, 404, "not found")
        end
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, ImmichFetchTest})
      {:ok, config: config, fake_jpeg: @fake_jpeg}
    end

    test "returns ok with binary on success", %{config: config, fake_jpeg: fake_jpeg} do
      assert {:ok, ^fake_jpeg} = Immich.fetch_image("asset-1", config)
    end

    test "returns error on HTTP failure", %{config: config} do
      Req.Test.stub(ImmichFetchErrorTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, "not found")
      end)

      config = Map.put(config, :req_options, [plug: {Req.Test, ImmichFetchErrorTest}, retry: false])
      assert {:error, {:http, 404}} = Immich.fetch_image("missing", config)
    end
  end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/nerves_photos/sources/immich_test.exs
```
Expected: fetch_image tests fail (not implemented).

- [ ] **Step 3: Implement fetch_image/2**

Replace the placeholder `fetch_image/2` in `lib/nerves_photos/sources/immich.ex`:

```elixir
  @impl true
  def fetch_image(source_id, %{url: url, api_key: api_key} = config) do
    req_options = Map.get(config, :req_options, [])
    req = Req.new([base_url: normalize_url(url), headers: [{"x-api-key", api_key}]] ++ req_options)

    case Req.get(req, url: "/api/assets/#{source_id}/thumbnail", params: [size: "preview"]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
```

- [ ] **Step 4: Run all Immich source tests**

```bash
mix test test/nerves_photos/sources/immich_test.exs
```
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/sources/immich.ex test/nerves_photos/sources/immich_test.exs
git commit -m "feat: add Sources.Immich with list_assets/1 and fetch_image/2"
```

---

## Task 4: Google Photos HTML fixture

**Files:**
- Create: `test/fixtures/google_photos_share.html`

- [ ] **Step 1: Create fixture directory and file**

```bash
mkdir -p test/fixtures
```

- [ ] **Step 2: Write the fixture**

```html
<!DOCTYPE html>
<html>
<head><title>Test Album - Google Photos</title></head>
<body>
<div data-p="[null,null,null,null,null,null,null,null,null,1]"></div>
<script nonce="abc123">
AF_initDataCallback({key:'ds:3',isError:false,hash:'6',data:[[null,null,"Test Album",null,null,
[[null,null,null,null,"token1",null,null,null,null,null,null,null,null,null,null,null,null,null,
null,[["https://lh3.googleusercontent.com/pw/PHOTO1TOKEN=w2048-h1536-no","PHOTO1TOKEN"]],null,null,null,
null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null],
[null,null,null,null,"token2",null,null,null,null,null,null,null,null,null,null,null,null,null,
null,[["https://lh3.googleusercontent.com/pw/PHOTO2TOKEN=w2048-h1536-no","PHOTO2TOKEN"]]]]]]})</script>
<script>
var t = "https://lh3.googleusercontent.com/pw/PHOTO1TOKEN=w512-h384";
</script>
</body>
</html>
```

This fixture contains two unique photo base tokens (`PHOTO1TOKEN`, `PHOTO2TOKEN`) appearing at multiple sizes. The parser should deduplicate by base URL (stripping the `=...` size suffix).

- [ ] **Step 3: Commit**

```bash
git add test/fixtures/google_photos_share.html
git commit -m "test: add Google Photos share page HTML fixture"
```

---

## Task 5: `Sources.GooglePhotos`

**Files:**
- Create: `lib/nerves_photos/sources/google_photos.ex`
- Create: `test/nerves_photos/sources/google_photos_test.exs`

The parser extracts `lh3.googleusercontent.com` URLs, strips size params (the `=...` suffix), deduplicates, then appends `=w1920-h1440` for `fetch_image/2` requests.

- [ ] **Step 1: Write failing tests**

```elixir
# test/nerves_photos/sources/google_photos_test.exs
defmodule NervesPhotos.Sources.GooglePhotosTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.Sources.GooglePhotos

  @fixture File.read!("test/fixtures/google_photos_share.html")
  @config %{share_url: "https://photos.app.goo.gl/testshare"}

  describe "list_assets/1" do
    setup do
      Req.Test.stub(GooglePhotosListTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.send_resp(200, @fixture)
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosListTest})
      {:ok, config: config}
    end

    test "returns ok with deduplicated asset list", %{config: config} do
      assert {:ok, assets} = GooglePhotos.list_assets(config)
      # Fixture has 2 unique photo tokens, PHOTO1TOKEN appears at 2 sizes → deduped to 1
      assert length(assets) == 2
    end

    test "asset source_ids are base lh3 URLs without size suffix", %{config: config} do
      assert {:ok, assets} = GooglePhotos.list_assets(config)
      {source_id, _meta} = List.first(assets)
      assert source_id =~ "lh3.googleusercontent.com"
      refute source_id =~ "="
    end

    test "metadata is nil date and nil location", %{config: config} do
      assert {:ok, assets} = GooglePhotos.list_assets(config)
      Enum.each(assets, fn {_id, meta} ->
        assert meta == %{date: nil, location: nil}
      end)
    end

    test "returns error when no photo URLs found" do
      Req.Test.stub(GooglePhotosEmptyTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.send_resp(200, "<html><body>no photos here</body></html>")
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosEmptyTest})
      assert {:error, :no_photos_found} = GooglePhotos.list_assets(config)
    end

    test "returns error on HTTP failure" do
      Req.Test.stub(GooglePhotosHttpErrorTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, "not found")
      end)

      config = Map.put(@config, :req_options, [plug: {Req.Test, GooglePhotosHttpErrorTest}, retry: false])
      assert {:error, {:http, 404}} = GooglePhotos.list_assets(config)
    end
  end

  describe "fetch_image/2" do
    @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

    test "fetches the image at the source_id URL with a size suffix appended" do
      base_url = "https://lh3.googleusercontent.com/pw/PHOTO1TOKEN"

      Req.Test.stub(GooglePhotosFetchTest, fn conn ->
        assert String.starts_with?(conn.request_path, "/pw/PHOTO1TOKEN")
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
        |> Plug.Conn.send_resp(200, @fake_jpeg)
      end)

      config = Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosFetchTest})
      assert {:ok, @fake_jpeg} = GooglePhotos.fetch_image(base_url, config)
    end

    test "returns error on HTTP failure" do
      Req.Test.stub(GooglePhotosFetchErrorTest, fn conn ->
        Plug.Conn.send_resp(conn, 403, "forbidden")
      end)

      config = Map.put(@config, :req_options, [plug: {Req.Test, GooglePhotosFetchErrorTest}, retry: false])
      assert {:error, {:http, 403}} = GooglePhotos.fetch_image("https://lh3.googleusercontent.com/pw/X", config)
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/nerves_photos/sources/google_photos_test.exs
```
Expected: compilation error.

- [ ] **Step 3: Implement**

```elixir
# lib/nerves_photos/sources/google_photos.ex
defmodule NervesPhotos.Sources.GooglePhotos do
  @moduledoc false
  @behaviour NervesPhotos.PhotoSource
  require Logger

  # Matches lh3 URLs, stops at whitespace, quotes, backslashes, angle brackets
  @url_regex ~r|https://lh3\.googleusercontent\.com/[^\s"'\\<>=]+|

  @fetch_size "=w1920-h1440"

  @impl true
  def list_assets(%{share_url: share_url} = config) do
    req_options = Map.get(config, :req_options, [])
    req = Req.new(req_options)

    case Req.get(req, url: share_url) do
      {:ok, %{status: 200, body: body}} ->
        parse_share_page(body)

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_image(base_url, config) do
    req_options = Map.get(config, :req_options, [])
    req = Req.new(req_options)
    url = base_url <> @fetch_size

    case Req.get(req, url: url) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_share_page(html) do
    urls =
      @url_regex
      |> Regex.scan(html)
      |> List.flatten()
      |> Enum.uniq()

    if urls == [] do
      Logger.warning("GooglePhotos: no photo URLs found in share page")
      {:error, :no_photos_found}
    else
      assets = Enum.map(urls, &{&1, %{date: nil, location: nil}})
      {:ok, assets}
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/nerves_photos/sources/google_photos_test.exs
```
Expected: all tests pass. (The fixture has PHOTO1TOKEN at 2 sizes — `=w2048-h1536-no` and `=w512-h384` — both strip to the same base URL and deduplicate to 1. Combined with PHOTO2TOKEN = 2 unique assets.)

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/sources/google_photos.ex test/nerves_photos/sources/google_photos_test.exs
git commit -m "feat: add Sources.GooglePhotos with HTML share page parsing"
```

---

## Task 6: Update `SettingsStore`

**Files:**
- Modify: `lib/nerves_photos/settings_store.ex`
- Modify: `test/nerves_photos/settings_store_test.exs`

Remove `:immich_url`, `:immich_api_key`, `:immich_album_id`. Add `:photo_sources` (default `[]`).

- [ ] **Step 1: Write failing tests for new schema**

Replace `test/nerves_photos/settings_store_test.exs` entirely:

```elixir
defmodule NervesPhotos.SettingsStoreTest do
  use ExUnit.Case

  alias NervesPhotos.SettingsStore

  setup do
    path =
      System.tmp_dir!()
      |> Path.join("nerves_photos_test_#{:erlang.unique_integer([:positive])}.json")

    {:ok, _} = start_supervised({SettingsStore, path: path})
    {:ok, path: path}
  end

  test "photo_sources defaults to empty list" do
    assert SettingsStore.get(:photo_sources) == []
  end

  test "put/2 and get/1 round-trip photo_sources" do
    sources = [%{type: "immich", url: "http://srv:2283", api_key: "k", album_id: "a1"}]
    :ok = SettingsStore.put(:photo_sources, sources)
    assert SettingsStore.get(:photo_sources) == sources
  end

  test "put/2 persists photo_sources to disk and reloads after restart", %{path: path} do
    sources = [%{type: "google_photos", share_url: "https://photos.app.goo.gl/abc"}]
    :ok = SettingsStore.put(:photo_sources, sources)

    stop_supervised!(SettingsStore)
    {:ok, _} = start_supervised({SettingsStore, path: path})

    assert SettingsStore.get(:photo_sources) == sources
  end

  test "put/2 returns error for unknown key" do
    assert {:error, :unknown_key} = SettingsStore.put(:immich_url, "http://x")
  end

  test "put/2 and get/1 round-trip slide_interval_ms" do
    :ok = SettingsStore.put(:slide_interval_ms, 10_000)
    assert SettingsStore.get(:slide_interval_ms) == 10_000
  end
end
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/nerves_photos/settings_store_test.exs
```
Expected: `photo_sources` tests fail, `immich_url` unknown key test fails.

- [ ] **Step 3: Update SettingsStore**

Replace `lib/nerves_photos/settings_store.ex`:

```elixir
defmodule NervesPhotos.SettingsStore do
  @moduledoc false
  use GenServer

  @keys [
    :photo_sources,
    :slide_interval_ms,
    :wifi_ssid,
    :wifi_psk,
    :weather_zip
  ]
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

    case persist(state.path, settings) do
      :ok -> {:reply, :ok, %{state | settings: settings}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put, _key, _value}, _from, state) do
    {:reply, {:error, :unknown_key}, state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.settings, state}
  end

  defp load(path) do
    defaults = %{
      photo_sources: Application.get_env(:nerves_photos, :photo_sources, []),
      slide_interval_ms: Application.get_env(:nerves_photos, :slide_interval_ms, 30_000),
      wifi_ssid: nil,
      wifi_psk: nil,
      weather_zip: nil
    }

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json, keys: :atoms) do
          {:ok, saved} -> Map.merge(defaults, Map.take(saved, @keys))
          {:error, _} -> defaults
        end

      {:error, _} ->
        defaults
    end
  end

  defp persist(path, settings) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(settings))
    end
  end
end
```

- [ ] **Step 4: Run SettingsStore tests**

```bash
mix test test/nerves_photos/settings_store_test.exs
```
Expected: all 5 tests pass.

- [ ] **Step 5: Run full suite to check for regressions**

```bash
mix test
```
Expected: failures in immich_client_test (references immich_url setting) and settings_router_test (ImmichClient) — these are expected and will be fixed in later tasks.

- [ ] **Step 6: Commit**

```bash
git add lib/nerves_photos/settings_store.ex test/nerves_photos/settings_store_test.exs
git commit -m "feat: replace immich_* settings keys with photo_sources list"
```

---

## Task 7: `PhotoQueue` — skeleton + not_configured state

**Files:**
- Create: `lib/nerves_photos/photo_queue.ex`
- Create: `test/nerves_photos/photo_queue_test.exs`

Asset tuples are `{module, source_id, config, metadata}`.

- [ ] **Step 1: Write failing tests for skeleton**

```elixir
# test/nerves_photos/photo_queue_test.exs
defmodule NervesPhotos.PhotoQueueTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.PhotoQueue

  # A source module stub that returns two assets
  defmodule GoodSource do
    def list_assets(config) do
      {:ok,
       [
         {"asset-1", %{date: ~D[2024-01-01], location: "Paris"}},
         {"asset-2", %{date: ~D[2024-02-01], location: "Rome"}}
       ]}
    end

    def fetch_image(id, _config), do: {:ok, "bytes-#{id}"}
  end

  defmodule FailingSource do
    def list_assets(_config), do: {:error, :timeout}
    def fetch_image(_id, _config), do: {:error, :timeout}
  end

  defmodule EmptySource do
    def list_assets(_config), do: {:error, :empty}
    def fetch_image(_id, _config), do: {:error, :not_found}
  end

  describe "with no sources configured" do
    setup do
      {:ok, pid} = start_supervised({PhotoQueue, sources: [], name: :pq_empty})
      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "current/0 returns :not_configured", %{pid: pid} do
      assert GenServer.call(pid, :current) == :not_configured
    end

    test "advance/0 returns :not_configured", %{pid: pid} do
      assert GenServer.call(pid, :advance) == :not_configured
    end

    test "queue_position/0 returns {0, 0}", %{pid: pid} do
      assert GenServer.call(pid, :queue_position) == {0, 0}
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/nerves_photos/photo_queue_test.exs
```
Expected: compilation error.

- [ ] **Step 3: Write the PhotoQueue skeleton**

```elixir
# lib/nerves_photos/photo_queue.ex
defmodule NervesPhotos.PhotoQueue do
  @moduledoc false
  use GenServer
  require Logger

  @backoff_initial 1_000
  @backoff_max 60_000
  @recheck_interval 5_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def current, do: GenServer.call(__MODULE__, :current)
  def advance, do: GenServer.call(__MODULE__, :advance)
  def queue_position, do: GenServer.call(__MODULE__, :queue_position)

  @impl true
  def init(opts) do
    sources = Keyword.get(opts, :sources, :from_store)

    sources =
      if sources == :from_store do
        NervesPhotos.SettingsStore.get(:photo_sources) || []
      else
        sources
      end

    state = %{
      sources: sources,
      queue: [],
      index: 0,
      status: :loading,
      backoff: @backoff_initial
    }

    if sources == [] do
      Process.send_after(self(), :recheck_config, @recheck_interval)
      {:ok, %{state | status: :not_configured}}
    else
      send(self(), :fetch_all)
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:current, _from, %{status: :not_configured} = state),
    do: {:reply, :not_configured, state}

  def handle_call(:advance, _from, %{status: :not_configured} = state),
    do: {:reply, :not_configured, state}

  def handle_call(:queue_position, _from, %{status: :not_configured} = state),
    do: {:reply, {0, 0}, state}

  def handle_call(:current, _from, %{queue: []} = state),
    do: {:reply, state.status, state}

  def handle_call(:advance, _from, %{queue: []} = state),
    do: {:reply, state.status, state}

  def handle_call(:queue_position, _from, %{queue: []} = state),
    do: {:reply, {0, 0}, state}

  def handle_call(:current, _from, state),
    do: {:reply, Enum.at(state.queue, state.index), state}

  def handle_call(:advance, _from, state) do
    next = state.index + 1

    if next >= length(state.queue) do
      send(self(), :fetch_all)
      new_state = %{state | index: 0}
      {:reply, Enum.at(new_state.queue, 0), new_state}
    else
      new_state = %{state | index: next}
      {:reply, Enum.at(new_state.queue, next), new_state}
    end
  end

  def handle_call(:queue_position, _from, state),
    do: {:reply, {state.index + 1, length(state.queue)}, state}

  @impl true
  def handle_info(:recheck_config, state) do
    sources = NervesPhotos.SettingsStore.get(:photo_sources) || []

    if sources == [] do
      Process.send_after(self(), :recheck_config, @recheck_interval)
      {:noreply, state}
    else
      send(self(), :fetch_all)
      {:noreply, %{state | sources: sources, status: :loading}}
    end
  end

  def handle_info(:fetch_all, state) do
    results =
      Task.async_stream(
        state.sources,
        fn source -> {source, fetch_source(source)} end,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    successes =
      for {:ok, {source, {:ok, assets}}} <- results do
        module = source_module(source)
        Enum.map(assets, fn {id, meta} -> {module, id, source, meta} end)
      end
      |> List.flatten()

    failures =
      for {:ok, {source, {:error, reason}}} <- results do
        {source, reason}
      end

    Enum.each(failures, fn {source, reason} ->
      Logger.warning("PhotoQueue: source #{inspect(source[:type])} failed: #{inspect(reason)}")
    end)

    cond do
      successes != [] ->
        queue = Enum.shuffle(successes)
        {:noreply, %{state | queue: queue, index: 0, status: :ok, backoff: @backoff_initial}}

      Enum.all?(results, fn {:ok, {_src, result}} -> result == {:error, :empty} end) ->
        Logger.info("PhotoQueue: all sources empty, retrying in 5 minutes")
        Process.send_after(self(), :fetch_all, 5 * 60 * 1_000)
        {:noreply, %{state | status: :empty}}

      true ->
        backoff = state.backoff
        Logger.warning("PhotoQueue: all sources failed, retrying in #{backoff}ms")
        Process.send_after(self(), :fetch_all, backoff)
        {:noreply, %{state | status: :disconnected, backoff: min(backoff * 2, @backoff_max)}}
    end
  end

  defp fetch_source(source) do
    module = source_module(source)
    module.list_assets(source)
  end

  defp source_module(%{type: "immich"}), do: NervesPhotos.Sources.Immich
  defp source_module(%{type: "google_photos"}), do: NervesPhotos.Sources.GooglePhotos

  defp source_module(type),
    do: raise("PhotoQueue: unknown source type #{inspect(type)}")
end
```

- [ ] **Step 4: Run not_configured tests**

```bash
mix test test/nerves_photos/photo_queue_test.exs --only describe:"with no sources configured"
```
Expected: 3 tests pass.

---

## Task 8: `PhotoQueue` — single source, multiple sources, queue exhaustion

**Files:**
- Modify: `test/nerves_photos/photo_queue_test.exs`

- [ ] **Step 1: Add tests for single and multi-source loading**

Add to `test/nerves_photos/photo_queue_test.exs`:

```elixir
  describe "with a single source" do
    setup do
      source = %{type: "stub_good"}
      {:ok, pid} = start_supervised({PhotoQueue, sources: [source], source_module_fn: fn _ -> GoodSource end, name: :pq_single})
      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "current/0 returns first queued asset", %{pid: pid} do
      result = GenServer.call(pid, :current)
      assert {GoodSource, id, _config, %{date: _, location: _}} = result
      assert id in ["asset-1", "asset-2"]
    end

    test "advance/0 returns next asset", %{pid: pid} do
      {_, id1, _, _} = GenServer.call(pid, :current)
      {_, id2, _, _} = GenServer.call(pid, :advance)
      assert id1 != id2
    end

    test "queue_position/0 tracks index", %{pid: pid} do
      assert {1, 2} = GenServer.call(pid, :queue_position)
      GenServer.call(pid, :advance)
      assert {2, 2} = GenServer.call(pid, :queue_position)
    end

    test "advance/0 triggers re-fetch when last photo is reached", %{pid: pid} do
      GenServer.call(pid, :advance)  # move to index 1
      GenServer.call(pid, :advance)  # exhausts queue → re-fetch sent
      :sys.get_state(pid)            # wait for re-fetch to complete
      assert {1, 2} = GenServer.call(pid, :queue_position)
    end
  end

  describe "with multiple sources" do
    setup do
      sources = [%{type: "stub_good"}, %{type: "stub_good"}]
      {:ok, pid} = start_supervised({PhotoQueue, sources: sources, source_module_fn: fn _ -> GoodSource end, name: :pq_multi})
      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "queue contains assets from all sources merged", %{pid: pid} do
      {_idx, total} = GenServer.call(pid, :queue_position)
      assert total == 4  # 2 assets × 2 sources
    end
  end

  describe "partial source failure" do
    setup do
      sources = [%{type: "stub_good"}, %{type: "stub_fail"}]
      module_fn = fn
        %{type: "stub_good"} -> GoodSource
        %{type: "stub_fail"} -> FailingSource
      end
      {:ok, pid} = start_supervised({PhotoQueue, sources: sources, source_module_fn: module_fn, name: :pq_partial})
      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "shows photos from successful source", %{pid: pid} do
      assert {_, _, total} = GenServer.call(pid, :queue_position)
      assert total == 2
    end

    test "status is :ok when at least one source succeeded", %{pid: pid} do
      result = GenServer.call(pid, :current)
      assert {_module, _id, _config, _meta} = result
    end
  end

  describe "total source failure" do
    setup do
      sources = [%{type: "stub_fail"}]
      module_fn = fn _ -> FailingSource end
      {:ok, pid} = start_supervised({PhotoQueue, sources: sources, source_module_fn: module_fn, name: :pq_fail})
      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "current/0 returns :disconnected", %{pid: pid} do
      assert GenServer.call(pid, :current) == :disconnected
    end
  end

  describe "all sources empty" do
    setup do
      sources = [%{type: "stub_empty"}]
      module_fn = fn _ -> EmptySource end
      {:ok, pid} = start_supervised({PhotoQueue, sources: sources, source_module_fn: module_fn, name: :pq_empty_src})
      :sys.get_state(pid)
      {:ok, pid: pid}
    end

    test "current/0 returns :empty", %{pid: pid} do
      assert GenServer.call(pid, :current) == :empty
    end
  end
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/nerves_photos/photo_queue_test.exs
```
Expected: new tests fail because `source_module_fn` opt isn't supported yet.

- [ ] **Step 3: Add `source_module_fn` injection to PhotoQueue for testability**

In `lib/nerves_photos/photo_queue.ex`, update `init/1` to accept a `source_module_fn` opt:

```elixir
  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    sources_opt = Keyword.get(opts, :sources, :from_store)
    source_module_fn = Keyword.get(opts, :source_module_fn, &source_module/1)

    sources =
      if sources_opt == :from_store do
        NervesPhotos.SettingsStore.get(:photo_sources) || []
      else
        sources_opt
      end

    state = %{
      sources: sources,
      queue: [],
      index: 0,
      status: :loading,
      backoff: @backoff_initial,
      source_module_fn: source_module_fn
    }

    if sources == [] do
      Process.send_after(self(), :recheck_config, @recheck_interval)
      {:ok, %{state | status: :not_configured}}
    else
      send(self(), :fetch_all)
      {:ok, state}
    end
  end
```

Update `handle_info(:fetch_all, ...)` to use `state.source_module_fn` instead of calling `source_module/1` directly:

```elixir
  def handle_info(:fetch_all, state) do
    results =
      Task.async_stream(
        state.sources,
        fn source -> {source, state.source_module_fn.(source).list_assets(source)} end,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    successes =
      for {:ok, {source, {:ok, assets}}} <- results do
        module = state.source_module_fn.(source)
        Enum.map(assets, fn {id, meta} -> {module, id, source, meta} end)
      end
      |> List.flatten()

    failures =
      for {:ok, {source, {:error, reason}}} <- results do
        {source, reason}
      end

    Enum.each(failures, fn {source, reason} ->
      Logger.warning("PhotoQueue: source #{inspect(Map.get(source, :type))} failed: #{inspect(reason)}")
    end)

    cond do
      successes != [] ->
        queue = Enum.shuffle(successes)
        {:noreply, %{state | queue: queue, index: 0, status: :ok, backoff: @backoff_initial}}

      Enum.all?(results, fn
        {:ok, {_src, {:error, :empty}}} -> true
        _ -> false
      end) ->
        Logger.info("PhotoQueue: all sources empty, retrying in 5 minutes")
        Process.send_after(self(), :fetch_all, 5 * 60 * 1_000)
        {:noreply, %{state | status: :empty}}

      true ->
        backoff = state.backoff
        Logger.warning("PhotoQueue: all sources failed, retrying in #{backoff}ms")
        Process.send_after(self(), :fetch_all, backoff)
        {:noreply, %{state | status: :disconnected, backoff: min(backoff * 2, @backoff_max)}}
    end
  end
```

- [ ] **Step 4: Run PhotoQueue tests**

```bash
mix test test/nerves_photos/photo_queue_test.exs
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/photo_queue.ex test/nerves_photos/photo_queue_test.exs
git commit -m "feat: add PhotoQueue GenServer replacing ImmichClient"
```

---

## Task 9: Update `ImageLoader`

**Files:**
- Modify: `lib/nerves_photos/image_loader.ex`
- Modify: `test/nerves_photos/image_loader_test.exs`

`load/1` now accepts the 4-tuple `{module, source_id, config, metadata}` and calls `module.fetch_image(source_id, config)`. The `connection_info_fn` and `req_options` opts are removed.

- [ ] **Step 1: Write failing tests**

Replace `test/nerves_photos/image_loader_test.exs`:

```elixir
defmodule NervesPhotos.ImageLoaderTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.ImageLoader

  @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

  defmodule GoodSource do
    def fetch_image("asset-1", _config), do: {:ok, <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>}
    def fetch_image(_, _), do: {:error, :not_found}
  end

  defmodule BadSource do
    def fetch_image(_id, _config), do: {:error, {:http, 404}}
  end

  setup do
    {:ok, _pid} =
      start_supervised(
        {ImageLoader, put_fn: fn _key, _bytes -> :ok end}
      )

    :ok
  end

  test "load/2 sends {:image_loaded, key} to caller on success" do
    asset = {GoodSource, "asset-1", %{}, %{date: nil, location: nil}}
    ImageLoader.load(asset, self())
    assert_receive {:image_loaded, "photo:current"}, 500
  end

  test "load/2 sends {:image_load_error, asset} on fetch failure" do
    asset = {BadSource, "bad-asset", %{}, %{date: nil, location: nil}}
    ImageLoader.load(asset, self())
    assert_receive {:image_load_error, ^asset}, 500
  end

  test "load/3 accepts a custom stream key" do
    asset = {GoodSource, "asset-1", %{}, %{date: nil, location: nil}}
    ImageLoader.load(asset, self(), "photo:custom")
    assert_receive {:image_loaded, "photo:custom"}, 500
  end
end
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/nerves_photos/image_loader_test.exs
```
Expected: tests fail (interface mismatch).

- [ ] **Step 3: Rewrite ImageLoader**

Replace `lib/nerves_photos/image_loader.ex`:

```elixir
defmodule NervesPhotos.ImageLoader do
  @moduledoc false
  use GenServer
  require Logger

  alias Scenic.Assets.Stream, as: ScenicStream

  @stream_key "photo:current"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def load({_module, _source_id, _config, _meta} = asset, reply_to \\ nil, stream_key \\ @stream_key) do
    GenServer.cast(__MODULE__, {:load, asset, reply_to || self(), stream_key})
  end

  @impl true
  def init(opts) do
    {:ok, %{put_fn: opts[:put_fn] || (&stream_put/2)}}
  end

  @impl true
  def handle_cast({:load, asset, reply_to, stream_key}, state) do
    Task.start(fn -> do_load(asset, reply_to, stream_key, state) end)
    {:noreply, state}
  end

  defp do_load({module, source_id, config, _meta} = asset, reply_to, stream_key, state) do
    case module.fetch_image(source_id, config) do
      {:ok, image_bytes} ->
        case state.put_fn.(stream_key, image_bytes) do
          :ok -> send(reply_to, {:image_loaded, stream_key})
          {:error, reason} ->
            Logger.warning("ImageLoader: stream put failed for #{source_id}: #{inspect(reason)}")
            send(reply_to, {:image_load_error, asset})
        end

      {:error, reason} ->
        Logger.warning("ImageLoader: failed to load #{source_id}: #{inspect(reason)}")
        send(reply_to, {:image_load_error, asset})
    end
  end

  defp stream_put(stream_key, image_bytes) do
    case ScenicStream.Image.from_binary(image_bytes) do
      {:ok, img} -> ScenicStream.put(stream_key, img)
      {:error, :invalid} -> {:error, :invalid_image}
    end
  end
end
```

- [ ] **Step 4: Run ImageLoader tests**

```bash
mix test test/nerves_photos/image_loader_test.exs
```
Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/image_loader.ex test/nerves_photos/image_loader_test.exs
git commit -m "feat: update ImageLoader to delegate fetch to source module via 4-tuple asset"
```

---

## Task 10: Update `SettingsRouter`

**Files:**
- Modify: `lib/nerves_photos/settings_router.ex`
- Modify: `test/nerves_photos/settings_router_test.exs`

Changes:
1. Add JSON parser support
2. Replace `ImmichClient` refs with `PhotoQueue`
3. Replace `GET /current/photo` Immich-specific fetch with `module.fetch_image/2`
4. Remove `POST /settings` immich_* param handling and form fields
5. Add `GET/POST/DELETE /settings/photo_sources`

- [ ] **Step 1: Update the SettingsRouter test stubs and add photo_sources tests**

Replace `test/nerves_photos/settings_router_test.exs`:

```elixir
defmodule NervesPhotos.SettingsRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts NervesPhotos.SettingsRouter.init([])

  defmodule TestPhotoSource do
    def fetch_image("asset123", _config), do: {:ok, <<0xFF, 0xD8, 0xFF, 0xE0>>}
    def fetch_image(_, _), do: {:error, :not_found}
  end

  defmodule PhotoQueueStub do
    use GenServer

    def start_link(state),
      do: GenServer.start_link(__MODULE__, state, name: NervesPhotos.PhotoQueue)

    def init(state), do: {:ok, state}
    def handle_call(:current, _, state), do: {:reply, state.current, state}
    def handle_call(:queue_position, _, state), do: {:reply, state.queue_position, state}
  end

  defmodule WeatherStub do
    use GenServer

    def start_link(state),
      do: GenServer.start_link(__MODULE__, state, name: NervesPhotos.WeatherFetcher)

    def init(state), do: {:ok, state}
    def handle_call(:current, _, state), do: {:reply, state.current, state}
  end

  setup do
    for mod <- [
          NervesPhotos.PhotoQueue,
          NervesPhotos.WeatherFetcher,
          NervesPhotos.SettingsStore
        ] do
      if pid = Process.whereis(mod), do: GenServer.stop(pid)
    end

    Application.delete_env(:nerves_photos, :req_options)
    :ok
  end

  describe "GET /current/photo" do
    setup do
      start_supervised!(
        {PhotoQueueStub,
         %{
           current:
             {TestPhotoSource, "asset123", %{}, %{date: ~D[2024-06-01], location: "Paris"}},
           queue_position: {1, 5}
         }}
      )

      :ok
    end

    test "returns JPEG bytes by delegating to source module" do
      conn = conn(:get, "/current/photo") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert conn.resp_body == <<0xFF, 0xD8, 0xFF, 0xE0>>
    end

    test "returns 503 when PhotoQueue returns :loading" do
      stop_supervised!(PhotoQueueStub)
      start_supervised!({PhotoQueueStub, %{current: :loading, queue_position: {0, 0}}})

      conn = conn(:get, "/current/photo") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.status == 503
    end

    test "returns 503 when fetch_image fails" do
      stop_supervised!(PhotoQueueStub)

      start_supervised!(
        {PhotoQueueStub,
         %{
           current: {TestPhotoSource, "bad-asset", %{}, %{}},
           queue_position: {1, 5}
         }}
      )

      conn = conn(:get, "/current/photo") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.status == 503
    end
  end

  describe "GET /current" do
    setup do
      start_supervised!(
        {NervesPhotos.SettingsStore, [path: "/tmp/nerves_photos_test_settings.json"]}
      )

      start_supervised!(
        {PhotoQueueStub,
         %{
           current:
             {TestPhotoSource, "asset123", %{},
              %{date: ~D[2024-06-01], location: "Paris, France"}},
           queue_position: {3, 20}
         }}
      )

      start_supervised!({WeatherStub, %{current: {:ok, %{temp_f: 72.5, condition: "Sunny"}}}})

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

    test "includes weather overlay" do
      conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.resp_body =~ "73°F"
      assert conn.resp_body =~ "Sunny"
    end

    test "shows Reconnecting banner when disconnected" do
      stop_supervised!(PhotoQueueStub)
      start_supervised!({PhotoQueueStub, %{current: :disconnected, queue_position: {0, 0}}})

      conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.resp_body =~ "Reconnecting..."
    end

    test "shows No photos found when empty" do
      stop_supervised!(PhotoQueueStub)
      start_supervised!({PhotoQueueStub, %{current: :empty, queue_position: {0, 0}}})

      conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.resp_body =~ "No photos found"
    end

    test "shows Not configured message" do
      stop_supervised!(PhotoQueueStub)
      start_supervised!({PhotoQueueStub, %{current: :not_configured, queue_position: {0, 0}}})

      conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.resp_body =~ "Not configured"
    end
  end

  describe "GET /settings/photo_sources" do
    setup do
      start_supervised!(
        {NervesPhotos.SettingsStore, [path: "/tmp/nerves_photos_test_sources_#{:erlang.unique_integer([:positive])}.json"]}
      )
      :ok
    end

    test "returns empty JSON array when no sources configured" do
      conn = conn(:get, "/settings/photo_sources") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == []
    end

    test "returns current sources" do
      NervesPhotos.SettingsStore.put(:photo_sources, [
        %{type: "immich", url: "http://srv", api_key: "k", album_id: "a"}
      ])

      conn = conn(:get, "/settings/photo_sources") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.status == 200
      [source] = Jason.decode!(conn.resp_body)
      assert source["type"] == "immich"
    end
  end

  describe "POST /settings/photo_sources" do
    setup do
      start_supervised!(
        {NervesPhotos.SettingsStore, [path: "/tmp/nerves_photos_test_post_#{:erlang.unique_integer([:positive])}.json"]}
      )
      :ok
    end

    test "appends an immich source" do
      body = Jason.encode!(%{type: "immich", url: "http://srv", api_key: "k", album_id: "a"})

      conn =
        conn(:post, "/settings/photo_sources", body)
        |> put_req_header("content-type", "application/json")
        |> NervesPhotos.SettingsRouter.call(@opts)

      assert conn.status == 201
      sources = NervesPhotos.SettingsStore.get(:photo_sources)
      assert length(sources) == 1
      assert hd(sources)[:type] == "immich"
    end

    test "appends a google_photos source" do
      body = Jason.encode!(%{type: "google_photos", share_url: "https://photos.app.goo.gl/x"})

      conn =
        conn(:post, "/settings/photo_sources", body)
        |> put_req_header("content-type", "application/json")
        |> NervesPhotos.SettingsRouter.call(@opts)

      assert conn.status == 201
      sources = NervesPhotos.SettingsStore.get(:photo_sources)
      assert hd(sources)[:type] == "google_photos"
    end

    test "rejects unknown source type with 422" do
      body = Jason.encode!(%{type: "dropbox", path: "/photos"})

      conn =
        conn(:post, "/settings/photo_sources", body)
        |> put_req_header("content-type", "application/json")
        |> NervesPhotos.SettingsRouter.call(@opts)

      assert conn.status == 422
    end
  end

  describe "DELETE /settings/photo_sources/:index" do
    setup do
      path = "/tmp/nerves_photos_test_del_#{:erlang.unique_integer([:positive])}.json"
      start_supervised!({NervesPhotos.SettingsStore, [path: path]})

      NervesPhotos.SettingsStore.put(:photo_sources, [
        %{type: "immich", url: "http://a", api_key: "k1", album_id: "a1"},
        %{type: "immich", url: "http://b", api_key: "k2", album_id: "a2"}
      ])

      :ok
    end

    test "removes source at given index" do
      conn =
        conn(:delete, "/settings/photo_sources/0")
        |> NervesPhotos.SettingsRouter.call(@opts)

      assert conn.status == 200
      sources = NervesPhotos.SettingsStore.get(:photo_sources)
      assert length(sources) == 1
      assert hd(sources)[:album_id] == "a2"
    end

    test "returns 404 for out-of-bounds index" do
      conn =
        conn(:delete, "/settings/photo_sources/5")
        |> NervesPhotos.SettingsRouter.call(@opts)

      assert conn.status == 404
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
mix test test/nerves_photos/settings_router_test.exs
```
Expected: failures (PhotoQueue not referenced, endpoints missing).

- [ ] **Step 3: Rewrite SettingsRouter**

Replace `lib/nerves_photos/settings_router.ex` with the updated version. Key changes:
- Add `json_decoder: Jason` to parsers
- Replace all `ImmichClient` references with `PhotoQueue`
- Replace `GET /current/photo` Req-based fetch with `module.fetch_image(source_id, config)`
- Remove POST /settings immich_* params and form fields
- Add GET/POST/DELETE `/settings/photo_sources`

```elixir
defmodule NervesPhotos.SettingsRouter do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason)
  plug(:dispatch)

  @valid_source_types ~w(immich google_photos)

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
    source = for {k, v} <- conn.body_params, into: %{}, do: {String.to_atom(k), v}

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
    idx = String.to_integer(conn.params["index"])

    if idx >= 0 and idx < length(sources) do
      updated = List.delete_at(sources, idx)
      NervesPhotos.SettingsStore.put(:photo_sources, updated)

      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, Jason.encode!(updated))
    else
      send_resp(conn, 404, Jason.encode!(%{error: "index out of bounds"}))
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
    ~s(<div class="centered-msg overlay">No photos found</div>)
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
```

- [ ] **Step 4: Run SettingsRouter tests**

```bash
mix test test/nerves_photos/settings_router_test.exs
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/nerves_photos/settings_router.ex test/nerves_photos/settings_router_test.exs
git commit -m "feat: update SettingsRouter — PhotoQueue, photo_sources API, remove immich_* form fields"
```

---

## Task 11: Update scenes, Application, and config

**Files:**
- Modify: `lib/nerves_photos/scene/main.ex`
- Modify: `lib/nerves_photos/scene/headless.ex`
- Modify: `lib/nerves_photos/application.ex`
- Modify: `config/target.exs`

- [ ] **Step 1: Update Scene.Main**

In `lib/nerves_photos/scene/main.ex`, make two changes:

Replace the `handle_info({:slide_timer, :next_photo}, ...)` handler:

```elixir
  @impl GenServer
  def handle_info({:slide_timer, :next_photo}, %{assigns: %{transition: :idle}} = scene) do
    case NervesPhotos.PhotoQueue.advance() do
      {_module, _source_id, _config, metadata} = asset ->
        NervesPhotos.ImageLoader.load(asset, self())
        {:noreply, assign(scene, metadata: metadata, transition: :loading)}

      :disconnected ->
        {:noreply, assign(scene, disconnected: true)}

      :empty ->
        {:noreply, assign(scene, empty_album: true)}

      :loading ->
        {:noreply, scene}

      :not_configured ->
        {:noreply, scene}
    end
  end
```

Replace the `queue_position` call in `render/1`:

```elixir
    {current, total} = NervesPhotos.PhotoQueue.queue_position()
```

- [ ] **Step 2: Update Scene.Headless**

In `lib/nerves_photos/scene/headless.ex`, replace `handle_info({:slide_timer, :next_photo}, ...)`:

```elixir
  @impl true
  def handle_info({:slide_timer, :next_photo}, state) do
    case NervesPhotos.PhotoQueue.advance() do
      {_module, asset_id, _config, %{date: date, location: location}} ->
        Logger.info("Headless slide: #{asset_id} — #{date}, #{location}")

      _ ->
        :ok
    end

    {:noreply, state}
  end
```

- [ ] **Step 3: Update Application**

In `lib/nerves_photos/application.ex`, replace `NervesPhotos.ImmichClient` with `NervesPhotos.PhotoQueue` in both `target_children/0` clauses:

```elixir
      defp target_children do
        [
          NervesPhotos.SettingsStore,
          NervesPhotos.PhotoQueue,
          NervesPhotos.WeatherFetcher,
          NervesPhotos.SlideTimer
        ]
      end
```

and:

```elixir
      defp target_children do
        core = [
          NervesPhotos.SettingsStore,
          NervesPhotos.ConnectivityMonitor,
          NervesPhotos.SettingsServer,
          NervesPhotos.PhotoQueue,
          NervesPhotos.WeatherFetcher,
          NervesPhotos.SlideTimer
        ]

        if Application.get_env(:nerves_photos, :headless_mode, false) do
          core ++ [NervesPhotos.Scene.Headless]
        else
          viewport_config = Application.get_env(:nerves_photos, :viewport)
          core ++ [NervesPhotos.ImageLoader, {Scenic, [viewport_config]}]
        end
      end
```

- [ ] **Step 4: Update config/target.exs**

Remove the three Immich env var lines from `config/target.exs`. Replace:

```elixir
config :nerves_photos,
  immich_url: System.get_env("IMMICH_URL"),
  immich_api_key: System.get_env("IMMICH_API_KEY"),
  immich_album_id: System.get_env("IMMICH_ALBUM_ID"),
  slide_interval_ms:
    System.get_env("SLIDE_INTERVAL_MS", "30000") |> String.trim() |> String.to_integer(),
  show_debug: System.get_env("SHOW_DEBUG", "false") == "true",
  headless_mode: System.get_env("HEADLESS_MODE", "true") == "true"
```

with:

```elixir
config :nerves_photos,
  slide_interval_ms:
    System.get_env("SLIDE_INTERVAL_MS", "30000") |> String.trim() |> String.to_integer(),
  show_debug: System.get_env("SHOW_DEBUG", "false") == "true",
  headless_mode: System.get_env("HEADLESS_MODE", "true") == "true"
```

- [ ] **Step 5: Compile to check for errors**

```bash
mix compile
```
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add lib/nerves_photos/scene/main.ex lib/nerves_photos/scene/headless.ex \
        lib/nerves_photos/application.ex config/target.exs
git commit -m "feat: wire PhotoQueue into scenes, Application, and remove IMMICH_* env vars"
```

---

## Task 12: Delete ImmichClient and rewrite integration test

**Files:**
- Delete: `lib/nerves_photos/immich_client.ex`
- Delete: `test/nerves_photos/immich_client_test.exs`
- Modify: `test/nerves_photos/integration_test.exs`

- [ ] **Step 1: Delete ImmichClient files**

```bash
rm lib/nerves_photos/immich_client.ex
rm test/nerves_photos/immich_client_test.exs
```

- [ ] **Step 2: Rewrite the integration test**

Replace `test/nerves_photos/integration_test.exs`:

```elixir
defmodule NervesPhotos.IntegrationTest do
  use ExUnit.Case

  @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

  defmodule FakeImmich do
    def list_assets(_config) do
      {:ok,
       [
         {"asset-001", %{date: ~D[2023-06-12], location: "Yosemite, USA"}},
         {"asset-002", %{date: ~D[2024-01-01], location: "Paris, France"}}
       ]}
    end

    def fetch_image(_id, _config), do: {:ok, <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>}
  end

  defmodule FakeWeather do
    use GenServer

    def start_link(state),
      do: GenServer.start_link(__MODULE__, state, name: NervesPhotos.WeatherFetcher)

    def init(state), do: {:ok, state}
    def handle_call(:current, _, state), do: {:reply, state, state}
  end

  setup do
    start_supervised!(NervesPhotos.SettingsStore)

    start_supervised!(
      {NervesPhotos.PhotoQueue,
       sources: [%{type: "stub"}],
       source_module_fn: fn _ -> FakeImmich end}
    )

    start_supervised!(
      {FakeWeather, {:ok, %{temp_f: 72.0, condition: "Sunny", icon_code: 2}}}
    )

    start_supervised!(
      {NervesPhotos.ImageLoader,
       put_fn: fn _key, _bytes -> :ok end}
    )

    start_supervised!({NervesPhotos.SlideTimer, interval_ms: 50, target: self()})

    :ok
  end

  test "SlideTimer tick drives PhotoQueue.advance and ImageLoader delivers :image_loaded" do
    :sys.get_state(NervesPhotos.PhotoQueue)

    assert_receive {:slide_timer, :next_photo}, 300

    result = NervesPhotos.PhotoQueue.advance()
    assert {FakeImmich, asset_id, _config, %{date: %Date{}, location: location}} = result
    assert asset_id in ["asset-001", "asset-002"]
    assert is_binary(location)

    NervesPhotos.ImageLoader.load(result, self())
    assert_receive {:image_loaded, "photo:current"}, 500
  end

  test "PhotoQueue.queue_position tracks advances" do
    :sys.get_state(NervesPhotos.PhotoQueue)

    {_before_idx, total} = NervesPhotos.PhotoQueue.queue_position()
    assert total == 2

    NervesPhotos.PhotoQueue.advance()
    {idx, ^total} = NervesPhotos.PhotoQueue.queue_position()
    assert idx == 2
  end

  test "PhotoQueue reshuffles after queue exhaustion" do
    :sys.get_state(NervesPhotos.PhotoQueue)

    NervesPhotos.PhotoQueue.advance()
    NervesPhotos.PhotoQueue.advance()

    :sys.get_state(NervesPhotos.PhotoQueue)
    result = NervesPhotos.PhotoQueue.advance()
    assert {FakeImmich, id, _config, _meta} = result
    assert id in ["asset-001", "asset-002"]
  end

  test "ImageLoader reports :image_load_error on fetch failure" do
    defmodule FailSource do
      def fetch_image(_id, _config), do: {:error, :timeout}
    end

    :sys.get_state(NervesPhotos.PhotoQueue)
    asset = {FailSource, "bad-id", %{}, %{date: nil, location: nil}}

    NervesPhotos.ImageLoader.load(asset, self())
    assert_receive {:image_load_error, ^asset}, 500
  end

  test "WeatherFetcher delivers weather data" do
    assert {:ok, %{temp_f: temp, condition: condition}} =
             NervesPhotos.WeatherFetcher.current()

    assert is_number(temp)
    assert is_binary(condition)
  end
end
```

- [ ] **Step 3: Run full test suite**

```bash
mix test
```
Expected: all tests pass, no references to ImmichClient remaining.

- [ ] **Step 4: Commit**

```bash
git add test/nerves_photos/integration_test.exs
git rm lib/nerves_photos/immich_client.ex test/nerves_photos/immich_client_test.exs
git commit -m "feat: delete ImmichClient, rewrite integration test for PhotoQueue"
```

---

## Task 13: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/user-guide.md`

- [ ] **Step 1: Update README.md**

Find the configuration section of `README.md`. Remove the `IMMICH_URL`, `IMMICH_API_KEY`, `IMMICH_ALBUM_ID` env var entries and the "Add a new photo source" extension note. Replace with:

```markdown
## Configuration

Photo sources are configured at runtime via the settings API. No env vars required for photo sources.

### Add a photo source

```bash
# Immich album
curl -X POST http://nerves.local/settings/photo_sources \
  -H "Content-Type: application/json" \
  -d '{"type":"immich","url":"http://192.168.1.10:2283","api_key":"your-key","album_id":"your-album-uuid"}'

# Google Photos shared album
curl -X POST http://nerves.local/settings/photo_sources \
  -H "Content-Type: application/json" \
  -d '{"type":"google_photos","share_url":"https://photos.app.goo.gl/yoursharelink"}'
```

### List sources
```bash
curl http://nerves.local/settings/photo_sources
```

### Remove a source (by 0-based index)
```bash
curl -X DELETE http://nerves.local/settings/photo_sources/0
```

### Extending with a new source type

Implement the `NervesPhotos.PhotoSource` behaviour:
- `list_assets/1` — given the source config map, return `{:ok, [{id, %{date, location}}]}` or `{:error, reason}`
- `fetch_image/2` — given the source_id and config, return `{:ok, binary}` or `{:error, reason}`

Register the new type in `PhotoQueue.source_module/1` and add it to `@valid_source_types` in `SettingsRouter`.
```

- [ ] **Step 2: Update docs/user-guide.md**

Find the "Setup" or "Immich" section. Replace single-album instructions with multi-source instructions matching the API documented in Step 1 above. Document both Immich and Google Photos source types, including the Google Photos note about the HTML-parsing approach being a best-effort first iteration.

- [ ] **Step 3: Run tests one final time**

```bash
mix test
```
Expected: all tests green.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/user-guide.md docs/superpowers/specs/2026-05-06-multi-source-photos-design.md \
        docs/superpowers/plans/2026-05-07-multi-source-photos.md
git commit -m "docs: update README and user guide for multi-source photo configuration"
```

---

## Verification

After all tasks are complete:

1. **Unit tests:** `mix test` — all tests green
2. **Compile check:** `mix compile --warnings-as-errors` — zero warnings
3. **Credo:** `mix credo` — no issues
4. **On-device smoke test:** Deploy to a device, POST two Immich sources, verify both albums' photos appear shuffled together in the slideshow
5. **Google Photos smoke test:** POST a Google Photos share URL, verify photos load (or appropriate error is logged if the share page format has changed)

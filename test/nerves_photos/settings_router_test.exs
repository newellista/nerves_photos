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
      path = "/tmp/nerves_photos_test_sources_#{:erlang.unique_integer([:positive])}.json"
      File.rm(path)
      start_supervised!({NervesPhotos.SettingsStore, [path: path]})
      on_exit(fn -> File.rm(path) end)
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
      path = "/tmp/nerves_photos_test_post_#{:erlang.unique_integer([:positive])}.json"
      File.rm(path)
      start_supervised!({NervesPhotos.SettingsStore, [path: path]})
      on_exit(fn -> File.rm(path) end)
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
      File.rm(path)
      start_supervised!({NervesPhotos.SettingsStore, [path: path]})
      on_exit(fn -> File.rm(path) end)

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

  describe "GET /settings sidebar layout" do
    setup do
      path = "/tmp/nerves_photos_test_settings_ui_#{:erlang.unique_integer([:positive])}.json"
      File.rm(path)
      start_supervised!({NervesPhotos.SettingsStore, [path: path]})
      on_exit(fn -> File.rm(path) end)
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

    test "wifi section contains ssid field and status" do
      NervesPhotos.SettingsStore.put(:wifi_ssid, "MyNetwork")

      conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
      body = conn.resp_body
      assert body =~ ~s(name="wifi_ssid")
      assert body =~ "MyNetwork"
      assert body =~ ~s(name="wifi_psk")
      assert body =~ "Status:"
    end
  end

  describe "GET /settings photo sources section" do
    setup do
      path = "/tmp/nerves_photos_test_sources_ui_#{:erlang.unique_integer([:positive])}.json"
      File.rm(path)
      start_supervised!({NervesPhotos.SettingsStore, [path: path]})
      on_exit(fn -> File.rm(path) end)
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
      assert conn.resp_body =~ ~s[onclick="deleteSource(0)"]
    end

    test "add immich form contains required fields" do
      conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
      body = conn.resp_body
      assert body =~ ~s(id="add-immich-form")
      assert body =~ ~s(placeholder="http://192.168.1.10:2283")
      assert body =~ ~s(name="api_key")
      assert body =~ ~s(name="album_id")
    end

    test "add google photos form contains share_url field" do
      conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
      body = conn.resp_body
      assert body =~ ~s(id="add-google-form")
      assert body =~ ~s(name="share_url")
    end

    test "edit form for immich source pre-fills url and album_id but not api_key" do
      NervesPhotos.SettingsStore.put(:photo_sources, [
        %{type: "immich", url: "http://192.168.1.10:2283", api_key: "mykey", album_id: "abc-uuid"}
      ])

      conn = conn(:get, "/settings") |> NervesPhotos.SettingsRouter.call(@opts)
      body = conn.resp_body
      assert body =~ ~s(id="edit-form-0")
      assert body =~ "http://192.168.1.10:2283"
      assert body =~ "abc-uuid"
      refute body =~ ~s(value="mykey")
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
  end

  describe "PUT /settings/photo_sources/:index" do
    setup do
      path = "/tmp/nerves_photos_test_put_#{:erlang.unique_integer([:positive])}.json"
      File.rm(path)
      start_supervised!({NervesPhotos.SettingsStore, [path: path]})
      on_exit(fn -> File.rm(path) end)

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

    test "preserves existing api_key when not included in update body" do
      body = Jason.encode!(%{type: "immich", url: "http://new", album_id: "a2"})

      conn =
        conn(:put, "/settings/photo_sources/0", body)
        |> put_req_header("content-type", "application/json")
        |> NervesPhotos.SettingsRouter.call(@opts)

      assert conn.status == 200
      sources = NervesPhotos.SettingsStore.get(:photo_sources)
      assert hd(sources)[:api_key] == "k1"
    end
  end
end

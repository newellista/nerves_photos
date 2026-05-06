defmodule NervesPhotos.SettingsRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts NervesPhotos.SettingsRouter.init([])

  defmodule ImmichStub do
    use GenServer

    def start_link(state),
      do: GenServer.start_link(__MODULE__, state, name: NervesPhotos.ImmichClient)

    def init(state), do: {:ok, state}
    def handle_call(:current, _, state), do: {:reply, state.current, state}
    def handle_call(:connection_info, _, state), do: {:reply, state.connection_info, state}
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
          NervesPhotos.ImmichClient,
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
        {ImmichStub,
         %{
           current: {"asset123", %{date: ~D[2024-06-01], location: "Paris, France"}},
           connection_info: {"http://immich.local", "test-key"}
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
      stop_supervised!(ImmichStub)
      start_supervised!({ImmichStub, %{current: :loading, connection_info: {"", ""}}})

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

  describe "GET /current" do
    setup do
      start_supervised!(
        {NervesPhotos.SettingsStore, [path: "/tmp/nerves_photos_test_settings.json"]}
      )

      start_supervised!(
        {ImmichStub,
         %{
           current: {"asset123", %{date: ~D[2024-06-01], location: "Paris, France"}},
           connection_info: {"http://immich.local", "test-key"},
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
      stop_supervised!(ImmichStub)

      start_supervised!(
        {ImmichStub, %{current: :disconnected, connection_info: {"", ""}, queue_position: {0, 0}}}
      )

      conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.resp_body =~ "Reconnecting..."
      refute conn.resp_body =~ ~s(<img id="photo")
    end

    test "shows Loading message when loading" do
      stop_supervised!(ImmichStub)

      start_supervised!(
        {ImmichStub, %{current: :loading, connection_info: {"", ""}, queue_position: {0, 0}}}
      )

      conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.resp_body =~ "Loading..."
      refute conn.resp_body =~ ~s(<img id="photo")
    end

    test "shows no photos message when album is empty" do
      stop_supervised!(ImmichStub)

      start_supervised!(
        {ImmichStub, %{current: :empty, connection_info: {"", ""}, queue_position: {0, 0}}}
      )

      conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.resp_body =~ "No photos found in album"
      refute conn.resp_body =~ ~s(<img id="photo")
    end

    test "shows not configured message" do
      stop_supervised!(ImmichStub)

      start_supervised!(
        {ImmichStub,
         %{current: :not_configured, connection_info: {nil, nil}, queue_position: {0, 0}}}
      )

      conn = conn(:get, "/current") |> NervesPhotos.SettingsRouter.call(@opts)
      assert conn.resp_body =~ "Not configured"
      refute conn.resp_body =~ ~s(<img id="photo")
    end

    test "shows No weather data when weather is unavailable" do
      stop_supervised!(WeatherStub)
      start_supervised!({WeatherStub, %{current: :unavailable}})

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
end

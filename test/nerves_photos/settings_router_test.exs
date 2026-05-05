defmodule NervesPhotos.SettingsRouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts NervesPhotos.SettingsRouter.init([])

  defmodule ImmichStub do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: NervesPhotos.ImmichClient)
    def init(state), do: {:ok, state}
    def handle_call(:current, _, state), do: {:reply, state.current, state}
    def handle_call(:connection_info, _, state), do: {:reply, state.connection_info, state}
  end

  setup do
    for mod <- [NervesPhotos.ImmichClient, NervesPhotos.SettingsStore] do
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
end

defmodule NervesPhotos.AuthPlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias NervesPhotos.AuthPlug

  @session_opts Plug.Session.init(
                  store: :ets,
                  key: "_nerves_photos_session",
                  table: :session,
                  signing_salt: "nerves_photos_sess"
                )

  defp secret_key_base,
    do: Application.get_env(:nerves_photos, :secret_key_base)

  defp setup_conn(method, path) do
    conn(method, path)
    |> put_in([Access.key(:secret_key_base)], secret_key_base())
    |> Plug.Session.call(@session_opts)
    |> fetch_session()
  end

  setup do
    path =
      System.tmp_dir!()
      |> Path.join("nerves_photos_users_auth_#{:erlang.unique_integer([:positive])}.json")

    File.rm(path)
    start_supervised!({NervesPhotos.UserStore, path: path})
    :ok
  end

  test "redirects unauthenticated request for protected path to /login" do
    conn = setup_conn(:get, "/settings") |> AuthPlug.call([])
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/login"]
  end

  test "assigns current_user and passes through when session is set" do
    user = %{username: "alice", role: :admin}

    conn =
      setup_conn(:get, "/settings")
      |> put_session("current_user", user)
      |> AuthPlug.call([])

    assert conn.assigns.current_user == user
    refute conn.halted
  end

  test "passes through public path /login without session" do
    conn = setup_conn(:get, "/login") |> AuthPlug.call([])
    refute conn.halted
    refute conn.status == 302
  end

  test "passes through public path /current without session" do
    conn = setup_conn(:get, "/current") |> AuthPlug.call([])
    refute conn.halted
  end

  test "passes through public path /current/photo without session" do
    conn = setup_conn(:get, "/current/photo") |> AuthPlug.call([])
    refute conn.halted
  end

  test "AP bypass does not trigger when ConnectivityMonitor absent" do
    conn = setup_conn(:get, "/settings") |> AuthPlug.call([])
    assert conn.status == 302
  end
end

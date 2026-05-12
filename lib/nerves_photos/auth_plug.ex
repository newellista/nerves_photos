defmodule NervesPhotos.AuthPlug do
  @moduledoc false
  import Plug.Conn

  @public_paths ["/login", "/current", "/current/photo"]

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      ap_bootstrap?() ->
        assign(conn, :current_user, %{username: nil, role: :admin})

      conn.request_path in @public_paths ->
        conn

      true ->
        case get_session(conn, "current_user") do
          nil ->
            conn
            |> put_resp_header("location", "/login")
            |> send_resp(302, "")
            |> halt()

          user ->
            assign(conn, :current_user, user)
        end
    end
  end

  defp ap_bootstrap? do
    case Process.whereis(NervesPhotos.ConnectivityMonitor) do
      nil ->
        false

      pid ->
        mode =
          try do
            GenServer.call(pid, :mode, 2_000)
          catch
            :exit, _ -> nil
          end

        mode == :ap && NervesPhotos.UserStore.all() == []
    end
  end
end

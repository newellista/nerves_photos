defmodule NervesPhotos.ImmichClientTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.ImmichClient

  setup do
    test_pid = self()

    Req.Test.stub(ImmichClient, fn conn ->
      if String.contains?(conn.request_path, "/api/albums/") do
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
      else
        Req.Test.json(conn, %{})
      end
    end)

    # Allow any process started by this test to access the stub.
    # Using a lazy function so the allowance is registered before the GenServer starts.
    Req.Test.allow(ImmichClient, test_pid, fn -> GenServer.whereis(ImmichClient) end)

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

  test "current/0 returns :empty when album has no assets" do
    test_pid = self()

    Req.Test.stub(ImmichClientEmptyStub, fn conn ->
      Req.Test.json(conn, %{"assets" => []})
    end)

    # Register the allowance lazily using a unique atom name so the GenServer
    # process can look itself up before making the first HTTP request.
    Req.Test.allow(ImmichClientEmptyStub, test_pid, fn ->
      GenServer.whereis(ImmichClientEmpty)
    end)

    {:ok, _pid} =
      start_supervised(
        {ImmichClient,
         url: "http://immich.test",
         api_key: "test-key",
         album_id: "album-empty",
         name: ImmichClientEmpty,
         req_options: [plug: {Req.Test, ImmichClientEmptyStub}]},
        id: :empty_client
      )

    # Flush the mailbox so :fetch_album has been processed
    pid = GenServer.whereis(ImmichClientEmpty)
    :sys.get_state(pid)

    assert GenServer.call(pid, :current) == :empty
  end

  test "returns :not_configured when settings are nil and does not crash" do
    {:ok, pid} =
      start_supervised(
        {ImmichClient, url: nil, api_key: nil, album_id: nil, name: :unconfigured_client},
        id: :unconfigured_client
      )

    :sys.get_state(pid)
    assert GenServer.call(pid, :current) == :not_configured
    assert GenServer.call(pid, :advance) == :not_configured
    assert GenServer.call(pid, :queue_position) == {0, 0}
    assert Process.alive?(pid)
  end

  test "current/0 returns :disconnected when Immich returns HTTP 500" do
    test_pid = self()

    Req.Test.stub(ImmichClientErrorStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "Internal Server Error")
    end)

    # Register the allowance lazily using a unique atom name so the GenServer
    # process can look itself up before making the first HTTP request.
    Req.Test.allow(ImmichClientErrorStub, test_pid, fn ->
      GenServer.whereis(ImmichClientError)
    end)

    {:ok, _pid} =
      start_supervised(
        {ImmichClient,
         url: "http://immich.test",
         api_key: "test-key",
         album_id: "album-error",
         name: ImmichClientError,
         req_options: [plug: {Req.Test, ImmichClientErrorStub}, retry: false]},
        id: :error_client
      )

    # Flush the mailbox so :fetch_album has been processed
    pid = GenServer.whereis(ImmichClientError)
    :sys.get_state(pid)

    assert GenServer.call(pid, :current) == :disconnected
  end
end

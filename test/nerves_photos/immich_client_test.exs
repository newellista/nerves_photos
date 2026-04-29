defmodule NervesPhotos.ImmichClientTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.ImmichClient

  setup do
    test_pid = self()

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
end

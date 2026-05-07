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

      config =
        Map.put(@config, :req_options, plug: {Req.Test, ImmichSourceErrorTest}, retry: false)

      assert {:error, {:http, 500}} = Immich.list_assets(config)
    end
  end
end

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

      config =
        Map.put(@config, :req_options, plug: {Req.Test, GooglePhotosHttpErrorTest}, retry: false)

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

      config =
        Map.put(@config, :req_options,
          plug: {Req.Test, GooglePhotosFetchErrorTest},
          retry: false
        )

      assert {:error, {:http, 403}} =
               GooglePhotos.fetch_image("https://lh3.googleusercontent.com/pw/X", config)
    end
  end
end

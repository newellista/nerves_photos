defmodule NervesPhotos.ImageLoaderTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.ImageLoader

  @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

  setup do
    test_pid = self()

    Req.Test.stub(ImageLoader, fn conn ->
      if String.contains?(conn.request_path, "/thumbnail") do
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
        |> Plug.Conn.send_resp(200, @fake_jpeg)
      else
        Req.Test.json(conn, %{"error" => "not found"})
      end
    end)

    Req.Test.allow(ImageLoader, test_pid, fn -> GenServer.whereis(ImageLoader) end)

    {:ok, _pid} =
      start_supervised(
        {ImageLoader,
         connection_info_fn: fn -> {"http://immich.test", "test-key"} end,
         req_options: [plug: {Req.Test, ImageLoader}],
         put_fn: fn _key, _bytes -> :ok end}
      )

    :ok
  end

  test "load/2 sends {:image_loaded, key} to caller on success" do
    ImageLoader.load("asset-1", self())
    assert_receive {:image_loaded, "photo:current"}, 500
  end

  test "load/2 sends {:image_load_error, asset_id} on HTTP failure" do
    Req.Test.stub(ImageLoader, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    ImageLoader.load("bad-asset", self())
    assert_receive {:image_load_error, "bad-asset"}, 500
  end
end

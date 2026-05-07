defmodule NervesPhotos.ImageLoaderTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.ImageLoader

  @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

  defmodule GoodSource do
    def fetch_image("asset-1", _config), do: {:ok, <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>}
    def fetch_image(_, _), do: {:error, :not_found}
  end

  defmodule BadSource do
    def fetch_image(_id, _config), do: {:error, {:http, 404}}
  end

  setup do
    {:ok, _pid} =
      start_supervised({ImageLoader, put_fn: fn _key, _bytes -> :ok end})

    :ok
  end

  test "load/2 sends {:image_loaded, key} to caller on success" do
    asset = {GoodSource, "asset-1", %{}, %{date: nil, location: nil}}
    ImageLoader.load(asset, self())
    assert_receive {:image_loaded, "photo:current"}, 500
  end

  test "load/2 sends {:image_load_error, asset} on fetch failure" do
    asset = {BadSource, "bad-asset", %{}, %{date: nil, location: nil}}
    ImageLoader.load(asset, self())
    assert_receive {:image_load_error, ^asset}, 500
  end

  test "load/3 accepts a custom stream key" do
    asset = {GoodSource, "asset-1", %{}, %{date: nil, location: nil}}
    ImageLoader.load(asset, self(), "photo:custom")
    assert_receive {:image_loaded, "photo:custom"}, 500
  end
end

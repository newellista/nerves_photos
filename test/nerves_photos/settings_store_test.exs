defmodule NervesPhotos.SettingsStoreTest do
  use ExUnit.Case, async: false

  alias NervesPhotos.SettingsStore

  setup do
    path =
      System.tmp_dir!()
      |> Path.join("nerves_photos_test_#{:erlang.unique_integer([:positive])}.json")

    File.rm(path)

    {:ok, store} = SettingsStore.start_link(path: path, name: nil)

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
      File.rm(path)
    end)

    {:ok, path: path, store: store}
  end

  test "photo_sources defaults to empty list", %{store: store} do
    assert GenServer.call(store, {:get, :photo_sources}) == []
  end

  test "put/2 and get/1 round-trip photo_sources", %{store: store} do
    sources = [%{type: "immich", url: "http://srv:2283", api_key: "k", album_id: "a1"}]
    :ok = GenServer.call(store, {:put, :photo_sources, sources})
    assert GenServer.call(store, {:get, :photo_sources}) == sources
  end

  test "put/2 persists photo_sources to disk and reloads after restart", %{
    path: path,
    store: store
  } do
    sources = [%{type: "google_photos", share_url: "https://photos.app.goo.gl/abc"}]
    :ok = GenServer.call(store, {:put, :photo_sources, sources})

    GenServer.stop(store)

    {:ok, reloaded} = SettingsStore.start_link(path: path, name: nil)
    on_exit(fn -> if Process.alive?(reloaded), do: GenServer.stop(reloaded) end)

    assert GenServer.call(reloaded, {:get, :photo_sources}) == sources
  end

  test "put/2 returns error for unknown key", %{store: store} do
    assert {:error, :unknown_key} = GenServer.call(store, {:put, :immich_url, "http://x"})
  end

  test "put/2 and get/1 round-trip slide_interval_ms", %{store: store} do
    :ok = GenServer.call(store, {:put, :slide_interval_ms, 10_000})
    assert GenServer.call(store, {:get, :slide_interval_ms}) == 10_000
  end
end

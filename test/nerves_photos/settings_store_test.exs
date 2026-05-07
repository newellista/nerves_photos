defmodule NervesPhotos.SettingsStoreTest do
  use ExUnit.Case

  alias NervesPhotos.SettingsStore

  setup do
    path =
      System.tmp_dir!()
      |> Path.join("nerves_photos_test_#{:erlang.unique_integer([:positive])}.json")

    {:ok, _} = start_supervised({SettingsStore, path: path})
    {:ok, path: path}
  end

  test "photo_sources defaults to empty list" do
    assert SettingsStore.get(:photo_sources) == []
  end

  test "put/2 and get/1 round-trip photo_sources" do
    sources = [%{type: "immich", url: "http://srv:2283", api_key: "k", album_id: "a1"}]
    :ok = SettingsStore.put(:photo_sources, sources)
    assert SettingsStore.get(:photo_sources) == sources
  end

  test "put/2 persists photo_sources to disk and reloads after restart", %{path: path} do
    sources = [%{type: "google_photos", share_url: "https://photos.app.goo.gl/abc"}]
    :ok = SettingsStore.put(:photo_sources, sources)

    stop_supervised!(SettingsStore)
    {:ok, _} = start_supervised({SettingsStore, path: path})

    assert SettingsStore.get(:photo_sources) == sources
  end

  test "put/2 returns error for unknown key" do
    assert {:error, :unknown_key} = SettingsStore.put(:immich_url, "http://x")
  end

  test "put/2 and get/1 round-trip slide_interval_ms" do
    :ok = SettingsStore.put(:slide_interval_ms, 10_000)
    assert SettingsStore.get(:slide_interval_ms) == 10_000
  end
end

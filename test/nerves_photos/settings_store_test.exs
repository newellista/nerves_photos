defmodule NervesPhotos.SettingsStoreTest do
  use ExUnit.Case

  alias NervesPhotos.SettingsStore

  setup do
    path = System.tmp_dir!() |> Path.join("nerves_photos_test_#{:erlang.unique_integer([:positive])}.json")
    {:ok, _} = start_supervised({SettingsStore, path: path})
    {:ok, path: path}
  end

  test "get/1 returns compiled-in default when no file exists" do
    assert is_binary(SettingsStore.get(:immich_url)) or is_nil(SettingsStore.get(:immich_url))
  end

  test "put/2 and get/1 round-trip a value" do
    :ok = SettingsStore.put(:slide_interval_ms, 10_000)
    assert SettingsStore.get(:slide_interval_ms) == 10_000
  end

  test "put/2 persists to disk and reloads after restart", %{path: path} do
    :ok = SettingsStore.put(:immich_url, "http://new-server:2283")

    stop_supervised!(SettingsStore)
    {:ok, _} = start_supervised({SettingsStore, path: path})

    assert SettingsStore.get(:immich_url) == "http://new-server:2283"
  end
end

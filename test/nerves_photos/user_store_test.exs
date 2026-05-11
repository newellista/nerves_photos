defmodule NervesPhotos.UserStoreTest do
  use ExUnit.Case

  alias NervesPhotos.UserStore

  setup do
    path =
      System.tmp_dir!()
      |> Path.join("nerves_photos_users_test_#{:erlang.unique_integer([:positive])}.json")

    {:ok, _} = start_supervised({UserStore, path: path})
    {:ok, path: path}
  end

  test "all/0 defaults to empty list" do
    assert UserStore.all() == []
  end

  test "put/2 stores a user and get/1 retrieves it by username" do
    user = %{username: "alice", password_hash: "hash", role: "admin"}
    :ok = UserStore.put("alice", user)
    assert UserStore.get("alice") == user
  end

  test "get/1 returns nil for unknown username" do
    assert UserStore.get("nobody") == nil
  end

  test "put/2 overwrites existing user with same username" do
    user1 = %{username: "alice", password_hash: "hash1", role: "editor"}
    user2 = %{username: "alice", password_hash: "hash2", role: "admin"}
    :ok = UserStore.put("alice", user1)
    :ok = UserStore.put("alice", user2)
    assert UserStore.get("alice").role == "admin"
    assert length(UserStore.all()) == 1
  end

  test "delete/1 removes user by username" do
    user = %{username: "alice", password_hash: "hash", role: "admin"}
    :ok = UserStore.put("alice", user)
    :ok = UserStore.delete("alice")
    assert UserStore.get("alice") == nil
    assert UserStore.all() == []
  end

  test "persists to disk and reloads after restart", %{path: path} do
    user = %{username: "alice", password_hash: "hash", role: "admin"}
    :ok = UserStore.put("alice", user)

    stop_supervised!(UserStore)
    {:ok, _} = start_supervised({UserStore, path: path})

    assert UserStore.get("alice") == user
  end
end

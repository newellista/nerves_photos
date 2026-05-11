defmodule NervesPhotos.UserTest do
  use ExUnit.Case

  alias NervesPhotos.User

  test "new/3 returns ok map with hashed password for valid inputs" do
    assert {:ok, user} = User.new("alice", "password123", "admin")
    assert user.username == "alice"
    assert user.role == "admin"
    assert String.starts_with?(user.password_hash, "$2b$")
    refute user.password_hash == "password123"
  end

  test "new/3 returns error when username is blank" do
    assert {:error, _reason} = User.new("", "password123", "admin")
  end

  test "new/3 returns error when username contains invalid characters" do
    assert {:error, _reason} = User.new("alice'; DROP TABLE", "password123", "admin")
  end

  test "new/3 accepts usernames with letters, digits, underscores, dots, hyphens" do
    assert {:ok, _} = User.new("alice.b-ob_2", "password123", "admin")
  end

  test "new/3 returns error when password is fewer than 8 characters" do
    assert {:error, reason} = User.new("alice", "short", "admin")
    assert reason =~ "8"
  end

  test "new/3 returns error for unknown role" do
    assert {:error, _reason} = User.new("alice", "password123", "superuser")
  end

  test "new/3 accepts editor role" do
    assert {:ok, user} = User.new("bob", "password123", "editor")
    assert user.role == "editor"
  end

  test "verify_password/2 returns true for correct password" do
    {:ok, user} = User.new("alice", "password123", "admin")
    assert User.verify_password(user, "password123")
  end

  test "verify_password/2 returns false for wrong password" do
    {:ok, user} = User.new("alice", "password123", "admin")
    refute User.verify_password(user, "wrongpassword")
  end
end

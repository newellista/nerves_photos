defmodule NervesPhotos.PolicyTest do
  use ExUnit.Case

  alias NervesPhotos.Policy

  @editor %{username: "ed", role: :editor}
  @admin %{username: "ad", role: :admin}

  test "editor can view_settings" do
    assert :ok = Bodyguard.permit(Policy, :view_settings, @editor)
  end

  test "editor can edit_settings" do
    assert :ok = Bodyguard.permit(Policy, :edit_settings, @editor)
  end

  test "editor can manage_sources (add/edit)" do
    assert :ok = Bodyguard.permit(Policy, :manage_sources, @editor)
  end

  test "editor cannot delete_source" do
    assert {:error, _} = Bodyguard.permit(Policy, :delete_source, @editor)
  end

  test "editor cannot manage_users" do
    assert {:error, _} = Bodyguard.permit(Policy, :manage_users, @editor)
  end

  test "admin can delete_source" do
    assert :ok = Bodyguard.permit(Policy, :delete_source, @admin)
  end

  test "admin can manage_users" do
    assert :ok = Bodyguard.permit(Policy, :manage_users, @admin)
  end

  test "admin can view_settings" do
    assert :ok = Bodyguard.permit(Policy, :view_settings, @admin)
  end
end

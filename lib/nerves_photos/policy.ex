defmodule NervesPhotos.Policy do
  @moduledoc false
  @behaviour Bodyguard.Policy

  def authorize(:view_settings, _user, _resource), do: :ok
  def authorize(:edit_settings, _user, _resource), do: :ok
  def authorize(:manage_sources, _user, _resource), do: :ok
  def authorize(:delete_source, %{role: :admin}, _resource), do: :ok
  def authorize(:manage_users, %{role: :admin}, _resource), do: :ok
  def authorize(_action, _user, _resource), do: {:error, :unauthorized}
end

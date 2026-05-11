defmodule NervesPhotos.User do
  @moduledoc false

  @valid_roles ~w(admin editor)

  def new(username, password, role) do
    with :ok <- validate_username(username),
         :ok <- validate_password(password),
         :ok <- validate_role(role) do
      {:ok,
       %{
         username: username,
         password_hash: Bcrypt.hash_pwd_salt(password),
         role: role
       }}
    end
  end

  def verify_password(%{password_hash: hash}, password) do
    Bcrypt.verify_pass(password, hash)
  end

  @username_pattern ~r/\A[a-zA-Z0-9_.\-]+\z/

  defp validate_username(u) when is_binary(u) and u != "" do
    if Regex.match?(@username_pattern, u),
      do: :ok,
      else: {:error, "username may only contain letters, digits, underscores, dots, and hyphens"}
  end

  defp validate_username(_), do: {:error, "username cannot be blank"}

  defp validate_password(p) when is_binary(p) and byte_size(p) >= 8, do: :ok
  defp validate_password(_), do: {:error, "password must be at least 8 characters"}

  defp validate_role(r) when r in @valid_roles, do: :ok
  defp validate_role(_), do: {:error, "role must be admin or editor"}
end

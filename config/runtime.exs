import Config

if config_env() == :prod do
  data_dir = System.get_env("NERVES_PHOTOS_DATA_DIR", "/data/nerves_photos")
  secret_key_path = Path.join(data_dir, "secret_key_base")

  secret_key_base =
    case File.read(secret_key_path) do
      {:ok, key} ->
        String.trim(key)

      {:error, _} ->
        key = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
        File.mkdir_p!(Path.dirname(secret_key_path))
        File.write!(secret_key_path, key)
        File.chmod!(secret_key_path, 0o600)
        key
    end

  config :nerves_photos, secret_key_base: secret_key_base
end

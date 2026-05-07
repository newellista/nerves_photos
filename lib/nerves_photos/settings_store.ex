defmodule NervesPhotos.SettingsStore do
  @moduledoc false
  use GenServer

  @keys [
    :photo_sources,
    :slide_interval_ms,
    :wifi_ssid,
    :wifi_psk,
    :weather_zip
  ]
  @default_path "/data/nerves_photos/settings.json"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})
  def all, do: GenServer.call(__MODULE__, :all)

  @impl true
  def init(opts) do
    path = opts[:path] || Application.get_env(:nerves_photos, :settings_path, @default_path)
    settings = load(path)
    {:ok, %{path: path, settings: settings}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.settings, key), state}
  end

  def handle_call({:put, key, value}, _from, state) when key in @keys do
    settings = Map.put(state.settings, key, value)

    case persist(state.path, settings) do
      :ok -> {:reply, :ok, %{state | settings: settings}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put, _key, _value}, _from, state) do
    {:reply, {:error, :unknown_key}, state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.settings, state}
  end

  defp load(path) do
    defaults = %{
      photo_sources: Application.get_env(:nerves_photos, :photo_sources, []),
      slide_interval_ms: Application.get_env(:nerves_photos, :slide_interval_ms, 30_000),
      wifi_ssid: nil,
      wifi_psk: nil,
      weather_zip: nil
    }

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json, keys: :atoms) do
          {:ok, saved} -> Map.merge(defaults, Map.take(saved, @keys))
          {:error, _} -> defaults
        end

      {:error, _} ->
        defaults
    end
  end

  defp persist(path, settings) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(settings))
    end
  end
end

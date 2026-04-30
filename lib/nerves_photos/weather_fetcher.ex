defmodule NervesPhotos.WeatherFetcher do
  use GenServer
  require Logger

  @poll_interval 15 * 60 * 1_000

  @wmo_codes %{
    0 => "Clear Sky",
    1 => "Mainly Clear",
    2 => "Partly Cloudy",
    3 => "Overcast",
    45 => "Fog",
    48 => "Fog",
    51 => "Light Drizzle",
    53 => "Drizzle",
    55 => "Heavy Drizzle",
    61 => "Light Rain",
    63 => "Rain",
    65 => "Heavy Rain",
    71 => "Light Snow",
    73 => "Snow",
    75 => "Heavy Snow",
    80 => "Rain Showers",
    81 => "Rain Showers",
    82 => "Heavy Showers",
    95 => "Thunderstorm",
    99 => "Thunderstorm"
  }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(opts) do
    send(self(), :fetch_weather)

    zip_fn =
      opts[:zip_fn] ||
        fn ->
          if Process.whereis(NervesPhotos.SettingsStore),
            do: NervesPhotos.SettingsStore.get(:weather_zip),
            else: nil
        end

    {:ok, %{weather: :unavailable, req_options: opts[:req_options] || [], zip_fn: zip_fn}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.weather, state}
  end

  @impl true
  def handle_info(:fetch_weather, state) do
    zip = state.zip_fn.()

    weather =
      with {:ok, coords} <- resolve_location(zip, state.req_options),
           {:ok, data} <- fetch_weather(coords, state.req_options) do
        {:ok, data}
      else
        err ->
          Logger.warning("WeatherFetcher: #{inspect(err)}")
          :unavailable
      end

    Process.send_after(self(), :fetch_weather, @poll_interval)
    {:noreply, %{state | weather: weather}}
  end

  defp resolve_location(zip, req_options) when is_binary(zip) and zip != "" do
    geolocate_by_zip(zip, req_options)
  end

  defp resolve_location(_zip, req_options) do
    geolocate_by_ip(req_options)
  end

  defp geolocate_by_zip(zip, req_options) do
    req = Req.new([base_url: "https://geocoding-api.open-meteo.com"] ++ req_options)

    case Req.get(req, url: "/v1/search", params: [name: zip, count: 1, language: "en", format: "json"]) do
      {:ok, %{status: 200, body: %{"results" => [%{"latitude" => lat, "longitude" => lon} | _]}}} ->
        {:ok, {lat, lon}}

      {:ok, %{status: 200}} ->
        {:error, {:geo_zip, :not_found}}

      {:ok, resp} ->
        {:error, {:geo_zip, resp.status}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp geolocate_by_ip(req_options) do
    req = Req.new([base_url: "http://ip-api.com"] ++ req_options)

    case Req.get(req, url: "/json") do
      {:ok, %{status: 200, body: %{"lat" => lat, "lon" => lon}}} -> {:ok, {lat, lon}}
      {:ok, resp} -> {:error, {:geo, resp.status}}
      {:error, e} -> {:error, e}
    end
  end

  defp fetch_weather({lat, lon}, req_options) do
    req = Req.new([base_url: "https://api.open-meteo.com"] ++ req_options)

    params = [
      latitude: lat,
      longitude: lon,
      current: "temperature_2m,weathercode",
      temperature_unit: "fahrenheit"
    ]

    case Req.get(req, url: "/v1/forecast", params: params) do
      {:ok, %{status: 200, body: %{"current" => current}}} ->
        code = current["weathercode"] || 0

        {:ok,
         %{
           temp_f: current["temperature_2m"],
           condition: Map.get(@wmo_codes, code, "Unknown"),
           icon_code: code
         }}

      {:ok, resp} ->
        {:error, {:weather, resp.status}}

      {:error, e} ->
        {:error, e}
    end
  end
end

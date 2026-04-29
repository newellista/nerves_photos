defmodule NervesPhotos.WeatherFetcherTest do
  use ExUnit.Case, async: true

  alias NervesPhotos.WeatherFetcher

  setup do
    test_pid = self()

    Req.Test.stub(WeatherFetcher, fn conn ->
      cond do
        String.contains?(conn.host, "ip-api") ->
          Req.Test.json(conn, %{"lat" => 37.7, "lon" => -122.4})

        String.contains?(conn.host, "open-meteo") ->
          Req.Test.json(conn, %{
            "current" => %{
              "temperature_2m" => 68.0,
              "weathercode" => 1
            }
          })

        true ->
          Req.Test.json(conn, %{})
      end
    end)

    # Allow any process started by this test to access the stub.
    # Using a lazy function so the allowance is registered before the GenServer starts.
    Req.Test.allow(WeatherFetcher, test_pid, fn -> GenServer.whereis(WeatherFetcher) end)

    {:ok, _pid} =
      start_supervised(
        {WeatherFetcher, req_options: [plug: {Req.Test, WeatherFetcher}]}
      )

    :ok
  end

  test "current/0 returns ok tuple with weather data" do
    # Allow async init to complete
    Process.sleep(50)
    assert {:ok, %{temp_f: temp, condition: condition, icon_code: code}} = WeatherFetcher.current()
    assert is_float(temp) or is_integer(temp)
    assert is_binary(condition)
    assert is_integer(code)
  end

  test "current/0 returns :unavailable when fetch fails" do
    # Start an anonymous GenServer with no stub access - fetch will fail gracefully
    {:ok, pid} =
      GenServer.start(WeatherFetcher, req_options: [plug: {Req.Test, WeatherFetcher}])
    # Use :sys.get_state as synchronization barrier to wait for :fetch_weather to complete
    :sys.get_state(pid)
    # Weather remains :unavailable because the HTTP call failed (no stub allowed)
    assert GenServer.call(pid, :current) == :unavailable
    GenServer.stop(pid)
  end
end

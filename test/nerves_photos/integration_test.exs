defmodule NervesPhotos.IntegrationTest do
  use ExUnit.Case

  # Registered names — cannot run async
  @fake_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>

  setup do
    test_pid = self()

    Req.Test.stub(NervesPhotos.ImmichClient, fn conn ->
      if String.contains?(conn.request_path, "/api/albums") do
        Req.Test.json(conn, %{
          "assets" => [
            %{
              "id" => "asset-001",
              "fileCreatedAt" => "2023-06-12T10:00:00Z",
              "exifInfo" => %{"city" => "Yosemite", "country" => "USA"}
            },
            %{
              "id" => "asset-002",
              "fileCreatedAt" => "2024-01-01T00:00:00Z",
              "exifInfo" => %{"city" => "Paris", "country" => "France"}
            }
          ]
        })
      else
        Req.Test.json(conn, %{})
      end
    end)

    Req.Test.stub(NervesPhotos.ImageLoader, fn conn ->
      if String.contains?(conn.request_path, "/thumbnail") do
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
        |> Plug.Conn.send_resp(200, @fake_jpeg)
      else
        Req.Test.json(conn, %{})
      end
    end)

    Req.Test.stub(NervesPhotos.WeatherFetcher, fn conn ->
      cond do
        String.contains?(conn.host, "ip-api") ->
          Req.Test.json(conn, %{"lat" => 37.7, "lon" => -122.4})

        String.contains?(conn.host, "open-meteo") ->
          Req.Test.json(conn, %{
            "current" => %{"temperature_2m" => 72.0, "weathercode" => 2}
          })

        true ->
          Req.Test.json(conn, %{})
      end
    end)

    Req.Test.allow(NervesPhotos.ImmichClient, test_pid, fn ->
      GenServer.whereis(NervesPhotos.ImmichClient)
    end)

    Req.Test.allow(NervesPhotos.ImageLoader, test_pid, fn ->
      GenServer.whereis(NervesPhotos.ImageLoader)
    end)

    Req.Test.allow(NervesPhotos.WeatherFetcher, test_pid, fn ->
      GenServer.whereis(NervesPhotos.WeatherFetcher)
    end)

    start_supervised!(NervesPhotos.SettingsStore)

    start_supervised!(
      {NervesPhotos.ImmichClient,
       req_options: [plug: {Req.Test, NervesPhotos.ImmichClient}]}
    )

    start_supervised!(
      {NervesPhotos.WeatherFetcher,
       req_options: [plug: {Req.Test, NervesPhotos.WeatherFetcher}]}
    )

    start_supervised!(
      {NervesPhotos.ImageLoader,
       url: "http://immich.test",
       api_key: "test-key",
       req_options: [plug: {Req.Test, NervesPhotos.ImageLoader}],
       put_fn: fn _key, _bytes -> :ok end}
    )

    start_supervised!(
      {NervesPhotos.SlideTimer, interval_ms: 50, target: test_pid}
    )

    :ok
  end

  test "SlideTimer tick drives ImmichClient.advance and ImageLoader delivers :image_loaded" do
    # Wait for ImmichClient to finish loading album from Immich
    :sys.get_state(NervesPhotos.ImmichClient)

    # SlideTimer fires → test process receives the tick
    assert_receive {:slide_timer, :next_photo}, 300

    # Simulate what Scene.Main does: advance queue and kick off image load
    result = NervesPhotos.ImmichClient.advance()
    assert {asset_id, %{date: date, location: location}} = result
    assert asset_id in ["asset-001", "asset-002"]
    assert %Date{} = date
    assert is_binary(location)

    NervesPhotos.ImageLoader.load(asset_id, self())
    assert_receive {:image_loaded, "photo:current"}, 500
  end

  test "WeatherFetcher delivers weather data alongside photo cycle" do
    :sys.get_state(NervesPhotos.WeatherFetcher)
    Process.sleep(50)
    assert {:ok, %{temp_f: temp, condition: condition, icon_code: code}} =
             NervesPhotos.WeatherFetcher.current()
    assert is_number(temp)
    assert is_binary(condition)
    assert is_integer(code)
  end

  test "ImmichClient queue_position tracks advances" do
    :sys.get_state(NervesPhotos.ImmichClient)

    {_before_idx, total} = NervesPhotos.ImmichClient.queue_position()
    assert total == 2

    NervesPhotos.ImmichClient.advance()
    {idx, ^total} = NervesPhotos.ImmichClient.queue_position()
    assert idx == 2
  end

  test "ImmichClient reshuffles and continues after queue exhaustion" do
    :sys.get_state(NervesPhotos.ImmichClient)

    # Drain the queue (2 photos)
    {id1, _} = NervesPhotos.ImmichClient.advance()
    {id2, _} = NervesPhotos.ImmichClient.advance()
    assert id1 in ["asset-001", "asset-002"]
    assert id2 in ["asset-001", "asset-002"]

    # Queue exhausted — next advance triggers reshuffle
    # ImmichClient re-fetches album; block until it's done
    :sys.get_state(NervesPhotos.ImmichClient)
    {id3, _} = NervesPhotos.ImmichClient.advance()
    assert id3 in ["asset-001", "asset-002"]
  end

  test "ImageLoader reports :image_load_error on HTTP failure" do
    :sys.get_state(NervesPhotos.ImmichClient)

    Req.Test.stub(NervesPhotos.ImageLoader, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    NervesPhotos.ImageLoader.load("missing-asset", self())
    assert_receive {:image_load_error, "missing-asset"}, 500
  end
end

defmodule NervesPhotos.IntegrationTest do
  use ExUnit.Case

  defmodule FakeImmich do
    def list_assets(_config) do
      {:ok,
       [
         {"asset-001", %{date: ~D[2023-06-12], location: "Yosemite, USA"}},
         {"asset-002", %{date: ~D[2024-01-01], location: "Paris, France"}}
       ]}
    end

    def fetch_image(_id, _config), do: {:ok, <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0>>}
  end

  defmodule FakeWeather do
    use GenServer

    def start_link(state),
      do: GenServer.start_link(__MODULE__, state, name: NervesPhotos.WeatherFetcher)

    def init(state), do: {:ok, state}
    def handle_call(:current, _, state), do: {:reply, state, state}
  end

  setup do
    start_supervised!(NervesPhotos.SettingsStore)

    start_supervised!(
      {NervesPhotos.PhotoQueue,
       sources: [%{type: "stub"}], source_module_fn: fn _ -> FakeImmich end}
    )

    start_supervised!({FakeWeather, {:ok, %{temp_f: 72.0, condition: "Sunny", icon_code: 2}}})

    start_supervised!({NervesPhotos.ImageLoader, put_fn: fn _key, _bytes -> :ok end})

    start_supervised!({NervesPhotos.SlideTimer, interval_ms: 50, target: self()})

    :ok
  end

  test "SlideTimer tick drives PhotoQueue.advance and ImageLoader delivers :image_loaded" do
    :sys.get_state(NervesPhotos.PhotoQueue)

    assert_receive {:slide_timer, :next_photo}, 300

    result = NervesPhotos.PhotoQueue.advance()
    assert {FakeImmich, asset_id, _config, %{date: %Date{}, location: location}} = result
    assert asset_id in ["asset-001", "asset-002"]
    assert is_binary(location)

    NervesPhotos.ImageLoader.load(result, self())
    assert_receive {:image_loaded, "photo:current"}, 500
  end

  test "PhotoQueue.queue_position tracks advances" do
    :sys.get_state(NervesPhotos.PhotoQueue)

    {_before_idx, total} = NervesPhotos.PhotoQueue.queue_position()
    assert total == 2

    NervesPhotos.PhotoQueue.advance()
    {idx, ^total} = NervesPhotos.PhotoQueue.queue_position()
    assert idx == 2
  end

  test "PhotoQueue reshuffles after queue exhaustion" do
    :sys.get_state(NervesPhotos.PhotoQueue)

    NervesPhotos.PhotoQueue.advance()
    NervesPhotos.PhotoQueue.advance()

    :sys.get_state(NervesPhotos.PhotoQueue)
    result = NervesPhotos.PhotoQueue.advance()
    assert {FakeImmich, id, _config, _meta} = result
    assert id in ["asset-001", "asset-002"]
  end

  test "ImageLoader reports :image_load_error on fetch failure" do
    defmodule FailSource do
      def fetch_image(_id, _config), do: {:error, :timeout}
    end

    :sys.get_state(NervesPhotos.PhotoQueue)
    asset = {FailSource, "bad-id", %{}, %{date: nil, location: nil}}

    NervesPhotos.ImageLoader.load(asset, self())
    assert_receive {:image_load_error, ^asset}, 500
  end

  test "WeatherFetcher delivers weather data" do
    assert {:ok, %{temp_f: temp, condition: condition}} =
             NervesPhotos.WeatherFetcher.current()

    assert is_number(temp)
    assert is_binary(condition)
  end
end

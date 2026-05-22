defmodule NervesPhotos.CairoPortTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias NervesPhotos.CairoPort

  # Returns a {fake_pid, send_fn} pair for injection via open_port_fn.
  # fake_pid acts as the port identity for handle_info pattern matching.
  # send_fn is called from within the GenServer process, so self() inside it
  # is the GenServer pid — responses are sent back there.
  defp make_port(responses) do
    fake_pid = spawn(fn -> :ok end)
    responses_ref = :ets.new(:responses, [:ordered_set, :public])

    Enum.with_index(responses, fn response, i ->
      :ets.insert(responses_ref, {i, response})
    end)

    counter_ref = :counters.new(1, [])

    send_fn = fn _payload ->
      server = self()
      i = :counters.get(counter_ref, 1)
      :counters.add(counter_ref, 1, 1)

      case :ets.lookup(responses_ref, i) do
        [{^i, response}] -> send(server, {fake_pid, {:data, response}})
        [] -> :no_response
      end
    end

    {fake_pid, send_fn}
  end

  # Capturing port: records the payload sent and never responds (for encoding tests).
  defp capturing_port(test_pid) do
    fake_pid = spawn(fn -> :ok end)
    send_fn = fn payload -> send(test_pid, {:captured, payload}) end
    {fake_pid, send_fn}
  end

  test "init_display sends correct binary and returns :ok" do
    pid =
      start_supervised!({NervesPhotos.CairoPort, [open_port_fn: fn -> make_port([<<0xA0>>]) end]})

    assert :ok == CairoPort.init_display(pid, width: 1920, height: 1080, display_mode: :auto)
  end

  test "load_image sends correct binary and returns {:ok, {w, h}}" do
    response = <<0xA2, 0, 1920::big-16, 1080::big-16>>

    pid =
      start_supervised!({NervesPhotos.CairoPort, [open_port_fn: fn -> make_port([response]) end]})

    assert {:ok, {1920, 1080}} == CairoPort.load_image(pid, 0, <<0xFF, 0xD8>>)
  end

  test "free_slot sends correct binary and returns :ok" do
    pid =
      start_supervised!({NervesPhotos.CairoPort, [open_port_fn: fn -> make_port([<<0xA0>>]) end]})

    assert :ok == CairoPort.free_slot(pid, 1)
  end

  test "render_frame with metadata overlay returns :ok" do
    pid =
      start_supervised!({NervesPhotos.CairoPort, [open_port_fn: fn -> make_port([<<0xA0>>]) end]})

    params = %{
      transition_type: :fade_to_black,
      t: 0.5,
      crop_mode: :letterbox,
      overlays: %{date: "May 22, 2026", location: "Portland, OR"}
    }

    assert :ok == CairoPort.render_frame(pid, params)
  end

  test "get_dimensions returns {:ok, {w, h}}" do
    response = <<0xA3, 1920::big-16, 1080::big-16>>

    pid =
      start_supervised!({NervesPhotos.CairoPort, [open_port_fn: fn -> make_port([response]) end]})

    assert {:ok, {1920, 1080}} == CairoPort.get_dimensions(pid)
  end

  test "ping returns :pong" do
    pid =
      start_supervised!({NervesPhotos.CairoPort, [open_port_fn: fn -> make_port([<<0xA4>>]) end]})

    assert :pong == CairoPort.ping(pid)
  end

  test "error response returns {:error, message}" do
    msg = "decode failed"
    response = <<0xA1, 0x03, byte_size(msg)::8, msg::binary>>

    pid =
      start_supervised!({NervesPhotos.CairoPort, [open_port_fn: fn -> make_port([response]) end]})

    assert {:error, "decode failed"} == CairoPort.load_image(pid, 0, <<0x00>>)
  end

  test "CMD_INIT binary encoding is correct" do
    test_pid = self()

    pid =
      start_supervised!(
        {NervesPhotos.CairoPort, [open_port_fn: fn -> capturing_port(test_pid) end]}
      )

    Task.start(fn ->
      CairoPort.init_display(pid, width: 1920, height: 1080, display_mode: :fbdev)
    end)

    assert_receive {:captured, data}, 500
    assert <<0x01, 1920::big-16, 1080::big-16, 1>> == data
  end

  test "CMD_RENDER_FRAME binary encoding with weather overlay" do
    test_pid = self()

    pid =
      start_supervised!(
        {NervesPhotos.CairoPort, [open_port_fn: fn -> capturing_port(test_pid) end]}
      )

    params = %{
      transition_type: :none,
      t: 0.0,
      crop_mode: :center_crop,
      overlays: %{temp: "72°F", condition: "Sunny"}
    }

    Task.start(fn -> CairoPort.render_frame(pid, params) end)
    assert_receive {:captured, data}, 500

    <<cmd, transition, _t::32, crop, flags, rest::binary>> = data
    assert cmd == 0x04
    assert transition == 0
    assert crop == 1
    assert (flags &&& 0x02) != 0
    assert (flags &&& 0x01) == 0

    <<len, _temp_str::binary-size(len), _rest::binary>> = rest
    assert len == byte_size("72°F")
  end

  test "CMD_RENDER_FRAME encodes all overlay flags correctly" do
    test_pid = self()

    pid =
      start_supervised!(
        {NervesPhotos.CairoPort, [open_port_fn: fn -> capturing_port(test_pid) end]}
      )

    params = %{
      transition_type: :cross_dissolve,
      t: 1.0,
      crop_mode: :letterbox,
      overlays: %{
        date: "May 22",
        location: "Portland",
        temp: "72°F",
        condition: "Sunny",
        debug: "slot=0",
        show_disconnected: true,
        show_empty_album: true
      }
    }

    Task.start(fn -> CairoPort.render_frame(pid, params) end)
    assert_receive {:captured, data}, 500

    <<0x04, transition, _t::32, crop, flags, _rest::binary>> = data
    assert transition == 2
    assert crop == 0
    assert (flags &&& 0x01) != 0
    assert (flags &&& 0x02) != 0
    assert (flags &&& 0x04) != 0
    assert (flags &&& 0x08) != 0
    assert (flags &&& 0x10) != 0
  end

  test "CMD_FREE_SLOT binary encoding is correct" do
    test_pid = self()

    pid =
      start_supervised!(
        {NervesPhotos.CairoPort, [open_port_fn: fn -> capturing_port(test_pid) end]}
      )

    Task.start(fn -> CairoPort.free_slot(pid, 1) end)
    assert_receive {:captured, data}, 500
    assert <<0x03, 1>> == data
  end

  test "CMD_PING binary encoding is correct" do
    test_pid = self()

    pid =
      start_supervised!(
        {NervesPhotos.CairoPort, [open_port_fn: fn -> capturing_port(test_pid) end]}
      )

    Task.start(fn -> CairoPort.ping(pid) end)
    assert_receive {:captured, data}, 500
    assert <<0x06>> == data
  end

  test "CMD_GET_DIMENSIONS binary encoding is correct" do
    test_pid = self()

    pid =
      start_supervised!(
        {NervesPhotos.CairoPort, [open_port_fn: fn -> capturing_port(test_pid) end]}
      )

    Task.start(fn -> CairoPort.get_dimensions(pid) end)
    assert_receive {:captured, data}, 500
    assert <<0x05>> == data
  end
end

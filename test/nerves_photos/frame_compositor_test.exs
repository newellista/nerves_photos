defmodule NervesPhotos.FrameCompositorTest do
  use ExUnit.Case, async: false

  alias NervesPhotos.FrameCompositor

  defmodule MockCairoPort do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, []}

    @impl true
    def handle_call({:init_display, _opts}, _from, calls) do
      {:reply, :ok, [:init_display | calls]}
    end

    def handle_call({:load_image, slot, _bytes}, _from, calls) do
      {:reply, {:ok, {1920, 1080}}, [{:load_image, slot} | calls]}
    end

    def handle_call({:free_slot, slot}, _from, calls) do
      {:reply, :ok, [{:free_slot, slot} | calls]}
    end

    def handle_call({:render_frame, _params}, _from, calls) do
      {:reply, :ok, [:render_frame | calls]}
    end

    def handle_call(:get_dimensions, _from, calls) do
      {:reply, {:ok, {1920, 1080}}, [:get_dimensions | calls]}
    end

    def handle_call(:calls, _from, calls) do
      {:reply, Enum.reverse(calls), calls}
    end
  end

  defmodule StubSource do
    def fetch_image(_id, _config), do: {:ok, <<0xFF, 0xD8>>}
  end

  defmodule ErrorSource do
    def fetch_image(_id, _config), do: {:error, :fetch_failed}
  end

  defp make_port(test_ctx) do
    start_supervised!(MockCairoPort, id: :"port_#{test_ctx}")
  end

  defp make_compositor(port, opts \\ []) do
    defaults = [
      port_pid: port,
      name: :"compositor_#{:erlang.unique_integer([:positive])}",
      advance_fn: fn -> :loading end,
      queue_position_fn: fn -> {0, 0} end,
      weather_fn: fn -> :unavailable end
    ]

    start_supervised!({FrameCompositor, Keyword.merge(defaults, opts)})
  end

  defp make_asset(module \\ StubSource),
    do: {module, "test-id", %{}, %{date: nil, location: nil}}

  test "init calls CairoPort.init_display" do
    port = make_port(:init_test)
    _compositor = make_compositor(port)
    assert :init_display in MockCairoPort.calls(port)
  end

  test "phase starts as idle" do
    port = make_port(:idle_test)

    compositor =
      make_compositor(port, advance_fn: fn -> make_asset() end)

    state = :sys.get_state(compositor)
    assert state.phase == :idle
  end

  test "{:slide_timer, :next_photo} when idle triggers image load" do
    port = make_port(:load_test)
    test_pid = self()

    compositor =
      make_compositor(port,
        advance_fn: fn ->
          send(test_pid, :advance_called)
          make_asset()
        end
      )

    send(compositor, {:slide_timer, :next_photo})
    assert_receive :advance_called, 500

    # Wait for the async load task to complete and compositor to process it
    Process.sleep(200)

    port_calls = MockCairoPort.calls(port)
    assert Enum.any?(port_calls, &match?({:load_image, _}, &1))
  end

  test "{:slide_timer, :next_photo} when idle moves phase to loading" do
    port = make_port(:loading_phase_test)

    compositor =
      make_compositor(port,
        advance_fn: fn ->
          Process.sleep(100)
          make_asset()
        end
      )

    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(10)
    state = :sys.get_state(compositor)
    assert state.phase == :loading
  end

  test "{:slide_timer, :next_photo} when not idle is discarded" do
    port = make_port(:discard_test)
    test_pid = self()
    call_count = :counters.new(1, [])

    compositor =
      make_compositor(port,
        advance_fn: fn ->
          :counters.add(call_count, 1, 1)
          send(test_pid, :advance_called)
          Process.sleep(200)
          make_asset()
        end
      )

    send(compositor, {:slide_timer, :next_photo})
    assert_receive :advance_called, 500
    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(50)

    assert :counters.get(call_count, 1) == 1
  end

  test "{:image_loaded, slot} triggers transition rendering" do
    port = make_port(:transition_test)

    compositor =
      make_compositor(port,
        advance_fn: fn -> make_asset() end
      )

    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(300)

    port_calls = MockCairoPort.calls(port)
    assert :render_frame in port_calls
  end

  test "transition completes: frees old slot and returns to idle" do
    port = make_port(:complete_test)

    compositor =
      make_compositor(port,
        advance_fn: fn -> make_asset() end
      )

    send(compositor, {:slide_timer, :next_photo})

    # Load + 20 steps * 16ms = ~320ms + buffer for task scheduling
    Process.sleep(800)

    state = :sys.get_state(compositor)
    assert state.phase == :idle

    port_calls = MockCairoPort.calls(port)
    assert Enum.any?(port_calls, &match?({:free_slot, _}, &1))
  end

  test "transition swaps slots on completion" do
    port = make_port(:slot_swap_test)

    compositor =
      make_compositor(port,
        advance_fn: fn -> make_asset() end
      )

    initial_state = :sys.get_state(compositor)
    initial_current = initial_state.current_slot
    initial_next = initial_state.next_slot

    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(800)

    final_state = :sys.get_state(compositor)
    assert final_state.current_slot == initial_next
    assert final_state.next_slot == initial_current
  end

  test "{:image_load_error} frees slot, resets to idle, and retries" do
    port = make_port(:error_test)
    test_pid = self()
    call_count = :counters.new(1, [])

    compositor =
      make_compositor(port,
        advance_fn: fn ->
          n = :counters.get(call_count, 1)
          :counters.add(call_count, 1, 1)
          send(test_pid, {:advance_called, n})
          make_asset(ErrorSource)
        end
      )

    send(compositor, {:slide_timer, :next_photo})
    assert_receive {:advance_called, 0}, 500
    assert_receive {:advance_called, 1}, 500

    port_calls = MockCairoPort.calls(port)
    assert Enum.any?(port_calls, &match?({:free_slot, _}, &1))
  end

  test "{:slide_timer, :next_photo} when disconnected sets disconnected flag" do
    port = make_port(:disconnected_test)

    compositor =
      make_compositor(port,
        advance_fn: fn -> :disconnected end
      )

    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(20)
    state = :sys.get_state(compositor)
    assert state.disconnected == true
    assert state.phase == :idle
  end

  test "{:slide_timer, :next_photo} when empty sets empty_album flag" do
    port = make_port(:empty_test)

    compositor =
      make_compositor(port,
        advance_fn: fn -> :empty end
      )

    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(20)
    state = :sys.get_state(compositor)
    assert state.empty_album == true
    assert state.phase == :idle
  end

  test "image_loaded clears disconnected and empty_album flags" do
    port = make_port(:clear_flags_test)
    {:ok, agent} = Agent.start_link(fn -> :disconnected end)

    compositor =
      make_compositor(port,
        advance_fn: fn -> Agent.get(agent, & &1) end
      )

    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(20)
    assert :sys.get_state(compositor).disconnected == true

    Agent.update(agent, fn _ -> make_asset() end)
    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(500)

    state = :sys.get_state(compositor)
    assert state.disconnected == false
    assert state.empty_album == false
  end

  test "weather and queue position fns are called during transition" do
    port = make_port(:overlay_test)
    test_pid = self()

    compositor =
      make_compositor(port,
        advance_fn: fn -> make_asset() end,
        weather_fn: fn ->
          send(test_pid, :weather_called)
          :unavailable
        end,
        queue_position_fn: fn ->
          send(test_pid, :queue_pos_called)
          {1, 5}
        end
      )

    send(compositor, {:slide_timer, :next_photo})
    assert_receive :weather_called, 1000
    assert_receive :queue_pos_called, 500
  end

  test "metadata with date and location is included in overlay" do
    port = make_port(:metadata_test)
    date = ~D[2026-05-22]
    asset = {StubSource, "test-id", %{}, %{date: date, location: "Portland, OR"}}

    compositor =
      make_compositor(port,
        advance_fn: fn -> asset end
      )

    send(compositor, {:slide_timer, :next_photo})
    Process.sleep(100)
    state = :sys.get_state(compositor)
    assert state.metadata.date == date
    assert state.metadata.location == "Portland, OR"
  end

  test "unknown messages are ignored" do
    port = make_port(:unknown_msg_test)
    compositor = make_compositor(port)
    send(compositor, :totally_unknown_message)
    Process.sleep(20)
    state = :sys.get_state(compositor)
    assert state.phase == :idle
  end
end

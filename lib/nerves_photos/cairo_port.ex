defmodule NervesPhotos.CairoPort do
  use GenServer
  import Bitwise
  require Logger

  @timeout_default 500
  @timeout_load 5000
  @timeout_render 100

  def start_link(opts \\ []) do
    gen_opts = if name = opts[:name], do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def init_display(pid \\ __MODULE__, opts \\ []) do
    GenServer.call(pid, {:init_display, opts}, @timeout_default)
  end

  def load_image(pid \\ __MODULE__, slot_id, image_bytes) do
    GenServer.call(pid, {:load_image, slot_id, image_bytes}, @timeout_load)
  end

  def free_slot(pid \\ __MODULE__, slot_id) do
    GenServer.call(pid, {:free_slot, slot_id}, @timeout_default)
  end

  def render_frame(pid \\ __MODULE__, params) do
    GenServer.call(pid, {:render_frame, params}, @timeout_render)
  end

  def get_dimensions(pid \\ __MODULE__) do
    GenServer.call(pid, :get_dimensions, @timeout_default)
  end

  def ping(pid \\ __MODULE__) do
    GenServer.call(pid, :ping, @timeout_default)
  end

  @impl true
  def init(opts) do
    {port, send_fn} = do_open_port(opts)
    {:ok, %{port: port, send_fn: send_fn, pending: nil}}
  end

  @impl true
  def handle_call(request, from, state) do
    payload = encode_command(request)
    state.send_fn.(payload)
    {:noreply, %{state | pending: {request, from}}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, pending: {request, from}} = state) do
    reply = decode_response(data, request)
    GenServer.reply(from, reply)
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("CairoPort: compositor exited with status #{code}")

    if state.pending do
      {_request, from} = state.pending
      GenServer.reply(from, {:error, {:compositor_exited, code}})
    end

    {:stop, {:compositor_exited, code}, %{state | pending: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_open_port(opts) do
    case opts[:open_port_fn] do
      nil ->
        port = open_port(opts[:binary_path])
        {port, &Port.command(port, &1)}

      f ->
        {fake_pid, send_fn} = f.()
        {fake_pid, send_fn}
    end
  end

  defp open_port(nil), do: open_port(compositor_binary_path())

  defp open_port(path) do
    Port.open(
      {:spawn_executable, path},
      [:binary, :exit_status, {:packet, 4}, :use_stdio, :stderr_to_stdout]
    )
  end

  defp compositor_binary_path do
    Application.app_dir(:nerves_photos, "priv/compositor")
  end

  defp encode_command({:init_display, opts}) do
    width = opts[:width] || 1920
    height = opts[:height] || 1080
    mode = encode_display_mode(opts[:display_mode] || :auto)
    <<0x01, width::big-unsigned-16, height::big-unsigned-16, mode>>
  end

  defp encode_command({:load_image, slot_id, bytes}) do
    size = byte_size(bytes)
    <<0x02, slot_id::8, size::big-unsigned-32, bytes::binary>>
  end

  defp encode_command({:free_slot, slot_id}) do
    <<0x03, slot_id::8>>
  end

  defp encode_command({:render_frame, params}) do
    transition = encode_transition(params[:transition_type] || :none)
    t = params[:t] || 0.0
    crop = encode_crop_mode(params[:crop_mode] || :letterbox)
    overlays = params[:overlays] || %{}
    {flags, overlay_data} = encode_overlays(overlays)
    <<0x04, transition::8, t::big-float-32, crop::8, flags::8, overlay_data::binary>>
  end

  defp encode_command(:get_dimensions), do: <<0x05>>
  defp encode_command(:ping), do: <<0x06>>

  defp encode_display_mode(:auto), do: 0
  defp encode_display_mode(:fbdev), do: 1
  defp encode_display_mode(:drm), do: 2

  defp encode_transition(:none), do: 0
  defp encode_transition(:fade_to_black), do: 1
  defp encode_transition(:cross_dissolve), do: 2

  defp encode_crop_mode(:letterbox), do: 0
  defp encode_crop_mode(:center_crop), do: 1

  defp encode_overlays(overlays) do
    flags = 0
    data = <<>>

    {flags, data} =
      if overlays[:date] || overlays[:location] do
        date_bin = encode_string(overlays[:date] || "")
        loc_bin = encode_string(overlays[:location] || "")
        {flags ||| 0x01, data <> date_bin <> loc_bin}
      else
        {flags, data}
      end

    {flags, data} =
      if overlays[:temp] || overlays[:condition] do
        temp_bin = encode_string(overlays[:temp] || "")
        cond_bin = encode_string(overlays[:condition] || "")
        {flags ||| 0x02, data <> temp_bin <> cond_bin}
      else
        {flags, data}
      end

    {flags, data} =
      if overlays[:debug] do
        {flags ||| 0x04, data <> encode_string(overlays[:debug])}
      else
        {flags, data}
      end

    flags = if overlays[:show_disconnected], do: flags ||| 0x08, else: flags
    flags = if overlays[:show_empty_album], do: flags ||| 0x10, else: flags

    {flags, data}
  end

  defp encode_string(s) when is_binary(s) do
    truncated = binary_part(s, 0, min(byte_size(s), 255))
    <<byte_size(truncated)::8, truncated::binary>>
  end

  defp encode_string(nil), do: <<0>>

  defp decode_response(<<0xA0>>, _request), do: :ok

  defp decode_response(<<0xA1, _code::8, len::8, msg::binary-size(len), _rest::binary>>, _request) do
    {:error, msg}
  end

  defp decode_response(<<0xA2, _slot::8, w::big-unsigned-16, h::big-unsigned-16>>, _request) do
    {:ok, {w, h}}
  end

  defp decode_response(<<0xA3, w::big-unsigned-16, h::big-unsigned-16>>, _request) do
    {:ok, {w, h}}
  end

  defp decode_response(<<0xA4>>, _request), do: :pong

  defp decode_response(data, request) do
    Logger.warning("CairoPort: unexpected response #{inspect(data)} for #{inspect(request)}")
    {:error, :unexpected_response}
  end
end

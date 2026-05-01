defmodule NervesPhotos.ConnectivityMonitor do
  use GenServer
  require Logger

  @ap_ssid "NervesPhotos-Setup"
  @ap_ip "192.168.4.1"
  @connect_timeout_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def mode, do: GenServer.call(__MODULE__, :mode)

  def connect(ssid, psk) do
    GenServer.cast(__MODULE__, {:connect, ssid, psk})
  end

  @impl true
  def init(_opts) do
    send(self(), :configure_wifi)
    {:ok, %{mode: :initializing, connect_timer: nil}}
  end

  def handle_info(:configure_wifi, state) do
    VintageNet.subscribe(["interface", "wlan0", "connection"])

    case NervesPhotos.SettingsStore.get(:wifi_ssid) do
      ssid when ssid in [nil, ""] ->
        apply_ap_mode()
        {:noreply, %{state | mode: :ap}}

      ssid ->
        psk = NervesPhotos.SettingsStore.get(:wifi_psk) || ""
        apply_client_mode(ssid, psk)
        timer = Process.send_after(self(), :connect_timeout, @connect_timeout_ms)
        {:noreply, %{state | mode: :connecting, connect_timer: timer}}
    end
  end

  @impl true
  def handle_call(:mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_cast({:connect, ssid, psk}, state) do
    if state.connect_timer, do: Process.cancel_timer(state.connect_timer)
    apply_client_mode(ssid, psk)
    timer = Process.send_after(self(), :connect_timeout, @connect_timeout_ms)
    {:noreply, %{state | mode: :connecting, connect_timer: timer}}
  end

  @impl true
  def handle_info(
        {VintageNet, ["interface", "wlan0", "connection"], _old, :connected, _meta},
        state
      ) do
    if state.connect_timer, do: Process.cancel_timer(state.connect_timer)
    Logger.info("ConnectivityMonitor: WiFi connected")
    {:noreply, %{state | mode: :client, connect_timer: nil}}
  end

  def handle_info(
        {VintageNet, ["interface", "wlan0", "connection"], _old, status, _meta},
        state
      ) do
    Logger.debug("ConnectivityMonitor: wlan0 connection status → #{inspect(status)}")
    {:noreply, state}
  end

  def handle_info(:connect_timeout, %{mode: :connecting} = state) do
    Logger.warning("ConnectivityMonitor: WiFi connect timed out, falling back to AP mode")
    apply_ap_mode()
    {:noreply, %{state | mode: :ap, connect_timer: nil}}
  end

  def handle_info(:connect_timeout, state), do: {:noreply, state}

  defp apply_ap_mode do
    Logger.info("ConnectivityMonitor: starting AP '#{@ap_ssid}' at #{@ap_ip}")

    VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{mode: :ap, ssid: @ap_ssid, key_mgmt: :none}]
      },
      ipv4: %{method: :static, address: @ap_ip, prefix_length: 24},
      dhcpd: %{
        start: "192.168.4.2",
        end: "192.168.4.10",
        options: %{
          dns: [@ap_ip],
          router: [@ap_ip],
          subnet: "255.255.255.0"
        }
      }
    })
  end

  defp apply_client_mode(ssid, psk) do
    Logger.info("ConnectivityMonitor: connecting to '#{ssid}'")

    VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{networks: [%{ssid: ssid, psk: psk, key_mgmt: :wpa_psk}]},
      ipv4: %{method: :dhcp}
    })
  end
end

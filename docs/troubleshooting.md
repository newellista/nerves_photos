# NervesPhotos — IEx Console Troubleshooting

Connect to the device over SSH (requires an SSH public key baked into the firmware):

```
ssh nerves.local
```

If `nerves.local` doesn't resolve, find the device IP in your router's connected-device list and use that instead.

---

## Logs

Stream new log entries to the console as they arrive:

```elixir
RingLogger.attach()
```

Print buffered log entries (last ~50 lines by default):

```elixir
RingLogger.next()
RingLogger.next(200)    # print the last 200 lines
```

Increase log verbosity for the current session:

```elixir
Logger.put_primary_level(:debug)
```

---

## Application status

### Check which supervisor children are running

```elixir
Supervisor.which_children(NervesPhotos.Supervisor)
```

Each entry is `{id, pid_or_status, type, modules}`. A pid means the process is alive; `:restarting` means it crashed and the supervisor is waiting to restart it; `:undefined` means it failed to start.

### Check the compositor sub-supervisor

```elixir
Supervisor.which_children(NervesPhotos.CompositorSupervisor)
```

The compositor runs under a `rest_for_one` sub-supervisor — `CairoPort` first, then `FrameCompositor`. If `CairoPort` crashes, both are restarted together.

### Check whether individual processes are alive

```elixir
Process.whereis(NervesPhotos.PhotoQueue)        # pid or nil
Process.whereis(NervesPhotos.WeatherFetcher)    # pid or nil
Process.whereis(NervesPhotos.SlideTimer)        # pid or nil
Process.whereis(NervesPhotos.CairoPort)         # pid or nil
Process.whereis(NervesPhotos.Scene.Main)        # pid or nil (FrameCompositor's registered name)
Process.whereis(NervesPhotos.ConnectivityMonitor) # pid or nil (nil on host)
```

`nil` means the process is not running.

---

## Starting processes that are not running

In normal operation the supervisor restarts crashed processes automatically. If a process is stuck in a restart loop (exceeded `max_restarts`), the supervisor itself will exit and Shoehorn will restart the application. If you need to intervene manually:

### Restart a single GenServer

Stopping a process cleanly triggers the supervisor to restart it:

```elixir
GenServer.stop(NervesPhotos.PhotoQueue, :normal)
GenServer.stop(NervesPhotos.WeatherFetcher, :normal)
GenServer.stop(NervesPhotos.SlideTimer, :normal)
```

### Restart the Cairo compositor (both CairoPort and FrameCompositor)

```elixir
GenServer.stop(NervesPhotos.CairoPort, :normal)
# rest_for_one restarts CairoPort first, then FrameCompositor
```

### Restart the entire application

```elixir
Application.stop(:nerves_photos)
Application.start(:nerves_photos)
```

### Reboot the device

```elixir
Nerves.Runtime.reboot()
```

---

## Photo queue

### Check queue state

```elixir
NervesPhotos.PhotoQueue.queue_position()
# => {current_index, total}  e.g. {3, 120}
# => {0, 0}  when the queue is empty or not configured
```

### Check current photo

```elixir
NervesPhotos.PhotoQueue.current()
# => {module, source_id, config, %{date: ~D[...], location: "..."}}  when a photo is loaded
# => :not_configured   no sources configured yet
# => :loading          fetching sources for the first time
# => :disconnected     all sources failed (network error, wrong credentials, etc.)
# => :empty            sources reachable but all albums are empty
```

### Force the queue to re-fetch all sources immediately

```elixir
GenServer.stop(NervesPhotos.PhotoQueue, :normal)
# supervisor restarts it; it will call list_assets on all configured sources
```

---

## Cairo compositor

### Ping the compositor process

```elixir
NervesPhotos.CairoPort.ping()
# => :pong   compositor is alive and responding
# => timeout / exit  compositor is dead or unresponsive
```

### Get the current display dimensions

```elixir
NervesPhotos.CairoPort.get_dimensions()
# => {:ok, {1920, 1080}}
```

---

## Weather

### Check current weather data

```elixir
NervesPhotos.WeatherFetcher.current()
# => {:ok, %{temp_f: 72.3, condition: "Clear sky"}}
# => :unavailable   not yet fetched or all fetch attempts failed
```

---

## Settings

### View all settings

```elixir
NervesPhotos.SettingsStore.all()
```

### View a specific key

```elixir
NervesPhotos.SettingsStore.get(:photo_sources)
NervesPhotos.SettingsStore.get(:slide_interval_ms)
NervesPhotos.SettingsStore.get(:wifi_ssid)
NervesPhotos.SettingsStore.get(:weather_zip)
```

### Update a setting at runtime

```elixir
NervesPhotos.SettingsStore.put(:slide_interval_ms, 60_000)   # 60-second interval
NervesPhotos.SettingsStore.put(:weather_zip, "90210")
```

Changes are persisted immediately to `/data/nerves_photos/settings.json`. Running processes use the stored value on their next cycle; to apply changes to live processes, restart the affected GenServer.

---

## Users

### List all user accounts

```elixir
NervesPhotos.UserStore.all()
# => [%{username: "steve", role: "admin", password_hash: "..."}]
```

### Reset a forgotten password (delete and recreate)

```elixir
# Delete the account
NervesPhotos.UserStore.delete("username")

# Then browse to http://nerves.local/login
# With no users in the store, the login page shows the account creation form
```

---

## Network / WiFi

### Full network status

```elixir
VintageNet.info()
```

### WiFi interface status

```elixir
VintageNet.get("wlan0", ["connection"])    # :internet | :lan | :disconnected
VintageNet.get_configuration("wlan0")     # current applied configuration
```

### Check connectivity mode (AP vs client)

```elixir
GenServer.call(NervesPhotos.ConnectivityMonitor, :mode)
# => :ap           device is in setup access-point mode
# => :connecting   trying to connect to the configured WiFi network
# => :client       connected to WiFi
```

### Test internet reachability

```elixir
:httpc.request(:get, {~c"http://api.open-meteo.com", []}, [{:timeout, 5000}], [])
# {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, ...}}  means internet is reachable
# {:error, ...}  means it is not
```

---

## Firmware

### Check firmware version and metadata

```elixir
Nerves.Runtime.KV.get("nerves_fw_version")
Nerves.Runtime.KV.get_all_active()   # full key/value map of active firmware slot
```

### Check available disk space on the data partition

```elixir
{out, 0} = System.cmd("df", ["-h", "/data"])
IO.puts(out)
```

# Local CI & Pipeline Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `mix ci` alias that runs all quality checks locally, wire the CI workflow to use it, and fix the existing compile warning that blocks the pipeline.

**Architecture:** All changes are configuration and tooling only — no application logic changes. The `mix ci` alias becomes the single source of truth for what "passing" means, used identically locally and in GitHub Actions. The `connectivity_monitor.ex` compile warning is a prerequisite fix so `mix ci` can actually run to completion.

**Tech Stack:** Elixir/Mix aliases, `credo ~> 1.7`, `mix_audit ~> 2.1`, GitHub Actions YAML.

---

### Task 1: Fix compile warning in ConnectivityMonitor

The `handle_info(:configure_wifi, state)` clause at line 25 of `connectivity_monitor.ex` is missing `@impl true` and appears before `handle_call`/`handle_cast`, so the `handle_info` clauses are not grouped. This causes `mix compile --warnings-as-errors` to fail.

**Files:**
- Modify: `lib/nerves_photos/connectivity_monitor.ex`

- [ ] **Step 1: Run compile to confirm the warning**

```bash
mix compile --warnings-as-errors
```

Expected output ends with:
```
warning: clauses with the same name and arity ... "def handle_info/2" was previously defined (lib/nerves_photos/connectivity_monitor.ex:25)
Compilation failed due to warnings while using the --warnings-as-errors option
```

- [ ] **Step 2: Move the `:configure_wifi` handler to be grouped with all other `handle_info` clauses**

Replace the entire file content of `lib/nerves_photos/connectivity_monitor.ex` with the grouped version below. The only changes are: removing `handle_info(:configure_wifi)` from line 25 (after `init`), adding `@impl true` to it, and inserting it before the other `handle_info` clauses (after `handle_cast`):

```elixir
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
```

- [ ] **Step 3: Run compile to confirm warning is gone**

```bash
mix compile --warnings-as-errors
```

Expected: clean compile, no warnings, exit 0.

- [ ] **Step 4: Commit**

```bash
git add lib/nerves_photos/connectivity_monitor.ex
git commit -m "fix: group handle_info clauses in ConnectivityMonitor to clear compile warning"
```

---

### Task 2: Add credo and mix_audit deps

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add dev-only deps to `mix.exs`**

In the `deps/0` function, add these two lines at the end of the list (before the closing `]`):

```elixir
# Dev tooling
{:credo, "~> 1.7", only: :dev, runtime: false},
{:mix_audit, "~> 2.1", only: :dev, runtime: false}
```

- [ ] **Step 2: Fetch new deps**

```bash
mix deps.get
```

Expected: credo and mix_audit downloaded and added to `mix.lock`.

- [ ] **Step 3: Verify credo runs**

```bash
mix credo --strict
```

Expected: either a clean pass or a list of credo findings. Either outcome is fine at this step — we just need the command to run without crashing.

- [ ] **Step 4: Verify deps.audit runs**

```bash
mix deps.audit
```

Expected: either "No vulnerabilities found" or a list of CVEs.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore: add credo and mix_audit as dev deps"
```

---

### Task 3: Add `mix ci` alias

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add the `ci` alias to the `aliases/0` function in `mix.exs`**

The existing `aliases/0` looks like:

```elixir
def aliases do
  [
    "deps.get": ["deps.get", "cmd patch --forward -p1 -d deps/scenic_driver_local < patches/scenic_driver_local.patch || true"]
  ]
end
```

Add the `ci` alias alongside `deps.get`:

```elixir
def aliases do
  [
    "deps.get": [
      "deps.get",
      "cmd patch --forward -p1 -d deps/scenic_driver_local < patches/scenic_driver_local.patch || true"
    ],
    ci: [
      "compile --warnings-as-errors",
      "format --check-formatted",
      "credo --strict",
      "deps.audit",
      "hex.audit",
      "test"
    ]
  ]
end
```

- [ ] **Step 2: Run `mix ci` to verify the full pipeline passes locally**

```bash
mix ci
```

Expected: all six steps pass in sequence, exit 0. If credo or audit report findings, address them before continuing (see notes below).

**If `mix credo --strict` reports issues:** fix each one before moving on. Common findings in Elixir projects:
- Unused aliases/imports → remove them
- Module doc missing → add `@moduledoc false` or a real doc
- Long function bodies → usually safe to ignore with `# credo:disable-for-next-line` if it's a known Nerves pattern

**If `mix deps.audit` reports CVEs:** check if updates are available (`mix hex.outdated`) and update affected deps in `mix.exs`.

**If `mix hex.audit` reports retired packages:** update to the recommended replacement.

- [ ] **Step 3: Commit**

```bash
git add mix.exs
git commit -m "chore: add mix ci alias for local pipeline checks"
```

---

### Task 4: Update CI workflow to use `mix ci`

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Replace the three individual `run:` steps in the `test` job with `mix ci`**

The current `test` job ends with:

```yaml
      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix format --check-formatted
      - run: mix test
```

Replace with:

```yaml
      - run: mix deps.get
      - run: mix ci
```

The `firmware` job is unchanged.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: use mix ci alias in test job"
```

# NervesPhotos

A Nerves-based digital photo frame that displays a rotating slideshow from multiple photo sources — any combination of Immich albums and Google Photos shared albums. Runs on Raspberry Pi hardware with a connected HDMI display. Includes a built-in web UI for configuration and overlays for weather and photo metadata.

---

## Features

- Fetches photos from multiple configured sources (Immich albums, Google Photos shared albums) merged into a single shuffled pool
- Fades smoothly between photos (20-step crossfade at ~60 fps)
- Overlays photo date and location (from EXIF) in the bottom-left corner
- Overlays current temperature and weather condition in the bottom-right corner
- Weather fetched every 15 minutes from [Open-Meteo](https://open-meteo.com) (free, no API key)
- Location resolved by ZIP code or falls back to IP geolocation
- Web UI served on port 80 for configuration (WiFi, slide interval); photo sources managed via JSON API
- AP bootstrap: if no WiFi credentials are saved, the device opens a `NervesPhotos-Setup` access point so the web UI is reachable on first boot without a pre-configured network

---

## Supported Targets

| Target | Scenic backend | Hardware |
|--------|---------------|----------|
| `rpi0` | DRM/KMS | Raspberry Pi Zero / Zero W |
| `rpi3` | BCM (VideoCore IV) | Raspberry Pi 3B / 3B+ |
| `rpi4` | DRM/KMS + GLES3 | Raspberry Pi 4 |
| `rpi5` | DRM/KMS + GLES3 | Raspberry Pi 5 |
| `host` | — | Development / CI (no display, no VintageNet) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 OTP Supervisor (one_for_one)             │
│                                                         │
│  SettingsStore       ← persistent JSON at /data/...     │
│  ConnectivityMonitor ← owns wlan0 via VintageNet        │
│  SettingsServer      ← Cowboy HTTP on port 80           │
│  PhotoQueue          ← fetches all sources concurrently │
│  WeatherFetcher      ← polls Open-Meteo every 15 min   │
│  SlideTimer          ← sends :next_photo tick           │
│  ImageLoader         ← downloads preview images        │
│  Scenic viewport     ← Scene.Main renders to display   │
└─────────────────────────────────────────────────────────┘
```

### Data flow

```
SlideTimer ──:next_photo──► Scene.Main ──advance()──► PhotoQueue
                                │                         │
                          4-tuple asset             shuffled queue
                          {module,id,cfg,meta}      (all sources merged)
                                │
                          ImageLoader.load(asset)
                                │
                          module.fetch_image(id, cfg)
                                │
                    Scenic.Assets.Stream.put()
                                │
                          {:image_loaded} ──► Scene.Main renders frame
```

### Module summary

| Module | Role |
|--------|------|
| `SettingsStore` | GenServer; reads/writes `/data/nerves_photos/settings.json`; all settings keyed as atoms |
| `ConnectivityMonitor` | GenServer; configures `wlan0` — client mode if credentials saved, AP mode otherwise; falls back to AP on 30s connect timeout |
| `SettingsServer` | Thin `child_spec` wrapper; serves `SettingsRouter` via Cowboy on port 80 |
| `SettingsRouter` | Plug router; `GET /settings` renders HTML form; `POST /settings` persists settings and live-restarts PhotoQueue/WeatherFetcher/SlideTimer; `GET/POST/DELETE /settings/photo_sources` manages sources |
| `PhotoSource` | Behaviour; defines `list_assets/1` and `fetch_image/2` callbacks |
| `Sources.Immich` | Stateless; fetches Immich album asset lists and thumbnail images |
| `Sources.GooglePhotos` | Stateless; fetches Google Photos shared album pages and images |
| `PhotoQueue` | GenServer; fetches all sources concurrently via `Task.async_stream`, merges into a shuffled queue, serves `current/0` and `advance/0`; states: `:not_configured`, `:loading`, `:disconnected`, `:empty`; exponential backoff on errors |
| `WeatherFetcher` | GenServer; resolves location (ZIP → Open-Meteo geocoding, else IP → ip-api.com), fetches current conditions every 15 min |
| `ImageLoader` | GenServer; spawns a `Task` per image fetch; pushes JPEG bytes into `Scenic.Assets.Stream` |
| `Scene.Main` | Scenic scene; manages photo/fade/overlay rendering; drives transitions |
| `Component.MetadataOverlay` | Scenic component; renders date + location badge (bottom-left) |
| `Component.WeatherOverlay` | Scenic component; renders temperature + condition badge (bottom-right) |

---

## Prerequisites

- **Elixir ~> 1.19** and **Erlang/OTP 26+**
- **nerves_bootstrap ~> 1.15** archive: `mix archive.install hex nerves_bootstrap`
- **fwup**: `brew install fwup` (macOS) or see [fwup releases](https://github.com/fwup-home/fwup/releases)
- An SSH public key in `~/.ssh/` — required by `config/target.exs` for device access
- At least one photo source: a running [Immich](https://immich.app) instance or a Google Photos shared album link

---

## Environment variables

Copy `.env.example` to `.env.work` and fill in your values (file is gitignored):

```bash
export MIX_TARGET=rpi5          # rpi0 | rpi3 | rpi4 | rpi5

export SLIDE_INTERVAL_MS=30000
export SHOW_DEBUG=false
```

WiFi credentials and photo sources are managed at runtime — not via env vars.

---

## Managing photo sources

Photo sources are configured at runtime via the HTTP API — no env vars or firmware rebuild needed.

### Add an Immich album
```bash
curl -X POST http://nerves.local/settings/photo_sources \
  -H "Content-Type: application/json" \
  -d '{"type":"immich","url":"http://192.168.1.10:2283","api_key":"your-key","album_id":"your-album-uuid"}'
```

### Add a Google Photos shared album
```bash
curl -X POST http://nerves.local/settings/photo_sources \
  -H "Content-Type: application/json" \
  -d '{"type":"google_photos","share_url":"https://photos.app.goo.gl/yoursharelink"}'
```

### List current sources
```bash
curl http://nerves.local/settings/photo_sources
```

### Remove a source (0-based index)
```bash
curl -X DELETE http://nerves.local/settings/photo_sources/0
```

Photos from all sources are merged into a single shuffled queue.

---

## Build and flash

```bash
source .env.work
mix deps.get            # also applies the scenic_driver_local patch
MIX_TARGET=rpi5 mix firmware
MIX_TARGET=rpi5 mix burn          # writes to SD card (prompts for device)
```

### Subsequent firmware updates over SSH

Once the device is on the network:

```bash
source .env.work
MIX_TARGET=rpi5 mix firmware
mix upload nerves.local            # or the device's mDNS hostname / IP
```

---

## Running tests

Tests run on the `:host` target and mock all external dependencies via `Req.Test`:

```bash
mix test
```

No hardware or network connection needed.

## Git hooks

A pre-commit hook that enforces `mix format` is committed in `.hooks/`. Install it once after cloning:

```bash
ln -sf ../../.hooks/pre-commit .git/hooks/pre-commit
```

---

## Settings storage

Settings are persisted to `/data/nerves_photos/settings.json` on the device's writable data partition. The file survives firmware OTA updates.

| Key | Type | Description |
|-----|------|-------------|
| `photo_sources` | list | JSON list of source configs. Each entry has `type` plus type-specific fields. Default: `[]` |
| `slide_interval_ms` | integer | Milliseconds between slides (default: 30 000) |
| `wifi_ssid` | string | WiFi network name |
| `wifi_psk` | string | WiFi password |
| `weather_zip` | string | ZIP code for weather (blank = use IP geolocation) |

---

## scenic_driver_local patch

`scenic_driver_local` 0.11's DRM Makefile links against `-lvchostif`, which is absent from the rpi0 sysroot. `patches/scenic_driver_local.patch` removes that flag for DRM targets only. It is applied automatically by the `deps.get` alias in `mix.exs` and is safe to re-apply (`patch --forward` skips already-applied hunks).

---

## Project structure

```
lib/nerves_photos/
├── application.ex           # OTP Application, builds supervision tree
├── settings_store.ex        # Persistent key/value store
├── settings_server.ex       # Cowboy child_spec wrapper
├── settings_router.ex       # Plug HTTP router + HTML settings form + photo_sources API
├── connectivity_monitor.ex  # WiFi / AP bootstrap manager
├── photo_source.ex          # Behaviour: list_assets/1, fetch_image/2
├── photo_queue.ex           # Multi-source photo queue (replaces ImmichClient)
├── sources/
│   ├── immich.ex            # Immich album source
│   └── google_photos.ex     # Google Photos shared album source
├── weather_fetcher.ex       # Open-Meteo weather poller
├── slide_timer.ex           # Periodic :next_photo sender
├── image_loader.ex          # Async image downloader → Scenic stream
├── scene/
│   ├── main.ex              # Primary Scenic scene (display loop)
│   └── headless.ex          # No-op scene for headless targets
└── component/
    ├── metadata_overlay.ex  # Date + location badge
    ├── weather_overlay.ex   # Temp + condition badge
    ├── debug_bar.ex         # Queue position counter (dev only)
    └── sick_sun.ex          # Weather icon graphic
```

---

## Extending the project

**Add a new setting:** add the atom key to `@keys` in `SettingsStore`, add a default in `load/1`, add a form field in `SettingsRouter.render_form/1`, and handle it in the `POST /settings` clause.

**Add a new display overlay:** create a `Scenic.Component` module in `lib/nerves_photos/component/`, then call `YourComponent.add_to_graph/3` inside `Scene.Main.render/1`.

**Add a new photo source:** implement the `NervesPhotos.PhotoSource` behaviour — `list_assets/1` (given the source config map, return `{:ok, [{id, %{date, location}}]}`) and `fetch_image/2` (given `source_id` and config, return `{:ok, binary}`). Register the module in `PhotoQueue.source_module/1` and add the type string to `@valid_source_types` in `SettingsRouter`.

**Support a new hardware target:** add the `nerves_system_*` dep to `mix.exs`, add the `MIX_TARGET` case in `setup_nerves_env/0` with the correct `SCENIC_LOCAL_TARGET` value (`drm` or `bcm`), and add the target atom to `scenic_driver_local`'s `targets:` list.

---

## Learn more

- [Nerves getting started](https://hexdocs.pm/nerves/getting-started.html)
- [Nerves supported targets](https://hexdocs.pm/nerves/supported-targets.html)
- [Scenic framework](https://hexdocs.pm/scenic)
- [VintageNet](https://github.com/nerves-networking/vintage_net)
- [Immich](https://immich.app)
- [Elixir Forum — Nerves](https://elixirforum.com/c/nerves-forum)

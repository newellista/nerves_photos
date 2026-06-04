# NervesPhotos

A Nerves-based digital photo frame that displays a rotating slideshow from multiple photo sources — any combination of Immich albums and Google Photos shared albums. Runs on Raspberry Pi hardware with a connected HDMI display. Includes a built-in web UI for configuration and overlays for weather and photo metadata.

---

## Features

- Fetches photos from multiple configured sources (Immich albums, Google Photos shared albums) merged into a single shuffled pool
- Smooth transitions between photos — configurable as fade-to-black, cross-dissolve, or instant cut; rendered by a C compositor via Cairo
- Overlays photo date and location (from EXIF) in the bottom-left corner
- Overlays current temperature and weather condition in the bottom-right corner
- Weather fetched every 15 minutes from [Open-Meteo](https://open-meteo.com) (free, no API key)
- Location resolved by ZIP code or falls back to IP geolocation
- Web UI served on port 80 for configuration (WiFi, slide interval, photo sources, users)
- AP bootstrap: if no WiFi credentials are saved, the device opens a `NervesPhotos-Setup` access point so the web UI is reachable on first boot without a pre-configured network
- Session-based authentication; first-boot admin account creation flow

---

## Supported Targets

| Target | Hardware |
|--------|----------|
| `rpi0_2` | Raspberry Pi Zero 2 W |
| `rpi3` | Raspberry Pi 3B / 3B+ |
| `rpi4` | Raspberry Pi 4 |
| `rpi5` | Raspberry Pi 5 |
| `host` | Development / CI (no display, no VintageNet) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 OTP Supervisor (one_for_one)             │
│                                                         │
│  SettingsStore       ← persistent JSON at /data/...     │
│  UserStore           ← persistent user accounts         │
│  ConnectivityMonitor ← owns wlan0 via VintageNet        │
│  SettingsServer      ← Cowboy HTTP on port 80           │
│  PhotoQueue          ← fetches all sources concurrently │
│  WeatherFetcher      ← polls Open-Meteo every 15 min   │
│  SlideTimer          ← sends :next_photo tick           │
│  CompositorSupervisor (rest_for_one)                    │
│    CairoPort         ← protocol bridge to C compositor  │
│    FrameCompositor   ← photo state machine              │
└─────────────────────────────────────────────────────────┘
```

In headless mode (`headless_mode: true`), `CompositorSupervisor` is replaced by `Scene.Headless`, a no-op GenServer that logs slide advances without rendering.

### Data flow

```
SlideTimer ──{:slide_timer, :next_photo}──► FrameCompositor
                                                 │
                                     PhotoQueue.advance()
                                                 │
                              Task.start(load_and_notify)
                                                 │
                           module.fetch_image(source_id, cfg)
                                                 │
                            CairoPort.load_image(slot, bytes)
                                                 │
                         {:image_loaded, slot} ──► FrameCompositor
                                                 │
                          CairoPort.render_frame(params)
                                                 │
                               C compositor → display
```

### Module summary

| Module | Role |
|--------|------|
| `SettingsStore` | GenServer; reads/writes `/data/nerves_photos/settings.json`; all settings keyed as atoms |
| `UserStore` | GenServer; reads/writes `/data/nerves_photos/users.json`; list of user maps |
| `User` | Struct + helpers; bcrypt password hashing via `bcrypt_elixir` |
| `AuthPlug` | Plug; session-based auth; bypasses auth in AP mode when no users exist (bootstrap) |
| `AuthRouter` | Plug router; `GET/POST /login`, `POST /logout`, `GET/POST/DELETE/PATCH /settings/users` |
| `Policy` | Bodyguard policy; admins can delete sources and manage users; editors can manage (but not delete) sources |
| `ConnectivityMonitor` | GenServer; configures `wlan0` — client mode if credentials saved, AP mode otherwise; falls back to AP on 30s connect timeout |
| `SettingsServer` | Thin `child_spec` wrapper; serves `SettingsRouter` via Cowboy on port 80 |
| `SettingsRouter` | Plug router; `GET /settings` renders HTML form; `POST /settings` persists settings and live-restarts PhotoQueue/WeatherFetcher/SlideTimer; `GET/POST/DELETE/PUT /settings/photo_sources` manages sources |
| `CurrentRouter` | Plug router; `GET /current` full-screen photo display (HTML, auto-reloads); `GET /current/photo` serves current photo as JPEG |
| `PhotoSource` | Behaviour; defines `list_assets/1` and `fetch_image/2` callbacks |
| `Sources.Immich` | Stateless; fetches Immich album asset lists and thumbnail images |
| `Sources.GooglePhotos` | Stateless; fetches Google Photos shared album pages and images |
| `PhotoQueue` | GenServer; fetches all sources concurrently via `Task.async_stream`, merges into a shuffled queue, serves `current/0` and `advance/0`; states: `:not_configured`, `:loading`, `:disconnected`, `:empty`; exponential backoff on errors |
| `WeatherFetcher` | GenServer; resolves location (ZIP → Open-Meteo geocoding, else IP → ip-api.com), fetches current conditions every 15 min |
| `CairoPort` | GenServer; binary protocol bridge to the `priv/compositor` C executable; encodes commands and decodes responses over a 4-byte-length-prefixed stdio port |
| `FrameCompositor` | GenServer; photo state machine — idle → loading → transitioning → idle; spawns a Task per image fetch; calls `CairoPort` to render frames and overlays; registered as `NervesPhotos.Scene.Main` for `SlideTimer` compatibility |
| `Scene.Headless` | GenServer; no-op; logs slide advances; registered as `NervesPhotos.Scene.Main` in headless mode |

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
export MIX_TARGET=rpi5          # rpi0_2 | rpi3 | rpi4 | rpi5

export SLIDE_INTERVAL_MS=30000
export SHOW_DEBUG=false
```

WiFi credentials and photo sources are managed at runtime — not via env vars.

### Runtime application config

The following keys are read via `Application.get_env(:nerves_photos, key, default)` at runtime:

| Key | Default | Values |
|-----|---------|--------|
| `:transition_type` | `:fade_to_black` | `:fade_to_black`, `:cross_dissolve`, `:none` |
| `:crop_mode` | `:letterbox` | `:letterbox`, `:center_crop` |
| `:compositor_display_mode` | `:auto` | `:auto`, `:drm`, `:fbdev` |
| `:headless_mode` | `false` | `true`, `false` |
| `:show_debug` | `false` | `true`, `false` |

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
mix deps.get
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

Tests run on the `:host` target and stub HTTP sources via `Req.Test`:

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

User accounts are persisted separately at `/data/nerves_photos/users.json`. Each user has a `username`, bcrypt-hashed `password_hash`, and `role` (`"admin"` or `"editor"`).

---

## Project structure

```
lib/nerves_photos/
├── application.ex           # OTP Application, builds supervision tree
├── auth_plug.ex             # Session auth; AP bootstrap bypass
├── auth_router.ex           # Login/logout + /settings/users management
├── cairo_port.ex            # Protocol bridge to priv/compositor C binary
├── connectivity_monitor.ex  # WiFi / AP bootstrap manager
├── current_router.ex        # GET /current (HTML display) + GET /current/photo (JPEG)
├── frame_compositor.ex      # Photo state machine (idle→loading→transitioning)
├── photo_source.ex          # Behaviour: list_assets/1, fetch_image/2
├── photo_queue.ex           # Multi-source photo queue
├── policy.ex                # Bodyguard authorization policy
├── settings_store.ex        # Persistent key/value store
├── settings_server.ex       # Cowboy child_spec wrapper
├── settings_router.ex       # Plug HTTP router + HTML settings form + photo_sources API
├── slide_timer.ex           # Periodic :next_photo sender
├── user.ex                  # User struct + bcrypt password helpers
├── user_store.ex            # Persistent user account store
├── weather_fetcher.ex       # Open-Meteo weather poller
├── scene/
│   └── headless.ex          # No-op scene for headless mode
└── sources/
    ├── immich.ex             # Immich album source
    └── google_photos.ex      # Google Photos shared album source
```

The C compositor lives in `c_src/` and is compiled by `elixir_make` to `priv/compositor`.

---

## Extending the project

**Add a new setting:** add the atom key to `@keys` in `SettingsStore`, add a default in `load/1`, add a form field in `SettingsRouter.render_form/1`, and handle it in the `POST /settings` clause.

**Add a new display overlay:** overlays are rendered in the C compositor. Encode the new overlay data in `CairoPort.encode_overlays/1` (add a flag bit and a data serializer), pass it from `FrameCompositor.build_overlays/4`, then implement the corresponding rendering in `c_src/compositor.c`.

**Add a new photo source:** implement the `NervesPhotos.PhotoSource` behaviour — `list_assets/1` (given the source config map, return `{:ok, [{id, %{date, location}}]}`) and `fetch_image/2` (given `source_id` and config, return `{:ok, binary}`). Register the module in `PhotoQueue.source_module/1` and add the type string to `@valid_source_types` in `SettingsRouter`.

**Support a new hardware target:** add the `nerves_system_*` dep to `mix.exs` and add the target atom to `@all_targets`. The C compositor auto-detects the display backend (DRM or fbdev) at runtime; no Makefile changes are needed for standard Pi targets.

---

## Open issues / future work

- `POST /settings` has no test coverage (pre-existing gap)
- Google Photos source uses HTML scraping — may break if Google changes the share page format; OAuth support planned
- Offline mode concept spec exists at `docs/superpowers/specs/` (not yet planned/implemented)

---

## Learn more

- [Nerves getting started](https://hexdocs.pm/nerves/getting-started.html)
- [Nerves supported targets](https://hexdocs.pm/nerves/supported-targets.html)
- [VintageNet](https://github.com/nerves-networking/vintage_net)
- [Immich](https://immich.app)
- [Elixir Forum — Nerves](https://elixirforum.com/c/nerves-forum)

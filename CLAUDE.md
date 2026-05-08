# nerves_photos

## Git Workflow

Always create a feature branch and git worktree before making any code changes. Use the `superpowers:using-git-worktrees` skill at the start of any implementation task.

Never commit directly to `main`. All changes go through a PR.

Worktrees live in `.worktrees/` (already gitignored).

## docs/superpowers

- Always commit plans and specs — don't leave them untracked after a session.
- When a feature ships, add `> Implemented in PR #N` to the corresponding spec file before or promptly after merging.
- Specs live in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`.

---

## What This Project Is

A digital photo frame running on Raspberry Pi (rpi0, rpi3, rpi4, rpi5) using Nerves. The display is driven by **Scenic** over DRM (rpi4/rpi5) or BCM VideoCore (rpi3). Photos are fetched from remote sources (Immich, Google Photos) and cycled on a configurable timer. A web UI on port 80 (port 4000 in host mode) lets users configure everything without SSH.

---

## Project Structure

```
lib/nerves_photos/
  application.ex          # Supervision tree — differs by Mix.target()
  photo_source.ex         # Behaviour: list_assets/1, fetch_image/2
  photo_queue.ex          # GenServer: fetches & cycles assets from all sources
  image_loader.ex         # GenServer: fetches bytes, puts into Scenic stream
  slide_timer.ex          # GenServer: sends :next_photo to Scene.Main on interval
  weather_fetcher.ex      # GenServer: polls open-meteo every 15 min
  connectivity_monitor.ex # GenServer: manages VintageNet WiFi (client/AP mode)
  settings_store.ex       # GenServer: file-backed settings (JSON at /data/nerves_photos/settings.json)
  settings_server.ex      # Plug.Cowboy HTTP server wrapping SettingsRouter
  settings_router.ex      # Plug.Router: /settings UI + /settings/photo_sources API + /current
  scene/
    main.ex               # Scenic scene: renders photo with overlays, handles transitions
    headless.ex           # Scenic scene: headless mode (no display)
  component/
    metadata_overlay.ex   # Scenic component: date + location text
    weather_overlay.ex    # Scenic component: temp + condition
    debug_bar.ex          # Scenic component: queue position indicator
  sources/
    immich.ex             # PhotoSource impl: Immich self-hosted
    google_photos.ex      # PhotoSource impl: Google Photos shared album (HTML scraping)
```

---

## GenServer Communication Map

```
SlideTimer ──:next_photo──▶ Scene.Main
                                │
                                ├──advance()──▶ PhotoQueue ◀──:fetch_all (self)
                                │                   │
                                │                   └──list_assets()──▶ Sources.Immich
                                │                                        Sources.GooglePhotos
                                │
                                └──load()──▶ ImageLoader ──fetch_image()──▶ Sources.*
                                                │
                                                └──{:image_loaded, key}──▶ Scene.Main
                                                   (puts to Scenic.Assets.Stream)

Scene.Main ──current()──▶ WeatherFetcher   (on every render)
Scene.Main ──queue_position()──▶ PhotoQueue (on every render)

SettingsRouter ──get/put──▶ SettingsStore
SettingsRouter ──{:connect, ssid, psk}──▶ ConnectivityMonitor
SettingsRouter ──GenServer.stop──▶ PhotoQueue, WeatherFetcher, SlideTimer  (on POST /settings)
```

**Asset tuple format** (flows from PhotoQueue → ImageLoader → Scene.Main):
`{source_module, source_id, config_map, metadata_map}`
- `metadata_map` keys: `:date` (Date or nil), `:location` (string or nil)

---

## PhotoSource Behaviour

```elixir
@callback list_assets(config :: map()) ::
  {:ok, [{source_id :: String.t(), metadata :: map()}]} | {:error, term()}

@callback fetch_image(source_id :: String.t(), config :: map()) ::
  {:ok, binary()} | {:error, term()}
```

`config` is an atom-keyed map from SettingsStore. Adding a new source type requires:
1. A module implementing `PhotoSource`
2. Adding the type string to `@valid_source_types` in `SettingsRouter`
3. Adding a `source_module/1` clause in `PhotoQueue`
4. HTML in `render_sources_section/1`, `render_add_*_form/0`, and `render_edit_form/2`

---

## Settings Store

Keys: `:photo_sources`, `:slide_interval_ms`, `:wifi_ssid`, `:wifi_psk`, `:weather_zip`

- Persisted as JSON at `/data/nerves_photos/settings.json` (device) or `~/.nerves_photos/settings.json` (host mode)
- Atom keys after decode (uses `keys: :atoms`)
- `photo_sources` is a list of atom-keyed maps: `[%{type: "immich", url: ..., api_key: ..., album_id: ...}, ...]`

---

## Settings Web UI

`GET /settings` — sidebar layout with four sections: Display, WiFi, Photo Sources, Users (placeholder)

`POST /settings` — saves slide_interval_ms (UI sends seconds, stored as ms), weather_zip, wifi_ssid/psk; restarts PhotoQueue/WeatherFetcher/SlideTimer

`GET/POST/DELETE/PUT /settings/photo_sources[/:index]` — JSON API for photo source management

`PUT /settings/photo_sources/:index` uses **merge semantics** — fields omitted from the body are preserved from the stored value (intentional: allows editing without re-entering api_key).

`GET /current` — full-screen HTML page for the photo display (auto-reloads on slide interval)
`GET /current/photo` — serves current photo bytes as image/jpeg

All HTML is inline strings in `settings_router.ex`. No Phoenix, no templates, no build step. `Plug.HTML.html_escape/1` is used on all user-supplied content. JS is inlined in `render_settings_js/0`.

---

## Supervision Trees by Target

**host** (`MIX_TARGET=host`): `SettingsStore`, `SettingsServer` only — for testing the settings UI locally without a device.

**embedded** (rpi3/4/5): `SettingsStore`, `ConnectivityMonitor`, `SettingsServer`, `PhotoQueue`, `WeatherFetcher`, `SlideTimer`, `ImageLoader`, `Scenic` (+ `Scene.Main` or `Scene.Headless`)

**test** (`MIX_ENV=test`): empty — all processes started explicitly via `start_supervised!`

---

## Running Locally (Host Mode)

```bash
MIX_TARGET=host mix run --no-halt
# open http://localhost:4000/settings
```

Settings persist to `~/.nerves_photos/settings.json`. NervesTime NTP is disabled in host mode (empty servers list). SlideTimer/PhotoQueue/WeatherFetcher do NOT run — host mode is settings-UI-only.

---

## Testing

```bash
MIX_TARGET=host mix test
```

- All tests use `async: false` and `start_supervised!` with unique temp file paths.
- Pattern for any describe block that starts SettingsStore:
  ```elixir
  path = "/tmp/nerves_photos_test_DESCRIPTOR_#{:erlang.unique_integer([:positive])}.json"
  File.rm(path)
  start_supervised!({NervesPhotos.SettingsStore, [path: path]})
  on_exit(fn -> File.rm(path) end)
  ```
- Tests use real dependencies at system boundaries — no mocking of internal modules.
- HTTP sources (Immich, GooglePhotos) accept `req_options:` in config for test stubbing.

---

## Development Process

Steve uses the **superpowers** skill system:

1. **Brainstorm** (`superpowers:brainstorming`) — idea → design spec → saved to `docs/superpowers/specs/`
2. **Plan** (`superpowers:writing-plans`) — spec → implementation plan → saved to `docs/superpowers/plans/`
3. **Execute** (`superpowers:subagent-driven-development`) — fresh subagent per task, two-stage review (spec compliance then code quality) after each task, final overall review at the end
4. **Finish** (`superpowers:finishing-a-development-branch`) — verify tests, push, open PR

Always work in a git worktree (`superpowers:using-git-worktrees`). Worktrees in `.worktrees/`.

Pre-commit hook enforces `mix format` — commits will be rejected if formatting is off. Run `MIX_TARGET=host mix format` before committing.

---

## Key Constraints

- No Phoenix — pure `Plug.Router` with inline HTML strings
- No JS build step — all JavaScript inlined in `render_settings_js/0` (~80 lines)
- Scenic `0.11.x` — DRM driver on rpi4/5, BCM on rpi3
- `String.to_existing_atom/1` (not `String.to_atom/1`) for body params — atom table safety
- `Integer.parse/1` (not `String.to_integer/1`) for path params — returns 400 on bad input
- ConnectivityMonitor is only started on embedded targets — not available in host mode; SettingsRouter uses `Process.whereis` to guard calls to it

---

## Open Issues / Future Work

- `#18` — User management / authentication (Users section in settings is a placeholder)
- `POST /settings` has no test coverage (pre-existing gap)
- Offline mode concept spec exists at `docs/superpowers/specs/` (not yet planned/implemented)

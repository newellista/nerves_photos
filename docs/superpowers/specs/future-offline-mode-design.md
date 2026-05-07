# Offline Mode — Future Design Spec

**Status: Future / Not Yet Planned**

This document captures a future feature concept. It is not scheduled for implementation. Its purpose is to preserve the design intent so a future developer (or AI) can plan and implement it without needing to rediscover the requirements.

---

## Overview

Offline mode allows NervesPhotos to operate without any network connection at runtime. When enabled, the device serves photos exclusively from a local cache on an attached SSD, and replaces the weather overlay with a live clock.

---

## Hardware Requirement

Offline mode requires an attached SSD with sufficient capacity to hold all source photos. Without an SSD, offline mode must be unavailable and any attempt to enable it should fail at settings-save time with a clear error message.

The expected SSD mount point is `/mnt/ssd`. Offline mode availability should be gated on `/mnt/ssd` being mounted and having writable free space.

---

## Two Sub-Modes

### Sync

Downloads and caches all photos from all configured `photo_sources` to the local SSD. This is a one-shot operation triggered on demand (no automatic scheduling in v1).

- Walks each configured source via `PhotoSource.list_assets/1`
- Downloads each asset via `PhotoSource.fetch_image/2`
- Writes JPEG files to `<offline_cache_path>/<source_index>/<asset_id>.jpg`
- Writes a manifest JSON file listing all cached assets and their metadata (date, location, source type)
- A failed sync for one source logs the error but does not corrupt the existing cache for other sources

### Playback

At startup, when `offline_mode: true`, the device reads from the local SSD cache instead of making any network calls to photo sources.

- Reads the manifest file to build the asset list
- Serves JPEG files directly from disk
- Makes zero HTTP calls to Immich, Google Photos, or any photo CDN

---

## Startup Behavior in Offline Mode

| Cache state | Internet available | Behavior |
|-------------|-------------------|----------|
| Cache exists | Either | Load from cache, start slideshow |
| Cache missing | Yes | Show error: "No local cache found. Run a sync first, or switch to Online mode." |
| Cache missing | No | Show error: "No local cache and no internet connection. Sync is required to use Offline mode." |

---

## Weather Replacement

In offline mode, the bottom-right overlay that normally shows temperature and weather condition is replaced by a live clock displaying the current local time in `HH:mm` format.

- No calls to `api.open-meteo.com`
- No calls to `ip-api.com`
- `WeatherFetcher` either does not start or starts in a no-op mode when `offline_mode: true`
- `Scene.Main` (or `Component.WeatherOverlay`) checks the setting and renders a clock widget instead

---

## New Settings Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `offline_mode` | boolean | `false` | Enable offline playback mode |
| `offline_cache_path` | string | `/mnt/ssd/nerves_photos/cache` | Root directory for cached photos and manifest |

---

## New Modules (Sketch)

### `NervesPhotos.PhotoCache`

Reads assets from the local SSD cache. Implements the `PhotoSource` behaviour (or an equivalent interface) so `PhotoQueue` can treat it as a drop-in source.

- `list_assets/1`: reads manifest JSON, returns `[{asset_id, meta}]`
- `fetch_image/2`: reads the JPEG file from `<offline_cache_path>/<source_index>/<asset_id>.jpg`

### `NervesPhotos.PhotoSync`

One-shot GenServer (or plain Task) that drives the sync operation.

- Started on demand via an API endpoint (e.g. `POST /settings/sync`)
- Iterates all configured `photo_sources`, downloads each asset, writes to SSD
- Reports progress and final status (count downloaded, count skipped, errors)

---

## Architecture Changes

- `PhotoQueue` checks `offline_mode` setting at startup:
  - `true` → delegates to `PhotoCache` instead of live source modules
  - `false` → existing behavior (live sources)
- `WeatherFetcher` checks `offline_mode`:
  - `true` → does not start (or starts in a disabled state returning `{:ok, nil}`)
- `Scene.Main` / `Component.WeatherOverlay` checks `offline_mode`:
  - `true` → renders clock widget in place of weather
- `SettingsRouter` adds `offline_mode` to the HTML form and to `@valid_keys` for POST
- `SettingsStore` adds `:offline_mode` and `:offline_cache_path` to `@keys`

---

## Open Questions

1. **SSD detection** — how to detect the SSD is mounted and healthy? Check `File.stat?("/mnt/ssd")` + free space via `:disksup`?
2. **Sync scheduling** — v1 is manual-only. Should a future version support automatic re-sync on a schedule or when new sources are added?
3. **Partial cache** — if sync completed for 2 of 3 sources, play what's available, or block until all sources are cached?
4. **Cache invalidation** — re-sync replaces all files, or delta-only (skip already-cached assets by ID)?
5. **Google Photos scraping fragility** — the HTML scraping used by `Sources.GooglePhotos` may break; a failed sync should not corrupt the existing cache. Delta sync or transactional writes (write to a temp dir, then atomic move) may help.
6. **Clock timezone** — use the system timezone (set from NTP/erlinit) or allow user-configurable timezone in settings?

---

## Critical Files to Understand Before Implementing

- `lib/nerves_photos/photo_queue.ex` — startup logic that needs the offline branch
- `lib/nerves_photos/settings_store.ex` — add new keys here
- `lib/nerves_photos/weather_fetcher.ex` — needs no-op mode or conditional start
- `lib/nerves_photos/scene/main.ex` — clock widget rendering
- `lib/nerves_photos/component/weather_overlay.ex` — swap weather for clock
- `config/target.exs` — SSD mount point configuration

---

## Acceptance Criteria (for when this is implemented)

- Unit tests for `PhotoCache` (reads from a fixture directory, no disk writes)
- Unit tests for `PhotoSync` (mocked source modules, writes to a temp dir)
- Integration test: `PhotoQueue` in offline mode serves from cache and makes zero HTTP calls
- Integration test: startup with missing cache + simulated internet → correct error state
- Manual: boot with SSD attached + cache populated → slideshow runs with no network activity
- Manual: boot with SSD missing or cache missing → error message visible on screen
- Manual: weather overlay replaced by `HH:mm` clock in offline mode

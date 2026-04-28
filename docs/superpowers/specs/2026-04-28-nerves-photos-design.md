# NervesPhotos Design Spec

**Date:** 2026-04-28
**Targets:** RPi0, RPi5

## Overview

A Nerves-based digital photo frame that streams photos from a user-configured Immich album and displays them as a full-screen automatic slideshow. Overlays show photo metadata (bottom-left) and current weather (bottom-right). Built with Scenic for the UI.

---

## Architecture

Five processes under `NervesPhotos.Supervisor` (strategy: `one_for_one`):

```
NervesPhotos.Supervisor
├── NervesPhotos.ImmichClient     — album fetch, shuffle queue, photo metadata
├── NervesPhotos.WeatherFetcher   — IP geolocation + Open-Meteo polling
├── NervesPhotos.SlideTimer       — fires :next_photo on configurable interval
├── NervesPhotos.ImageLoader      — fetches Immich preview, pushes to Scenic asset stream
└── Scenic Viewport               → NervesPhotos.Scene.Main (render only)
```

Each GenServer owns a single concern. The Scenic scene is a pure renderer — it reads state from GenServers and builds the scene graph.

---

## Components

### ImmichClient

- On init: fetches the configured album's photo list via Immich REST API, shuffles it into a queue
- Exposes `current/0` → `{asset_id, %{date, location}}` for the current photo
- Exposes `advance/0` → advances the queue index and returns the new `{asset_id, metadata}`
- When the queue is exhausted: re-fetches the album (picks up newly added photos) and re-shuffles
- On HTTP error: sets internal state to `:disconnected`, retries with exponential backoff (1s → 2s → 4s… capped at 60s)

### WeatherFetcher

- On init: determines device location via `ip-api.com` (free, no API key, returns lat/lon)
- Fetches current weather from Open-Meteo (free, no API key required)
- Polls every 15 minutes via `Process.send_after`
- Exposes `current/0` → `{:ok, %{temp_f, condition, icon_code}}` or `:unavailable`
- On error: returns `:unavailable` and retries on the next scheduled poll

### SlideTimer

- Uses an internal `Process.send_after` loop to schedule ticks
- On each tick: sends `{:slide_timer, :next_photo}` to `Scene.Main` via `send(NervesPhotos.Scene.Main, ...)`
- Interval configured via `SLIDE_INTERVAL_MS` env var (default: `30_000`)

### ImageLoader

- Called by `Scene.Main` with a photo asset ID
- Requests a preview-sized image from Immich (`/api/assets/{id}/thumbnail?size=preview`) on both targets — no local image processing required
- Pushes raw image bytes to `Scenic.Assets.Stream` under a known asset key
- On decode error: logs via `RingLogger` and sends `{:image_load_error}` back to scene — scene advances to next photo

### Scene.Main

- Subscribes to `SlideTimer` ticks via `handle_info`
- On `:next_photo` tick:
  1. Calls `ImmichClient.advance()` to get next `{asset_id, metadata}`
  2. Dispatches `ImageLoader.load(asset_id)` asynchronously
  3. Initiates transition animation (see Transitions)
- On image loaded: completes transition, updates scene graph with new photo + metadata overlay
- On `ImmichClient` state `:disconnected`: freezes current photo, shows "Reconnecting…" badge
- Reads `WeatherFetcher.current()` on each slide update to refresh weather overlay

---

## UI Layout

Full-screen viewport at the display's native resolution (auto-detected by the DRM driver). Three visual layers rendered as Scenic primitives:

```
┌─────────────────────────────────────────────┐
│                                             │
│           [ full-screen photo ]             │
│                                             │
│  [ ⟳ Reconnecting… ]  ← top-center,        │
│                          visible only when  │
│                          disconnected       │
│                                             │
│  June 12, 2023          ☁️ 68°F            │
│  Yosemite Natl Park     Partly Cloudy       │
└─────────────────────────────────────────────┘
  ↑ bottom-left overlay   ↑ bottom-right overlay
```

**Bottom-left overlay:** semi-transparent gradient rect + text showing photo date and location (from Immich metadata). Hidden if metadata is absent.

**Bottom-right overlay:** semi-transparent gradient rect + weather icon + temperature + condition label. When `WeatherFetcher` returns `:unavailable`, shows a "sick sun" Scenic component (a custom-drawn sun face with a thermometer — no emoji, Scenic renders primitives only) in place of the normal icon.

**Reconnecting badge:** semi-transparent pill at top-center, visible only when `ImmichClient` is in `:disconnected` state.

---

## Photo Transitions

Implemented as a `handle_info` tick loop in `Scene.Main` that interpolates opacity values manually (Scenic has no built-in tweening).

**RPi5 — Crossfade:**
- Two `Scenic.Assets.Stream` slots (`slot_a`, `slot_b`) alternate as front/back
- Outgoing photo fades from opacity 1.0 → 0.0 while incoming fades from 0.0 → 1.0 simultaneously
- New photo is loaded into the back slot before the transition begins

**RPi0 — Fade to Black:**
- One `Scenic.Assets.Stream` slot
- A black rect layered on top animates from opacity 0.0 → 1.0, photo is swapped, then 0.0 again
- Only one image texture in memory at a time

Target selected at compile time via `Mix.target()`.

---

## Configuration

All configuration via environment variables, loaded in `config/target.exs`, following the existing project pattern (see `.env.home`, `.env.work`).

| Variable | Description | Default |
|---|---|---|
| `IMMICH_URL` | Base URL of Immich server | required |
| `IMMICH_API_KEY` | Immich API key | required |
| `IMMICH_ALBUM_ID` | Album ID to display | required |
| `SLIDE_INTERVAL_MS` | Milliseconds between photos | `30000` |

---

## Resilience

| Scenario | Behaviour |
|---|---|
| Immich unreachable | Freeze last photo, show "Reconnecting…" badge, retry with exponential backoff (cap 60s) |
| Album empty / not found | Show "No photos found" message; retry album fetch every 5 minutes |
| Photo fails to decode | Log error, silently skip to next photo |
| Weather unavailable | Show sick-sun Scenic component in weather overlay; retry on next 15-min poll |
| Album queue exhausted | Re-fetch album from Immich (picks up new photos), re-shuffle, continue |
| GenServer crash | Supervisor restarts that process independently; other processes unaffected |

---

## Future Considerations

- **In-app configuration UI:** A Scenic settings scene to configure Immich URL/key/album and slide interval without needing SSH + env var changes. Not in scope for this iteration.
``
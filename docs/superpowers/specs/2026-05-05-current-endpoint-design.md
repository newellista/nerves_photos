# /current Endpoint Design

**Date:** 2026-05-05

## Goal

Add a `/current` HTTP endpoint to the existing settings web server that shows what the Scenic photo frame scene is currently displaying — photo, metadata overlay, weather overlay, and status indicators — without requiring a physical monitor. Primary use case: verifying the Scenic scene logic during headless development.

## Architecture

Two new routes added to the existing `NervesPhotos.SettingsRouter` (Plug/Cowboy on port 80). No new modules.

Works in both headless mode (`headless_mode: true`) and display mode since both run `ImmichClient` and `WeatherFetcher`.

## Routes

### `GET /current`

Returns an HTML page that visually recreates the Scenic scene in the browser.

- Calls `ImmichClient.current()` for `{asset_id, %{date, location}}` or a status atom
- Calls `WeatherFetcher.current()` for weather data
- Reads `SettingsStore.get(:slide_interval_ms)` for the auto-refresh interval
- Renders a full-viewport HTML page with the photo loaded via `<img src="/current/photo">` and CSS-positioned overlays
- Uses `setTimeout(location.reload, slide_interval_ms)` so the browser stays in sync with the slide timer
- Handles all `ImmichClient` states with appropriate in-scene message overlays:
  - `:loading` → centered "Loading..." message on black background
  - `:disconnected` → black background + amber "Reconnecting..." banner (no photo; `current()` only returns this atom when the queue is empty)
  - `:empty` → centered "No photos found in album" pill on black background
  - `:not_configured` → centered "Not configured" message on black background

### `GET /current/photo`

Proxies the current photo JPEG from Immich.

- Calls `ImmichClient.current()` to get the current `asset_id`
- Calls `ImmichClient.connection_info()` for `{url, api_key}`
- Fetches `GET /api/assets/{asset_id}/thumbnail?size=preview` from Immich via `Req`
- Returns bytes as `image/jpeg`
- Returns `503` plain-text for non-photo states (`:loading`, `:disconnected`, `:empty`, `:not_configured`)

## HTML Layout

Full-viewport container (`position: relative; width: 100vw; height: 100vh; background: black; overflow: hidden`).

Photo: `<img>` with `object-fit: contain; width: 100%; height: 100%; position: absolute`.

### Overlays

All overlays use `position: absolute`. Geometry mirrors the Scenic component source exactly.

| Overlay | CSS position | Size | Background | Font |
|---|---|---|---|---|
| Metadata (date + location) | `bottom: 8px; left: 16px` | 400×70px | `rgba(0,0,0,0.55)` | 18px date (white), 15px location (`rgba(255,255,255,0.71)`) |
| Weather (temp + condition) | `bottom: 8px; right: 16px` | 184×70px | `rgba(0,0,0,0.55)` | 20px temp (white), 14px condition (`rgba(255,255,255,0.71)`) |
| "Reconnecting..." banner | `top: 16px; left: 50%; transform: translateX(-50%)` | 140×30px pill | `rgba(0,0,0,0.63)` | 16px, `rgb(255,204,68)` |
| "No photos found" message | `top: 50%; left: 50%; transform: translate(-50%, -50%)` | 200×36px pill | `rgba(0,0,0,0.63)` | 16px white |
| Debug bar | `bottom: 8px; left: 50%; transform: translateX(-50%)` | 80×28px | `rgba(0,0,0,0.63)` | 16px white |

The debug bar is gated on `Application.get_env(:nerves_photos, :show_debug, false)`, matching `Scene.Main`.

Weather shows `"No weather data"` when `WeatherFetcher` returns `:unavailable`, matching `WeatherOverlay`.

## What This Does Not Cover

- Fade transitions (the crossfade between slides is not replicated — the endpoint always shows the current steady-state photo)
- `SickSun` graphic in the weather overlay (replaced with plain text "No weather data")
- Pixel-perfect font rendering (browser fonts differ from Scenic's Roboto rendering)

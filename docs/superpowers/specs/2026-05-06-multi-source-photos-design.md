# Multi-Source Photo Support

**Date:** 2026-05-06

## Context

The photo frame currently supports a single Immich album configured via flat settings keys (`immich_url`, `immich_api_key`, `immich_album_id`). Users want to display photos from multiple sources — any number of Immich albums and/or Google Photos shared albums — merged into a single shuffled slideshow queue. This spec replaces the single-source architecture with an extensible multi-source design.

## Goals

- Support 0..many Immich albums and 0..many Google Photos shared album links
- All photos from all sources are merged into one shuffled pool
- Clean break from the flat settings schema — no backward-compat shims
- Architecture extensible toward Google Photos OAuth in a future iteration

## Configuration Schema

`SettingsStore` replaces `immich_url`, `immich_api_key`, `immich_album_id` with a single `photo_sources` key containing a list of source maps.

```json
{
  "photo_sources": [
    { "type": "immich", "url": "http://192.168.1.10:2283", "api_key": "abc123", "album_id": "uuid-1" },
    { "type": "immich", "url": "http://192.168.1.10:2283", "api_key": "abc123", "album_id": "uuid-2" },
    { "type": "google_photos", "share_url": "https://photos.app.goo.gl/xxxx" }
  ]
}
```

`photo_sources` defaults to `[]`. An empty list puts the system in `:not_configured` state.

## Architecture

### New / Changed Modules

| Module | Change |
|--------|--------|
| `NervesPhotos.PhotoSource` | New — behaviour definition |
| `NervesPhotos.Sources.Immich` | New — Immich implementation |
| `NervesPhotos.Sources.GooglePhotos` | New — Google Photos shared album implementation |
| `NervesPhotos.PhotoQueue` | New — replaces `ImmichClient` |
| `NervesPhotos.ImageLoader` | Updated — delegates fetch to source module |
| `NervesPhotos.SettingsStore` | Updated — schema change, remove old Immich keys |
| `NervesPhotos.SettingsRouter` | Updated — new source management endpoints |
| `NervesPhotos.ImmichClient` | Deleted |

### Process Tree

Unchanged shape — `ImmichClient` is replaced by `PhotoQueue`:

```
Supervisor
  SettingsStore
  ConnectivityMonitor
  SettingsServer
  PhotoQueue
  WeatherFetcher
  SlideTimer
```

### Asset Representation

Throughout the system, assets change from `{id_string, metadata}` to a three-element tuple:

```elixir
{SourceModule, source_id, metadata}
```

Examples:
```elixir
{NervesPhotos.Sources.Immich, "asset-uuid", %{date: ~D[2024-01-01], location: "Paris, France"}}
{NervesPhotos.Sources.GooglePhotos, "https://lh3.googleusercontent.com/abc123", %{date: nil, location: nil}}
```

For `Sources.GooglePhotos`, the `source_id` is the direct `lh3.googleusercontent.com` image URL — `fetch_image/2` performs a plain HTTP GET.

## `PhotoSource` Behaviour

```elixir
@callback list_assets(config :: map()) ::
  {:ok, [{source_id :: String.t(), metadata :: map()}]} | {:error, term()}

@callback fetch_image(source_id :: String.t(), config :: map()) ::
  {:ok, binary()} | {:error, term()}
```

Both callbacks are stateless. `config` is the source map from settings. `PhotoQueue` owns all state; source modules are pure functions.

## `Sources.Immich`

- `list_assets/1` — `GET /api/albums/{album_id}`, returns `[{id, %{date, location}}]`
- `fetch_image/2` — `GET /api/assets/{id}/thumbnail?size=preview`, returns binary

Ports the existing `ImmichClient` fetch and parse logic unchanged.

## `Sources.GooglePhotos`

- `list_assets/1` — fetches the share URL, parses the HTML response to extract photo entries from the embedded JSON blob Google includes in the page, returns `[{lh3_url, %{date, location}}]`
- `fetch_image/2` — `Req.get(source_id)` (source_id is the full image URL)

The HTML parsing logic is isolated in a private `parse_share_page/1` function so it can be updated independently when Google changes the page format. On parse failure, the source is treated as an error and logged.

This implementation is intentionally simple. A future iteration will replace it with the Google Photos Library API using OAuth2.

## `PhotoQueue` GenServer

Replaces `ImmichClient` as the single queue process. Public interface is identical to `ImmichClient` (`current/0`, `advance/0`, `queue_position/0`). `connection_info/0` is removed.

**State:**
```elixir
%{
  queue: [{module, source_id, metadata}],
  index: 0,
  status: :not_configured | :loading | :ok | :empty | :disconnected,
  backoff: integer()
}
```

**Startup:** reads `photo_sources` from `SettingsStore`. Empty list → `:not_configured`, polls every 5s. Non-empty → sends `:fetch_all`.

**`:fetch_all`:** calls `module.list_assets(config)` for each source concurrently via `Task.async_stream`. Merges all returned asset lists, shuffles the combined pool. Partial failures are logged but do not block — photos from successful sources are shown. On total failure, exponential backoff with the same parameters as the current `ImmichClient`.

**`advance/0`:** increments index. When the last photo in the queue is reached, triggers a fresh `:fetch_all` to pick up newly added photos.

## `ImageLoader` Changes

`load/1` accepts the full `{module, source_id, metadata}` tuple instead of a plain `asset_id` string. On each load, reads the current `photo_sources` list from `SettingsStore` to build a `module → config` lookup, then calls `module.fetch_image(source_id, config)`. Reading fresh from `SettingsStore` on each load avoids state-sync complexity and ensures config changes take effect immediately.

## `SettingsRouter` Changes

Remove the existing `immich_url`, `immich_api_key`, `immich_album_id` PUT endpoints.

Add:

| Method | Path | Body | Action |
|--------|------|------|--------|
| `GET` | `/settings/photo_sources` | — | Return current sources list |
| `POST` | `/settings/photo_sources` | `{type, ...fields}` | Append a source |
| `DELETE` | `/settings/photo_sources/:index` | — | Remove source at index |

## Error Handling

| Situation | Behavior |
|-----------|----------|
| `photo_sources` is `[]` | `:not_configured`; poll every 5s for config |
| All sources fail `list_assets` | Exponential backoff; `:disconnected` |
| Some sources fail, some succeed | Log failures; show photos from successful sources |
| Google Photos page format changed | Log parse error; treat source as failed |
| Queue exhausted | Re-fetch all sources |
| `ImageLoader` `fetch_image` fails | Log warning; send `{:image_load_error, asset}` to caller |

## Documentation Updates

- `README.md` — update configuration section: replace `IMMICH_*` env vars with `photo_sources` JSON structure; update "Add a new photo source" extension guide to reference the `PhotoSource` behaviour
- `docs/user-guide.md` — replace single-album setup instructions with multi-source setup; document both Immich and Google Photos source types and the settings API endpoints

## Testing

Full test coverage is required for all new and changed modules.

- **`Sources.Immich`** — unit tests with `Req` mock (same pattern as existing `ImmichClient` tests); cover success, HTTP errors, empty album, asset parse
- **`Sources.GooglePhotos`** — unit tests with a fixture of real Google Photos share page HTML; cover success, parse failure, HTTP error, `fetch_image` direct URL fetch
- **`PhotoQueue`** — unit tests with mock source modules injected via opts; cover: empty sources, single source, multiple sources, partial source failure, total failure + backoff, queue exhaustion triggering re-fetch
- **`ImageLoader`** — unit tests with mock `SettingsStore` and mock source modules; cover success, fetch failure, unknown source type
- **`SettingsRouter`** — cover `GET/POST/DELETE /settings/photo_sources` including index out-of-bounds on DELETE
- **`SettingsStore`** — cover `photo_sources` persistence, default to `[]`, rejection of unknown keys

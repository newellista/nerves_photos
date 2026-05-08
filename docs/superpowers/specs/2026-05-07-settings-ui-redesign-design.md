# Settings UI Redesign — Design Spec

## Goal

Reorganize the `/settings` page from a single monolithic form into a sidebar-navigated layout with discrete sections. This accommodates the growing number of settings areas (Display, WiFi, Photo Sources) and scales cleanly to future additions such as User Management.

---

## Navigation

A persistent left sidebar lists all settings sections. Clicking a section switches the content area in place via JavaScript — no page reloads. The URL stays `/settings` throughout.

Sidebar sections (in order):

| Label | Status |
|-------|--------|
| Display | Active |
| WiFi | Active |
| Photo Sources | Active |
| Users | Placeholder ("Coming soon") |

The **Display** section is shown by default on page load.

### JavaScript scope

Minimal inline JavaScript only:
- Section switching: show/hide content `<div>`s, update sidebar active state
- Inline form expand/collapse for edit and add (Photo Sources)

No external libraries, no build step. All JS is inlined in the HTML response.

---

## Sections

### Display *(default)*

Fields:
- **Slide interval** — numeric input, value in seconds (stored internally as milliseconds)
- **Weather ZIP code** — text input, optional

Single **Save** button. Posts to `POST /settings` (unchanged).

---

### WiFi

Fields:
- **Network name (SSID)** — text input
- **Password** — password input
- **Status** — read-only indicator showing current connectivity mode (Connected / Connecting... / Access Point)

Single **Save** button. Posts to `POST /settings` (unchanged).

---

### Photo Sources

Displays a list of all configured sources. Each row shows:
- Source type badge (Immich / Google Photos) and a brief description (server URL or "Shared album")
- **Edit** button — expands an inline form beneath the row, pre-filled with current values
- **Delete** button — removes the source immediately

Below the list, two distinct Add buttons:
- **+ Add Immich Album** — expands an inline form with fields: Server URL, API Key, Album ID
- **+ Add Google Photos Album** — expands an inline form with field: Share URL

Inline forms have **Save** and **Cancel** buttons. Cancel collapses the form without changes.

**Edit** uses a new `PUT /settings/photo_sources/:index` route. **Add** uses the existing `POST /settings/photo_sources`. **Delete** uses the existing `DELETE /settings/photo_sources/:index`.

Only one inline form (edit or add) is open at a time.

---

### Users *(placeholder)*

Greyed-out sidebar entry, no content rendered. Labelled "Coming soon." Will be activated when authentication and user management (GH issue #18) is implemented.

---

## Routes

### Changed

| Method | Path | Change |
|--------|------|--------|
| `GET /settings` | Renders new sidebar layout with Display section active by default |

### Unchanged

| Method | Path | Notes |
|--------|------|-------|
| `POST /settings` | Handles `slide_interval_ms`, `weather_zip`, `wifi_ssid`, `wifi_psk` as before |
| `GET /settings/photo_sources` | JSON — unchanged |
| `POST /settings/photo_sources` | JSON — unchanged |
| `DELETE /settings/photo_sources/:index` | JSON — unchanged |

### New

| Method | Path | Purpose |
|--------|------|---------|
| `PUT /settings/photo_sources/:index` | Update an existing photo source by index |

`PUT /settings/photo_sources/:index` accepts the same JSON body as `POST /settings/photo_sources`, validates the type and required fields, and replaces the entry at the given index. Returns 200 + updated source on success, 404 if index out of bounds, 422 on validation failure.

---

## HTML structure

`render_form/2` is replaced by `render_page/2`, which composes:

- `render_sidebar/1` — sidebar nav with active section highlighted
- `render_display_section/1` — display settings form
- `render_wifi_section/2` — WiFi settings form + status
- `render_sources_section/1` — source list + inline edit/add forms
- `render_users_placeholder/0` — greyed-out coming soon message

All HTML remains inline strings (consistent with existing codebase pattern). `Plug.HTML.html_escape/1` used for all user-supplied content.

---

## Testing

- Unit tests for `PUT /settings/photo_sources/:index`: valid update, index out of bounds, invalid body
- Existing photo source tests (`GET`, `POST`, `DELETE`) remain unchanged
- `MIX_TARGET=host mix run --no-halt` + manual browser walkthrough:
  - All three sections render and switch correctly
  - Save on Display and WiFi sections persists values
  - Add Immich / Add Google Photos forms open and submit correctly
  - Edit expands inline and saves correctly
  - Delete removes source from list
  - Users entry is visible but inactive

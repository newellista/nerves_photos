# Auth & Authorization Design

## Context

The NervesPhotos settings web UI is completely open — anyone on the same network can view or change settings. This spec covers session-based authentication and role-based authorization for the settings routes (issue #18).

---

## Decisions

- **Session store:** `Plug.Session` with ETS backend — sessions lost on reboot (acceptable)
- **Password hashing:** `bcrypt_elixir ~> 3.0` + `comeonin ~> 5.0`
- **Authorization:** `bodyguard ~> 2.4` with a `Policy` module
- **User storage:** Separate `users.json` file managed by a new `UserStore` GenServer (not mixed into `settings.json`)
- **CSRF protection:** `Plug.CSRFProtection` included in v1
- **Roles:** Editor and Admin (two roles)
- **Password policy:** Minimum 8 characters; no account lockout

---

## Data Model

Users are stored in `/data/nerves_photos/users.json` (device) or `~/.nerves_photos/users.json` (host mode), managed by `NervesPhotos.UserStore`.

Each user is an atom-keyed map:

```elixir
%{username: "alice", password_hash: "$2b$...", role: "admin"}
```

Roles stored as strings (`"admin"`, `"editor"`) for JSON compatibility; converted to atoms at point of use via `String.to_existing_atom/1`.

---

## New Modules

### `NervesPhotos.UserStore`

GenServer mirroring `SettingsStore` — file-backed JSON persistence, ETS-free, atom-keyed. Public API:

```elixir
UserStore.all()                          # -> [%{username:, password_hash:, role:}]
UserStore.get(username)                  # -> map | nil
UserStore.put(username, user_map)        # -> :ok | {:error, reason}
UserStore.delete(username)               # -> :ok
```

Default: empty list. Path configurable via `opts[:path]` or `:users_path` app env.

### `NervesPhotos.User`

Struct and validation — not a GenServer. Functions:

```elixir
User.new(username, password, role)       # -> {:ok, map} | {:error, reason}
User.verify_password(user_map, password) # -> boolean
```

Validation in `new/3`: username non-empty, password ≥ 8 chars, role in `~w(admin editor)`.

### `NervesPhotos.AuthPlug`

Plug that runs on every request after session parsing. Logic:

1. If `ConnectivityMonitor` is running and returns `:ap` **and** `UserStore.all()` is empty → assign `%{username: nil, role: :admin}` as `current_user`, skip all further checks (bootstrap AP bypass only)
2. If path is in the public allowlist (`/login`, `/current`, `/current/photo`) → pass through
3. If session has `current_user` → assign it to `conn.assigns` and pass through
4. Otherwise → redirect to `/login`

AP bypass only applies when no users exist. Once the first admin is created, a device in AP mode still requires login — the AP provides network access to reach `/login`, not a free pass into settings. This prevents a bad actor from forcing the device into AP mode (power cycle + blocked WiFi) to bypass auth on a configured device.

### `NervesPhotos.Policy`

`bodyguard` policy module:

```elixir
# Editor and Admin
def authorize(:view_settings, _user, _),   do: :ok
def authorize(:edit_settings, _user, _),   do: :ok
def authorize(:manage_sources, _user, _),  do: :ok   # add / edit

# Admin only
def authorize(:delete_source, %{role: :admin}, _),  do: :ok
def authorize(:manage_users, %{role: :admin}, _),   do: :ok
def authorize(_, _, _),                             do: {:error, :unauthorized}
```

Route handlers call `Bodyguard.permit!(Policy, :action, current_user)` and rescue `Bodyguard.NotAuthorizedError` with a 403 response.

---

## Authentication Flow

### Bootstrap Mode (no users exist)

- `GET /login` detects empty `UserStore` and renders a "Create first admin account" form
- `POST /login` in bootstrap mode: validates username + password (≥ 8 chars), creates the admin via `User.new/3` + `UserStore.put/2`, logs the user in immediately, redirects to `/settings`

### Normal Login

- `GET /login` renders username/password form
- `POST /login`: looks up username in `UserStore`, calls `User.verify_password/2`, on success stores `%{username: ..., role: atom}` in session and redirects to `/settings`
- Wrong credentials: re-render form with generic "Invalid username or password" (no hint which field was wrong)

### Logout

- `POST /logout` (CSRF-protected form button): clears session, redirects to `/login`

### AP Mode

- `AuthPlug` checks `Process.whereis(ConnectivityMonitor)` — if running, calls `GenServer.call(pid, :mode)`
- `:ap` AND `UserStore.all()` is empty → synthetic admin user assigned, no session check (bootstrap setup flow)
- `:ap` AND users exist → no bypass; bad actor who forces AP mode still must authenticate
- ConnectivityMonitor absent (host mode) → no bypass

### Credential Recovery

If a user loses their credentials, recovery is via SSH + IEx (the device already runs `nerves_ssh`):

```elixir
NervesPhotos.UserStore.delete("alice")
# or wipe all users to re-enter bootstrap mode:
File.rm("~/.nerves_photos/users.json")
```

No additional recovery mechanism is built into the web UI. SSH access is equivalent to physical access for a home device.

---

## Route Table

| Method | Path | Auth | Action |
|--------|------|------|--------|
| `GET` | `/login` | Public | Login form or bootstrap form |
| `POST` | `/login` | Public | Authenticate or create first admin |
| `POST` | `/logout` | Authenticated | Clear session |
| `GET` | `/settings` | Editor+ | Settings form |
| `POST` | `/settings` | Editor+ | Save settings |
| `GET` | `/settings/photo_sources` | Editor+ | List sources |
| `POST` | `/settings/photo_sources` | Editor+ | Add source |
| `DELETE` | `/settings/photo_sources/:index` | Admin | Delete source |
| `GET` | `/settings/users` | Admin | List users |
| `POST` | `/settings/users` | Admin | Add user |
| `DELETE` | `/settings/users/:username` | Admin | Remove user |
| `PATCH` | `/settings/users/:username/role` | Admin | Change role |
| `GET` | `/current` | Public | Photo display |
| `GET` | `/current/photo` | Public | Photo bytes |

---

## Plug Pipeline Changes

```elixir
plug Plug.Session, store: :ets, key: "_nerves_photos_session", signing_salt: "nerves_photos_sess"
plug Plug.CSRFProtection
plug :match
plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason
plug NervesPhotos.AuthPlug
plug :dispatch
```

`signing_salt` is a static string committed to the codebase — not secret, just unique to the app. The ETS session store requires `conn.secret_key_base` to be set; a `put_secret_key_base/2` plug reads it from `Application.get_env(:nerves_photos, :secret_key_base)`, configured in `config/config.exs`.

CSRF token injected into all state-changing forms via `Plug.CSRFProtection.get_csrf_token/0` as a hidden input.

---

## UI Changes

- **`/login`:** Minimal form — username, password, submit. In bootstrap mode, heading changes to "Create first admin account" and includes a password confirmation field.
- **Settings sidebar:** Users link visible to Admin only (hidden entirely for Editor). Links to `/settings/users`.
- **`/settings/users`:** Table of users with username, role, and Delete button (Admin only). Below the table, an "Add user" inline form (username, password, role select) following the same pattern as photo sources.
- **Logout:** Small "Log out" link or button in the settings page header, rendered as a `<form method="POST" action="/logout">` with CSRF token.

---

## Dependencies to Add

```elixir
{:bcrypt_elixir, "~> 3.0"},
{:comeonin, "~> 5.0"},
{:bodyguard, "~> 2.4"}
```

---

## Supervision

`UserStore` added to the supervision tree alongside `SettingsStore` in all targets (host, embedded). It is a peer of `SettingsStore`, not a child.

---

## Testing

All tests `async: false`, `start_supervised!` with unique temp paths.

- **`UserStoreTest`:** defaults to empty list; put/get/delete round-trips; persist and reload after restart
- **`UserTest`:** `new/3` validates min length, rejects short passwords, rejects invalid roles, hashes password; `verify_password/2` returns true/false
- **`AuthPlugTest`:** unauthenticated request → redirect to `/login`; valid session → `current_user` assigned; AP mode → admin role assigned; public paths pass through
- **`PolicyTest`:** Editor permitted on view/edit/manage_sources; Editor rejected on delete_source/manage_users; Admin permitted on all actions
- **`SettingsRouterTest`:** login flow (bootstrap form, first admin creation, normal login, logout); user management routes (add, delete, role change, 403 for Editors)

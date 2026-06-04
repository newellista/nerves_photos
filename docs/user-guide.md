# NervesPhotos — User Guide

NervesPhotos turns a Raspberry Pi into a digital photo frame. It pulls photos from one or more sources — Immich albums and/or Google Photos shared albums — and displays them in a shuffled slideshow on any HDMI monitor or TV. Current weather and photo details (date taken, location) appear as small overlays in the corners.

---

## What you need

### Hardware

| Item | Notes |
|------|-------|
| Raspberry Pi | Pi Zero 2 W, Pi 3B/3B+, Pi 4, or Pi 5 |
| microSD card | 8 GB or larger |
| HDMI display | TV, monitor, or picture-frame display |
| HDMI cable / adapter | Pi Zero 2 needs a mini-HDMI adapter; Pi 5 needs micro-HDMI |
| Power supply | Official Pi power supply recommended |
| WiFi network | 2.4 GHz or 5 GHz (Pi Zero 2 W and Pi 3 only support 2.4 GHz) |

### Software / services

| Service | What it does | Cost |
|---------|-------------|------|
| [Immich](https://immich.app) | Self-hosted photo library. Optional — you can use Google Photos instead. | Free, open-source |
| [Open-Meteo](https://open-meteo.com) | Provides weather data. NervesPhotos contacts it automatically — you do not need an account. | Free |

You need at least one photo source configured: an Immich album or a Google Photos shared album link.

---

## How it works

```
  Immich server / Google Photos    NervesPhotos device
  ┌──────────────────────┐         ┌──────────────────────┐
  │ Immich album(s)      │ ◄────── │                      │
  │ Google Photos albums │ ──────► │  Downloads photos    │
  └──────────────────────┘         │  Displays slideshow  │
                                   │  Shows weather       │
  Open-Meteo (internet)            │  Shows photo details │
  ┌──────────────┐                 └──────────────────────┘
  │ Weather API  │ ◄── polls every 15 min
  └──────────────┘
```

On boot, the device connects to your WiFi and starts downloading photos from all configured sources, merging them into a single shuffled pool. While it runs, it periodically updates the weather display and advances photos on the configured interval (default: 30 seconds).

---

## First-time setup

### Step 1 — Flash the SD card

You will receive (or build) a `.fw` firmware file. Flash it to your microSD card using one of these methods:

**macOS / Linux (command line):**
```
fwup nerves_photos.fw
```

**Any OS — graphical option:**
Use [Etcher](https://etcher.balena.io) and select the `.fw` file.

Insert the flashed card into your Pi.

---

### Step 2 — Connect the display and power on

1. Insert the SD card into the Pi.
2. Connect the HDMI cable between the Pi and your display.
3. Plug in the power supply.

The device will boot. If this is the first time (no WiFi configured), you will see a black screen — the display is running but waiting for you to complete setup.

---

### Step 3 — Connect to the setup access point

On a first boot with no WiFi credentials saved, the device automatically creates a WiFi network called **NervesPhotos-Setup**.

1. On your phone or laptop, open WiFi settings and connect to **NervesPhotos-Setup** (no password required).
2. Open a web browser and navigate to **http://192.168.4.1/settings**

---

### Step 4 — Configure WiFi

Fill in the **SSID** (your WiFi network name) and **Password** fields so the device can connect to your home network.

---

### Step 5 — Save and connect

Click **Save**. The device will:
1. Save all settings
2. Switch from the setup access point to your WiFi network
3. Begin polling for photo sources (you'll add these in Step 7)

Your phone/laptop will lose the `NervesPhotos-Setup` connection — switch back to your normal WiFi network.

---

### Step 6 — Create your admin account

After the device joins your WiFi, navigate to **http://nerves.local/settings** from any device on the same network. On the first visit with no users configured, you will be redirected to a sign-in page that shows an account creation form.

Enter a username and password (minimum 8 characters) to create the initial administrator account. After this, all access to `/settings` requires a login.

> **Note:** While the device is still in AP mode (NervesPhotos-Setup) and no users have been created, the settings page is accessible without a password. This bootstrap bypass ends once you create your first user.

---

### Step 7 — Add photo sources

Once logged in, add photo sources via the API from any device on the same network.

#### Add an Immich album

You need three pieces of information from your Immich installation:

**Server URL** — the address of your Immich server (e.g. `http://192.168.1.50:2283`)

**API Key** — from Immich → Account Settings → API Keys → New API Key. Enable at minimum `asset.read` and `asset.view` permissions.

**Album ID** — open the album in Immich and copy the UUID from the URL (`/albums/<uuid>`).

```bash
curl -X POST http://nerves.local/settings/photo_sources \
  -H "Content-Type: application/json" \
  -d '{"type":"immich","url":"http://192.168.1.10:2283","api_key":"your-key","album_id":"your-album-uuid"}'
```

#### Add a Google Photos shared album

1. In Google Photos, open the album you want to share
2. Click Share → Create link → copy the `https://photos.app.goo.gl/...` URL

```bash
curl -X POST http://nerves.local/settings/photo_sources \
  -H "Content-Type: application/json" \
  -d '{"type":"google_photos","share_url":"https://photos.app.goo.gl/yoursharelink"}'
```

> **Google Photos note:** NervesPhotos fetches the shared album page and extracts photo URLs. This is a best-effort approach — it may break if Google changes the share page format.

#### Manage existing sources

```bash
# List all configured sources (with their 0-based indexes)
curl http://nerves.local/settings/photo_sources

# Remove source at index 0
curl -X DELETE http://nerves.local/settings/photo_sources/0
```

Photos from all sources are merged into a single shuffled queue. The slideshow begins as soon as at least one source loads successfully.

> **If the device already has WiFi configured** (not a first boot), you can reach the settings page at `http://nerves.local/settings` from any device on the same network.

---

## Display overlays

```
┌─────────────────────────────────────────┐
│                                         │
│                                         │
│                                         │
│              [Photo fills               │
│               entire screen]            │
│                                         │
│                                         │
│ ┌──────────────────┐  ┌───────────────┐ │
│ │ June 12, 2023    │  │    72°F       │ │
│ │ Yosemite, USA    │  │  Clear Sky    │ │
│ └──────────────────┘  └───────────────┘ │
└─────────────────────────────────────────┘
```

**Bottom-left:** The date the photo was taken and the city/country where it was shot (if that information is stored in the photo's EXIF data by your camera or phone).

**Bottom-right:** Current temperature (Fahrenheit) and weather condition for your location. Updates every 15 minutes.

---

## Changing settings later

Navigate to **http://nerves.local/settings** from any device on the same WiFi network. You will need to log in. Changes take effect immediately — no reboot needed.

If `nerves.local` doesn't resolve, try the device's IP address instead. You can find it in your router's connected-devices list, or by SSH-ing in and running `VintageNet.info` in the IEx shell.

---

## User management

The **Users** section in the settings sidebar is visible to admin accounts only. From there you can:

- Add additional users with either the **admin** or **editor** role
- Change a user's role between admin and editor
- Delete users

**Roles:**
- **Admin** — full access: can manage photo sources (including delete), change all settings, and manage users
- **Editor** — can view and change settings and add photo sources, but cannot delete sources or manage users

---

## Web photo display

`GET /current` serves a full-screen HTML view of the current photo with overlays — the same layout shown on the physical display. It reloads automatically on each slide interval. This is useful for checking what the frame is showing from a browser without looking at the device.

`GET /current/photo` returns the raw JPEG bytes of the current photo.

Both routes are publicly accessible (no login required).

---

## Troubleshooting

### The display is black and the setup AP never appears

- Make sure the SD card is fully inserted and the correct card for your Pi model.
- Try a different power supply — underpowered supplies cause boot failures.
- Verify the HDMI cable is connected before powering on (the Pi detects the display at boot).
- Wait up to 60 seconds — the first boot can be slow.

---

### I can see the NervesPhotos-Setup AP but the settings page won't load

- Make sure your device fully connected to the `NervesPhotos-Setup` network (it may take a few seconds after joining).
- Try typing the address manually: **http://192.168.4.1/settings** (not https).
- Disable mobile data on your phone — some phones prefer cellular over the AP.

---

### Photos are not showing / screen says "Reconnecting..."

The device cannot reach one or more photo sources.

1. Make sure the Pi is on your WiFi (check the router).
2. For Immich sources: check that Immich is running — open it in your browser from another device.
3. For Immich sources: verify the Server URL is correct and uses `http://` (not `https://` unless you configured TLS).
4. For Immich sources: make sure your server allows connections from local network devices — check its Docker port mapping (`2283:2283` should be exposed).
5. The Pi and any Immich server must be on the same local network or reachable from the Pi's network.
6. For Google Photos sources: confirm the share link is still valid — open it in a browser to verify.

---

### Screen says "No photos found in album"

All configured sources returned empty results.

1. For Immich: open Immich and confirm the album has photos in it. Re-copy the Album ID from the URL — it is easy to accidentally copy an extra character.
2. For Google Photos: open the shared album link in a browser. If the album is empty or the link has been revoked, no photos will appear.
3. Confirm at least one photo source has been added: `curl http://nerves.local/settings/photo_sources`

---

### Weather shows "No weather data"

The device cannot reach the Open-Meteo API. This requires an internet connection (not just local network).

1. Confirm the Pi can reach the internet (it needs to connect to `api.open-meteo.com` on port 443).
2. If you entered a ZIP code in settings, try deleting it — a ZIP that doesn't geocode will cause this error. The IP-based fallback is more forgiving.
3. Weather will retry automatically every 15 minutes.

---

### The settings page shows WiFi as "Connecting..." but it never connects

1. Double-check the SSID spelling — WiFi network names are case-sensitive.
2. Confirm the password is correct.
3. The Pi Zero 2 W and Pi 3 only support **2.4 GHz** WiFi. If your network is 5 GHz only, the Pi won't connect.
4. If the device can't connect within 30 seconds, it falls back to AP mode so you can reconnect and fix the credentials.

---

### I forgot my password / can't log in

1. SSH into the device (if your SSH key was included at firmware build time): `ssh nerves.local`
2. In the IEx shell, delete all users to re-enter bootstrap mode:
   ```elixir
   NervesPhotos.UserStore.all()
   |> Enum.each(fn u -> NervesPhotos.UserStore.delete(u.username) end)
   ```
3. Navigate to **http://nerves.local/login** — with no users in the store, the login page shows the account creation form, allowing you to create a new admin account.

---

### I need to reset everything / start over

1. Connect to **NervesPhotos-Setup** (the device falls back to AP mode automatically if it can't connect to WiFi).
2. Open **http://192.168.4.1/settings** and correct the WiFi settings. Then re-add your photo sources via the API once back on the network.

If you need a complete factory reset, re-flash the SD card with the firmware image.

---

### SSH access (advanced)

If your SSH public key was included when the firmware was built, you can connect via:

```
ssh nerves.local
```

From the IEx shell you can inspect logs, check process state, and diagnose issues. See [docs/troubleshooting.md](troubleshooting.md) for a full list of IEx console commands.

---

## Privacy note

NervesPhotos makes the following outbound network connections:

| Destination | Purpose | Data sent |
|-------------|---------|-----------|
| Your Immich server (if configured) | Download photos | API key, album ID |
| Google Photos CDN (if configured) | Download photos | None (public shared album URLs) |
| `api.open-meteo.com` | Weather forecast | Your latitude/longitude |
| `ip-api.com` | IP geolocation (only if no ZIP set) | Your public IP address |

No data is sent to any other service. NervesPhotos has no cloud component and no analytics.

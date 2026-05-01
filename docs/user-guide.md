# NervesPhotos — User Guide

NervesPhotos turns a Raspberry Pi into a digital photo frame. It pulls photos from your self-hosted [Immich](https://immich.app) library and displays them in a full-screen slideshow on any HDMI monitor or TV. Current weather and photo details (date taken, location) appear as small overlays in the corners.

---

## What you need

### Hardware

| Item | Notes |
|------|-------|
| Raspberry Pi | Pi Zero W, Pi 3B/3B+, Pi 4, or Pi 5 |
| microSD card | 8 GB or larger |
| HDMI display | TV, monitor, or picture-frame display |
| HDMI cable / adapter | Pi Zero needs a mini-HDMI adapter; Pi 5 needs micro-HDMI |
| Power supply | Official Pi power supply recommended |
| WiFi network | 2.4 GHz or 5 GHz (Pi Zero only supports 2.4 GHz) |

### Software / services

| Service | What it does | Cost |
|---------|-------------|------|
| [Immich](https://immich.app) | Stores and organizes your photos. Must be self-hosted on your home network or a server you control. | Free, open-source |
| [Open-Meteo](https://open-meteo.com) | Provides weather data. NervesPhotos contacts it automatically — you do not need an account. | Free |

> **Immich must already be set up** before you can use NervesPhotos. See the [Immich installation guide](https://immich.app/docs/install/docker-compose) if you haven't done that yet.

---

## How it works

```
  Your Immich server                NervesPhotos device
  ┌──────────────┐                  ┌──────────────────────┐
  │              │  fetch album ──► │                      │
  │  Photo album │ ◄─ thumbnails ── │  Downloads photos    │
  │              │                  │  Displays slideshow  │
  └──────────────┘                  │  Shows weather       │
                                    │  Shows photo details │
  Open-Meteo (internet)             └──────────────────────┘
  ┌──────────────┐
  │ Weather API  │ ◄── polls every 15 min
  └──────────────┘
```

On boot, the device connects to your WiFi and starts displaying photos from the album you configured. It shuffles the album on each full cycle. While it runs, it periodically updates the weather display and advances photos on the configured interval (default: 30 seconds).

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

You should see the NervesPhotos settings page:

```
┌────────────────────────────────────┐
│       NervesPhotos Settings        │
│                                    │
│  IMMICH                            │
│  Server URL  [________________]    │
│  API Key     [________________]    │
│  Album ID    [________________]    │
│                                    │
│  WEATHER                           │
│  ZIP Code    [________________]    │
│                                    │
│  DISPLAY                           │
│  Slide interval (seconds)  [30]    │
│                                    │
│  WIFI                              │
│  SSID        [________________]    │
│  Password    [________________]    │
│                                    │
│         [      Save      ]         │
└────────────────────────────────────┘
```

---

### Step 4 — Configure Immich

You need three pieces of information from your Immich installation:

#### Server URL
The address of your Immich server on your local network. For example:
- `http://192.168.1.50:2283`
- `http://photos.home:2283`

This is the same address you use to open Immich in a browser.

#### API Key
1. In Immich, click your profile picture (top-right) → **Account Settings**
2. Scroll to **API Keys** → click **New API Key**
3. Give it a name (e.g. "NervesPhotos") and copy the key shown

#### Album ID
1. In Immich, open the album you want to display
2. Look at the URL in your browser — it will look like:
   `http://your-immich/albums/a1b2c3d4-e5f6-...`
3. Copy the long ID after `/albums/`

---

### Step 5 — Configure WiFi

Fill in the **SSID** (your WiFi network name) and **Password** fields so the device can connect to your home network.

---

### Step 6 — Save and connect

Click **Save**. The device will:
1. Save all settings
2. Switch from the setup access point to your WiFi network
3. Start downloading photos from Immich
4. Begin the slideshow within a few seconds

Your phone/laptop will lose the `NervesPhotos-Setup` connection — switch back to your normal WiFi network.

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

Navigate to **http://nerves.local/settings** from any device on the same WiFi network. Changes take effect immediately — no reboot needed.

If `nerves.local` doesn't resolve, try the device's IP address instead. You can find it in your router's connected-devices list, or by connecting a keyboard and running `ip addr show wlan0` in the IEx shell.

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

The device cannot reach your Immich server.

1. Make sure the Pi is on your WiFi (check the router).
2. Check that Immich is running — open it in your browser from another device.
3. Verify the Server URL in settings is correct and uses `http://` (not `https://` unless you configured TLS).
4. Make sure your Immich server allows connections from local network devices — check its Docker port mapping (`2283:2283` should be exposed).
5. The Pi and your Immich server must be on the same local network or the server must be reachable from the Pi's network.

---

### Screen says "No photos found in album"

The album exists in Immich but is empty, or the Album ID is wrong.

1. Open Immich and confirm the album has photos in it.
2. Re-copy the Album ID from the URL — it is easy to accidentally copy an extra character.

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
3. The Pi Zero and Pi 3 only support **2.4 GHz** WiFi. If your network is 5 GHz only, the Pi won't connect.
4. If the device can't connect within 30 seconds, it falls back to AP mode so you can reconnect and fix the credentials.

---

### I need to reset everything / start over

1. Connect to **NervesPhotos-Setup** (the device falls back to AP mode automatically if it can't connect to WiFi).
2. Open **http://192.168.4.1/settings** and correct the WiFi or Immich settings.

If you need a complete factory reset, re-flash the SD card with the firmware image.

---

### SSH access (advanced)

If your SSH public key was included when the firmware was built, you can connect via:

```
ssh nerves.local
```

From the IEx shell you can inspect logs (`RingLogger.next`), check WiFi status (`VintageNet.info`), and view current settings (`NervesPhotos.SettingsStore.all`).

---

## Privacy note

NervesPhotos makes the following outbound network connections:

| Destination | Purpose | Data sent |
|-------------|---------|-----------|
| Your Immich server | Download photos | API key, album ID |
| `api.open-meteo.com` | Weather forecast | Your latitude/longitude |
| `ip-api.com` | IP geolocation (only if no ZIP set) | Your public IP address |

No data is sent to any other service. NervesPhotos has no cloud component and no analytics.

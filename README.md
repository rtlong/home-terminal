# home-terminal

> **Vibe coded.** This entire project — from architecture to implementation to NixOS deployment config — was written with AI assistance (Claude). It works great. It is not an example of careful software engineering.

A full-screen household dashboard that runs permanently on a Raspberry Pi 4 mounted in the kitchen. It shows a 7-day Gantt-style calendar view with travel time overlays, integrates with Home Assistant for display power control, and computes sunrise/sunset/moon phase locally.

![screenshot placeholder]

## What it does

- **7-day Gantt calendar** — horizontal timeline, one day per row, events as colored bars. Timed events are positioned by start/end time; all-day events appear in the left gutter. Multiple household members get separate sub-rows per day.
- **Multi-source calendars** — fetches from Apple iCloud CalDAV (full 4-step PROPFIND/REPORT discovery) and arbitrary `.ics` feed URLs (e.g. shared Google Calendar links).
- **Travel time overlays** — calls the Google Maps Distance Matrix API to compute drive time from home to each event location. A tinted envelope extends the event bar leftward to show "leave by" time.
- **Sun/moon** — sunrise/sunset/moonrise/moonset and moon phase (emoji + illumination %) computed with pure math from configured lat/lon. Day/night gradient background on the timeline.
- **Home Assistant integration** — connects to an MQTT broker and registers as a HA device with `display_power` and `dark_mode` switches. Display on/off is executed via `swaymsg output <name> power on/off`.
- **Settings UI** — toggle calendar visibility, enable/disable travel time per calendar, assign calendars to people, configure person colors via a color-wheel picker.
- **Auto-reload** — if the WebSocket reconnects more than 3 seconds after page load (e.g. after a server restart), the browser reloads automatically.

## Tech stack

**Language:** [Gleam](https://gleam.run/) — statically typed functional language on the Erlang VM (BEAM). The whole thing is Gleam, including the UI.

**UI architecture:** [Lustre](https://hexdocs.pm/lustre/) server components — the Elm-architecture loop runs on the server and pushes HTML diffs over WebSocket. The browser runs only a tiny JS shim. No client-side JS build step.

**HTTP/WebSocket:** [Mist](https://hexdocs.pm/mist/) — pure Erlang HTTP server.

**MQTT:** [spoke_mqtt](https://hexdocs.pm/spoke_mqtt/) — Gleam MQTT client.

**CSS:** Tailwind CSS v4. Dynamic per-person/per-calendar colors use OKLCH inline styles (not Tailwind classes).

**Build/deployment:** [Nix](https://nixos.org/) + [nix-gleam](https://github.com/arnarg/nix-gleam) + Colmena for deploy to the Pi.

## Running locally

### Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- [direnv](https://direnv.net/) (optional but recommended)

### Setup

```sh
git clone https://github.com/rtlong/home-terminal
cd home-terminal
cp .env.example .env   # fill in your credentials
direnv allow           # or: nix develop
```

### Environment variables

| Variable | Description |
|---|---|
| `CALDAV_URL` | CalDAV server base URL (e.g. `https://caldav.icloud.com`) |
| `CALDAV_USERNAME` | CalDAV username |
| `CALDAV_PASSWORD` | CalDAV password (Apple: use an app-specific password) |
| `GOOGLE_MAPS_API_KEY` | Google Maps Distance Matrix + Geocoding API key |
| `MQTT_HOST` | MQTT broker hostname |
| `MQTT_USERNAME` | MQTT username |
| `MQTT_PASSWORD` | MQTT password |
| `DISPLAY_OUTPUT` | Wayland output name for display power (e.g. `HDMI-A-1`) |
| `DISPLAY_CONTROL_SCHEME` | `swaymsg`, `wlopm`, or `wlr-randr` |
| `PORT` | HTTP port (default: `46548`) |

### Run

```sh
overmind start   # runs gleam, tailwind watcher, and file watcher concurrently
```

Or individually:

```sh
gleam run        # starts the server on $PORT (default 46548)
```

Open `http://localhost:46546`.

On first run with a `home_address` configured in `~/.config/home-terminal/config.json`, the app will geocode it via Google Maps and write the coordinates back. Subsequent runs skip the geocode call.

## Configuration

Config lives at `$XDG_CONFIG_HOME/home-terminal/config.json` (default: `~/.config/home-terminal/config.json`).

The first time the app starts it writes a default config. You can then edit it to:

- Set your home address / lat-lon for sun/moon calculations
- Configure extra `.ics` feed URLs
- Assign calendars to people
- Adjust person hue angles

## Production deployment (NixOS / Raspberry Pi)

This repo is deployed to a Pi 4 via a private [infra repo](https://github.com/rtlong/infra) using [Colmena](https://github.com/zhaofengli/colmena). The NixOS module:

- Builds the Gleam app with `nix-gleam`'s `buildGleamApplication`, including a Tailwind CSS compile step
- Runs it as a systemd service under a dedicated `kiosk` user
- Uses `systemd LoadCredential` for secrets (no env-file needed)
- Runs [sway](https://swaywm.org/) as the Wayland compositor (via greetd) with Chromium in kiosk mode
- Uses a systemd path unit watching `$XDG_RUNTIME_DIR/sway.sock` to sequence startup (home-terminal waits for sway's IPC socket before starting, so display power control is ready immediately)

## Project structure

```
src/
├── home_terminal.gleam  — entry point
├── app.gleam            — HTTP server, WebSocket plumbing
├── tabs.gleam           — Lustre server component (per-connection UI state)
├── cal.gleam            — Gantt view rendering, sun/moon math (~2300 lines)
├── cal_server.gleam     — singleton actor: polls calendars, manages travel cache
├── cal_dav.gleam        — CalDAV HTTP client
├── ical.gleam           — iCalendar RFC 5545 parser (RRULE, EXDATE, TZID, etc.)
├── ical_fetch.gleam     — external .ics feed fetcher
├── ha_client.gleam      — Home Assistant MQTT actor
├── travel.gleam         — Google Maps Distance Matrix client
├── palette.gleam        — OKLCH color palette generation
├── state.gleam          — config/cache file I/O
└── ...                  — FFI modules for XML parsing, timezone conversion, signals
```

## License

MIT

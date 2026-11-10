# Outlander PHEV bridge

---

While you're here - check out [Amphora](https://getamphora.app) for checking your battery health on iOS.

---

Turns a Raspberry Pi into a bridge between a Mitsubishi Outlander PHEV and MQTT. The Pi
joins the car's "Remote Control" wifi hotspot with a second (USB) wifi adapter and runs
[phev2mqtt](https://github.com/buxtronix/phev2mqtt) with a few fixes. From MQTT the car
can go to Home Assistant (discovery is built in), Homebridge, or anything else.

It includes:
- a patched phev2mqtt build (see [Patches](#patches))
- a web page for status, car wifi, pairing and MQTT settings
- a watchdog that recovers the USB wifi adapter when its driver gets stuck
- a scheduled-preheat helper
- an installer that sets all of this up

## What you need

- A Raspberry Pi with built-in wifi (a Pi Zero W or Zero 2 W is enough).
- Raspberry Pi OS Bookworm or later, so NetworkManager. The Lite image is fine.
- The Pi already connected to your home network by its built-in wifi (or Ethernet).
- A **USB wifi adapter** for the car, plugged in but not configured. Pick one whose
  driver is in the kernel (e.g. MediaTek MT7601U or Realtek RTL8192EU). An adapter with
  an external aerial helps if the car is parked a long way from the Pi.
- An MQTT broker on your network.
- The car's hotspot name and password, from the label in the car.

## Installing

1. On a computer with this folder, run `./bundle.sh`. It writes `phev-bridge.tgz`.
2. Copy that to the Pi and unpack it: `tar xzf phev-bridge.tgz`.
3. Run the installer:
   ```bash
   cd phev-bridge && sudo ./install.sh
   ```
   In a terminal, it asks for the car hotspot and the MQTT broker. Press Enter to skip
   either and set it in the web page later. Or pass them as flags:
   ```bash
   sudo ./install.sh --car-ssid REMOTE12abcd --car-psk '…' \
       --mqtt-server 192.168.1.10 --mqtt-user '…' --mqtt-pass '…'
   ```
   `--dry-run` shows every change without making it, and `--help` lists all options.
4. Open `http://<pi>/`. Check that the broker connects, and choose the car hotspot if you
   skipped it.
5. Pair the Pi with the car: in the car, start "Setup Your Vehicle" (registration mode,
   see the car's Remote Control manual), then press **Pair with car** in the web page.
   The car allows a limited number of registered devices.

### What the installer does

- **Picks the car adapter:** the wifi interface that isn't carrying the default route,
  preferring a USB one, or `--car-iface`. If the main wifi has landed on the USB adapter
  (interface names follow probe order, so this can happen on first boot), it stops and
  prints the command to move the main wifi to the onboard radio.
- **Finds the adapter by MAC from then on.** It records the adapter's MAC in
  `/etc/phev-bridge.conf`, and the watchdog and web page look the adapter up by that MAC,
  since USB adapters can swap names between boots. The `car-remote` NetworkManager
  profile is pinned to the same MAC.
- **Pins the main wifi profile** to the onboard adapter's MAC, so it can't come up on the
  car adapter (`--no-pin-main-wifi` to skip). This takes effect from the next reconnect.
- **Sets up the car profile:**
  - retries forever, since the car comes and goes
  - a static address `192.168.8.47/24`, because some cars don't answer DHCP reliably
    (`--car-static-ip`, or `--car-dhcp` to use DHCP)
  - never takes the default route or DNS from the car
  - wifi power saving off
  - presents the adapter's own MAC, unless you pass `--clone-mac`
  - without a hotspot name, autoconnect stays off until you choose a network in the web page
- **Installs phev2mqtt** from `dist/`, checked against `dist/SHA256SUMS`. The 32-bit ARM
  build runs on every Pi with 32-bit or 64-bit OS, except probably a Pi 5. If
  `dist/phev2mqtt-linux-arm64` exists (`./build.sh` makes it), it's used on 64-bit OS.
- **Creates `/etc/phev2mqtt/env`** if it's missing, with raw register writes disabled
  (see [Settings](#settings)), and sets any MQTT options given.
- **Installs and enables** phev2mqtt, the web page, the watchdog timer, `phev-preheat` and
  persistent logging (50 MB, one month). It installs `iw` if needed.
- **Re-running it** upgrades changed files, restarts only what changed, and keeps
  existing settings. After swapping the car adapter, run it again: it warns that the MAC
  changed, so either pair again or use `--clone-mac <old MAC>` to keep the old
  registration (the car registers clients by MAC).

## Web page

`http://<pi>/` (port 80). From it you can:
- **Check the connections:** car wifi (network, signal, address), whether the car answers
  ping, whether phev2mqtt has a session with the car, and both broker connections.
- **See the latest car data:** key values, plus every topic and how long ago it changed.
  "Retained" means the value came from the broker's store, not a live update.
- **Manage the car wifi:** Reconnect, Reset dongle (reloads the driver), and Search for
  networks then Connect.
- **Pair** with the car. This stops phev2mqtt, runs `phev2mqtt client register` for up to
  2 minutes, then starts phev2mqtt again. The button works once the car wifi is connected.
- **Restart phev2mqtt.**
- **Change the MQTT settings:** server, username, password and topic prefix. **Test**
  tries a login, and **Save** only goes ahead if that works. A blank password keeps the
  saved one. Plain MQTT (`tcp://`) only.
- **Read the recent log** of phev2mqtt, the watchdog and the web page.

The page has **no login**: anyone on your network can use it. It only accepts
`application/json` POSTs, which stops other web pages triggering actions from a browser.
It runs as root, because it drives nmcli, modprobe and systemctl. Its log is
`journalctl -u phev-web`.

## MQTT

### Topics (default prefix `phev`)

| Kind | Topics |
|---|---|
| Status | `phev/battery/…`, `phev/charge/…`, `phev/climate/…`, `phev/door/…`, `phev/lights/…`, `phev/available` (online/offline), `phev/vin`, `phev/registrations` |
| Commands | `phev/set/climate/…`, `phev/set/headlights`, `phev/set/parkinglights`, `phev/set/cancelchargetimer`, `phev/set/connection` (on / off / restart) |

Home Assistant discovery messages are published under `homeassistant/`
(`HA_DISCOVERY=false` turns them off).

**Car data is retained,** so a new subscriber gets the last known state straight away.
The car sends a full snapshot when phev2mqtt connects, then changes, plus a refresh
every 5 minutes (`UPDATE_INTERVAL`). When the car is out of range these values are its
last known state: check `phev/available` to know whether they're current.

`phev/available`:
- is set to `offline` by a retained last-will message if the Pi or the service dies
- goes `offline` once when the car has been unreachable for more than 30 s
- goes `online` once after connecting to the car
- is published again after a broker reconnect

### Sending commands

Publish a plain-text payload. **Don't set retain**: a retained command is replayed every
time phev2mqtt reconnects.

| Action | Topic | Payload |
|---|---|---|
| Headlights | `phev/set/headlights` | `on` / `off` |
| Parking lights | `phev/set/parkinglights` | `on` / `off` |
| Preheat | `phev/set/climate/heat` | `10` / `20` / `30` (minutes), `on` (= 10), `off` |
| Pre-cool / windscreen | `phev/set/climate/cool`, `phev/set/climate/windscreen` | same as heat |
| Clear a terminated run | `phev/set/climate/state` | `reset` |
| Drop / restore the car connection | `phev/set/connection` | `off` / `on` / `restart` |

`phev/charge/plug` shows whether the charger is **live**, not whether the cable is in.
With the cable connected but the supply off, the car reports `unplugged`, and preheat
runs from the car's battery.

To watch the topics from another computer, use any MQTT client (e.g. MQTT Explorer or
`mosquitto_sub`), or the dependency-free [`tools/mqttsub.py`](tools/mqttsub.py):
```bash
MQTT_USERNAME=… MQTT_PASSWORD=… python3 tools/mqttsub.py 192.168.1.10 'phev/#' 10
```

## Scheduled preheat

`/usr/local/sbin/phev-preheat [--dry-run] [10|20|30]` waits for `phev/available` to be
`online`, sends the preheat command and waits for the car to confirm it. It retries every
30 s for up to 20 minutes (at most 3 sends) and logs to `journalctl -t phev-preheat`.

To schedule a one-off run:
```bash
sudo systemd-run --unit=phev-preheat-YYYYMMDD-HHMM --on-calendar="YYYY-MM-DD HH:MM:00" \
  --timer-property=AccuracySec=1s /usr/local/sbin/phev-preheat 30
systemctl list-timers 'phev-preheat-*'
```
This only works if the car's hotspot is awake at that time (see below). The car's own
climate timer, set in Mitsubishi's app, doesn't depend on the hotspot.

## Settings

phev2mqtt reads `/etc/phev2mqtt/env` (root-only). Any command-line flag can be set there
as an uppercase variable, e.g. `--update_interval` becomes `UPDATE_INTERVAL`. The web
page and `phev-preheat` read the same file. After editing it by hand, run
`sudo systemctl restart phev2mqtt`.

`MQTT_DISABLE_REGISTER_SET_COMMAND=true` is set by default. It turns off
`phev/set/register/…`, which writes arbitrary values to the car's remote-control module.
The protocol is reverse-engineered and many registers are unknown, and any client on the
broker could publish to it. The normal controls don't need it. To allow it, delete the
line and restart phev2mqtt.

The car is expected at `192.168.8.46:8080` (`ADDRESS`).

## The car's hotspot and the adapter watchdog

Things to know:
- **The hotspot goes to sleep** about an hour after the car is parked, even while
  phev2mqtt is connected. It comes back later.
- **The car serves one app session at a time.** While the phone app is connected,
  phev2mqtt can't talk to the car (`timed out waiting for start`). Close the phone app if
  the Pi needs the car.
- **USB wifi drivers can get stuck,** often when the hotspot disappears. Reloading the
  driver fixes it. The ways seen so far:
  - scans return nothing at all
  - the car's hotspot is visible but every join times out
  - it stays "connected", but no data arrives from the car
- **A join the car cuts off mid-handshake** fails as `no-secrets`, and NetworkManager then
  stops autoconnecting the profile until it's brought up by hand.

The watchdog (`wlan1-watchdog.timer`, every 5 minutes) handles these:
- Connected, and the car answers ping: nothing to do.
- Connected, but the car doesn't answer 5 pings: reload the driver.
- Not connected, and a scan finds other networks but not the car: the car is just away.
- Not connected, and a scan finds nothing (after one retry): reload the driver.
- Not connected, but the car's hotspot is visible: bring the profile up by hand. If that
  still fails on the next check too, reload the driver.

It does nothing while pairing is running. Its actions are logged to
`journalctl -t wlan1-watchdog`. (The name is historical: the car adapter needn't be
`wlan1`.)

One gap: NetworkManager can keep reporting "connected" for a while after the link has
gone, and the watchdog only steps in once NetworkManager notices.

## Troubleshooting

- **Car wifi status:** `nmcli device` and `nmcli connection show car-remote`.
- **phev2mqtt log:** `journalctl -fu phev2mqtt -o cat`.
- **Pairing by hand:** stop phev2mqtt first, so the two don't compete for the car:
  ```bash
  sudo systemctl stop phev2mqtt
  sudo phev2mqtt client register
  sudo systemctl start phev2mqtt
  ```
- **After a reboot, phev2mqtt's first attempt can hang** for about 2 minutes if it starts
  before the car wifi is up. It recovers by itself.
- **Moving the SD card to another Pi:** the main wifi profile is pinned to the old
  board's MAC, so the Pi won't join your network until it's re-pinned. From a screen and
  keyboard:
  ```bash
  sudo nmcli connection modify '<main profile>' 802-11-wireless.mac-address "$(cat /sys/class/net/wlan0/address)"
  sudo nmcli connection up '<main profile>'
  ```
  `nmcli connection show` lists the profile names. On netplan-based systems the `modify`
  can take a minute.
- **SD card errors** (`command (18) not complete` in `dmesg`): check the power supply
  first, then the card. Adding `dtoverlay=sdtweak,overclock_50=25` to
  `/boot/firmware/config.txt` sometimes helps.

## Patches

phev2mqtt is built from upstream commit `8f42340` plus the fixes in [`patches/`](patches/):
- **0001:** upstream's `mqtt_disable_register_set_command` stops subscribing to
  `phev/set/#` altogether, which silently disables every command. With the patch it
  always subscribes, and the flag only ignores `phev/set/register/…`.
- **0002:**
  - car data is published retained
  - `phev/available` is published only when it changes
  - command subscriptions are redone on every broker reconnect (upstream subscribed once,
    so commands stopped working after any broker reconnect)

## Building phev2mqtt

`./build.sh` (or `GO=/path/to/go ./build.sh`) clones upstream, applies `patches/`, and
writes `dist/phev2mqtt-linux-armv6`, `dist/phev2mqtt-linux-arm64` and `dist/SHA256SUMS`.
It needs Go and about 1 GB of free disk. Then bundle and re-run `install.sh` on the Pi.

## Files

| In this folder | Installed as |
|---|---|
| `dist/phev2mqtt-linux-*` | `/usr/local/bin/phev2mqtt` |
| `pi/phev2mqtt.service` | `/etc/systemd/system/phev2mqtt.service` (runs as a dynamic user, sandboxed) |
| `pi/phev-web`, `pi/phev-web.html`, `pi/phev-web.service` | `/usr/local/sbin/phev-web`, `/usr/local/share/phev-web/`, `/etc/systemd/system/` |
| `pi/wlan1-watchdog`, `.service`, `.timer` | `/usr/local/sbin/wlan1-watchdog`, `/etc/systemd/system/` |
| `pi/phev-preheat` | `/usr/local/sbin/phev-preheat` |
| `pi/journald-persistent.conf` | `/etc/systemd/journald.conf.d/50-persistent.conf` |
| (written by the installer) | `/etc/phev-bridge.conf`, `/etc/phev2mqtt/env` |

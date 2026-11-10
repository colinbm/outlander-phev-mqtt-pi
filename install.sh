#!/bin/bash
# Install (or upgrade) the Outlander PHEV bridge on a Raspberry Pi.
#
# Assumes Raspberry Pi OS (Bookworm or later, so NetworkManager), already on the main
# network, with a second wifi adapter plugged in for the car's hotspot. Copy this whole
# folder to the Pi and run:   sudo ./install.sh        (see --help)
#
# Safe to re-run: it upgrades files in place and keeps existing settings unless you pass
# new ones.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Anything not given here can be set afterwards in the web page (http://<pi>/).
When run in a terminal, it asks for the car hotspot and MQTT broker if they aren't
set yet (press Enter to skip).

Car wifi:
  --car-iface IFACE      the adapter to use for the car (default: the one wifi
                         interface that isn't the main connection)
  --car-ssid SSID        the car's hotspot name (on the label, e.g. REMOTE12abcd)
  --car-psk PASSWORD     the car's hotspot password
  --car-static-ip CIDR   the Pi's address on the car network (default 192.168.8.47/24;
                         some cars don't answer DHCP reliably)
  --car-dhcp             ask the car for an address instead
  --clone-mac MAC        present this MAC to the car, e.g. to keep a registration
                         made with a different adapter

MQTT broker:
  --mqtt-server HOST[:PORT]
  --mqtt-user USER
  --mqtt-pass PASSWORD
  --mqtt-prefix PREFIX   topic prefix (default phev)

Other:
  --no-pin-main-wifi     don't pin the main wifi profile to the onboard adapter's MAC
  --yes                  don't ask questions
  --dry-run              show what would change without changing anything
  -h, --help
EOF
}

DRY_RUN=0 ASSUME_YES=0 PIN_MAIN=1
CAR_IFACE= CAR_SSID= CAR_PSK= CAR_STATIC=192.168.8.47/24 CLONE_MAC=
MQTT_SERVER= MQTT_USER= MQTT_PASS= MQTT_PREFIX=
SET_MQTT_USER=0 SET_MQTT_PASS=0
PROFILE=car-remote
CAR_IP=192.168.8.46
CONF=/etc/phev-bridge.conf
ENV_FILE=/etc/phev2mqtt/env

while (( $# )); do
    case $1 in
        --car-iface) CAR_IFACE=$2; shift ;;
        --car-ssid) CAR_SSID=$2; shift ;;
        --car-psk) CAR_PSK=$2; shift ;;
        --car-static-ip) CAR_STATIC=$2; shift ;;
        --car-dhcp) CAR_STATIC= ;;
        --clone-mac) CLONE_MAC=$2; shift ;;
        --mqtt-server) MQTT_SERVER=$2; shift ;;
        --mqtt-user) MQTT_USER=$2; SET_MQTT_USER=1; shift ;;
        --mqtt-pass) MQTT_PASS=$2; SET_MQTT_PASS=1; shift ;;
        --mqtt-prefix) MQTT_PREFIX=$2; shift ;;
        --no-pin-main-wifi) PIN_MAIN=0 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Run a command that changes something; in --dry-run just print it (secrets masked).
run() {
    if (( DRY_RUN )); then
        local out=() a
        for a in "$@"; do
            if [[ -n "$a" && ( "$a" == "$CAR_PSK" || "$a" == "$MQTT_PASS" ) ]]; then a='***'; fi
            out+=("$(printf '%q' "$a")")
        done
        printf '    [dry-run] %s\n' "${out[*]}"
    else
        "$@"
    fi
}

CHANGED=()   # files that changed, to know what to restart
install_file() {   # install_file SRC DEST MODE
    local src=$HERE/$1 dest=$2 mode=$3
    [[ -f "$src" ]] || die "missing $1 (copy the whole folder to the Pi)"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        return
    fi
    note "${dest} ($( [[ -f "$dest" ]] && echo updated || echo new))"
    run install -D -m "$mode" "$src" "$dest"
    CHANGED+=("$dest")
}
changed() { local f; for f in "${CHANGED[@]}"; do [[ "$f" == "$1" ]] && return 0; done; return 1; }

set_env() {   # set_env KEY VALUE: set one line of the env file, keeping the rest
    local k=$1 v=$2
    if [[ -f "$ENV_FILE" ]] && grep -qxF "$k=$v" "$ENV_FILE"; then
        return
    fi
    note "$ENV_FILE: $k=$([[ $k == MQTT_PASSWORD ]] && echo '***' || echo "$v")"
    CHANGED+=("$ENV_FILE")
    (( DRY_RUN )) && return
    if ! (umask 077
          K=$k V=$v awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
            index($0, k "=") == 1 { print k "=" v; done = 1; next } { print }
            END { if (!done) print k "=" v }' "$ENV_FILE" > "$ENV_FILE.new" &&
          chmod 600 "$ENV_FILE.new" && mv "$ENV_FILE.new" "$ENV_FILE"); then
        rm -f "$ENV_FILE.new"
        die "couldn't update $ENV_FILE (is the disk full or read-only?). Nothing is started yet; fix that and run this again."
    fi
}

# The adapter's own MAC; while NetworkManager clones another onto it, ip shows it as permaddr.
perm_mac() {
    local line
    line=$(ip -o link show dev "$1")
    if [[ "$line" =~ permaddr\ ([0-9a-fA-F:]{17}) ]] || [[ "$line" =~ link/ether\ ([0-9a-fA-F:]{17}) ]]; then
        echo "${BASH_REMATCH[1]^^}"
    fi
}
iface_for_mac() {
    local d
    for d in /sys/class/net/*; do
        [[ "$(perm_mac "${d##*/}")" == "${1^^}" ]] && { echo "${d##*/}"; return; }
    done
}
is_wifi() { [[ -d "/sys/class/net/$1/wireless" || -e "/sys/class/net/$1/phy80211" ]]; }
# A USB adapter (rather than the onboard radio, which sits on SDIO/PCIe). The car is often
# further away than the router, and a USB adapter can have a bigger aerial.
is_usb()  { [[ "$(readlink -f "/sys/class/net/$1/device" 2>/dev/null)" == */usb* ]]; }

# --- checks ------------------------------------------------------------------
(( EUID == 0 )) || die "run with sudo: sudo $0 $*"
(( DRY_RUN )) && say "Dry run: nothing will be changed"

command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager ||
    die "NetworkManager isn't running. This needs Raspberry Pi OS Bookworm or later."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null ||
    die "python3 3.9 or later is needed"

case $(uname -m) in
    armv6l|armv7l) BIN=dist/phev2mqtt-linux-armv6 ;;
    aarch64)
        if [[ $(dpkg --print-architecture) == arm64 && -f "$HERE/dist/phev2mqtt-linux-arm64" ]]; then
            BIN=dist/phev2mqtt-linux-arm64
        else
            BIN=dist/phev2mqtt-linux-armv6
            [[ $(dpkg --print-architecture) == arm64 ]] &&
                warn "no 64-bit phev2mqtt in dist/ (run ./build.sh); using the 32-bit one, which needs the kernel's 32-bit support (fine on Pi 3/4/Zero 2, not on Pi 5)"
        fi ;;
    *) die "unsupported CPU $(uname -m); this is for a Raspberry Pi" ;;
esac
[[ -f "$HERE/$BIN" ]] || die "missing $BIN; run ./build.sh on a machine with Go"
if [[ -f "$HERE/dist/SHA256SUMS" ]] && grep -q " ${BIN##*/}\$" "$HERE/dist/SHA256SUMS"; then
    (cd "$HERE/dist" && grep " ${BIN##*/}\$" SHA256SUMS | sha256sum -c --quiet -) ||
        die "$BIN doesn't match dist/SHA256SUMS; copy it again"
fi

# --- which adapter is which ----------------------------------------------------
MAIN_IFACE=$(ip route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
[[ -n "$MAIN_IFACE" ]] || die "no default route; connect the Pi to your main network first"

OLD_MAC=
[[ -r $CONF ]] && OLD_MAC=$(sed -n 's/^CAR_MAC=//p' "$CONF" | tr -d "'\"")
if [[ -n "$CAR_IFACE" ]]; then
    [[ -e /sys/class/net/$CAR_IFACE ]] || die "--car-iface $CAR_IFACE doesn't exist (see: ip link)"
    is_wifi "$CAR_IFACE" || die "$CAR_IFACE isn't a wifi adapter"
elif [[ -n "$OLD_MAC" && -n "$(iface_for_mac "$OLD_MAC")" ]]; then
    CAR_IFACE=$(iface_for_mac "$OLD_MAC")
else
    candidates=()
    for d in /sys/class/net/*; do
        i=${d##*/}
        is_wifi "$i" && [[ "$i" != "$MAIN_IFACE" ]] && candidates+=("$i")
    done
    (( ${#candidates[@]} )) ||
        die "no second wifi adapter found. Plug it in, check it shows in 'ip link', then run this again."
    if is_wifi "$MAIN_IFACE" && is_usb "$MAIN_IFACE"; then
        # Interface names follow probe order, so on first boot the USB adapter can get
        # wlan0 and with it the main wifi profile. The car needs the USB adapter more.
        main_con=$(nmcli -g GENERAL.CONNECTION device show "$MAIN_IFACE" 2>/dev/null || true)
        onboard= onboard_mac='<onboard MAC>'
        for i in "${candidates[@]}"; do is_usb "$i" || { onboard=$i; onboard_mac=$(perm_mac "$i"); break; }; done
        die "the main wifi is on the USB adapter ($MAIN_IFACE), which should be kept for the car.
       Move the main wifi to the onboard radio${onboard:+ ($onboard)}, reboot, and run this again:
         sudo nmcli connection modify '${main_con:-<main profile>}' connection.interface-name '' 802-11-wireless.mac-address $onboard_mac
       Or, to use ${candidates[0]} for the car anyway: --car-iface ${candidates[0]}"
    fi
    if (( ${#candidates[@]} > 1 )); then
        usb=()
        for i in "${candidates[@]}"; do is_usb "$i" && usb+=("$i"); done
        (( ${#usb[@]} == 1 )) ||
            die "several spare wifi adapters (${candidates[*]}); choose one with --car-iface"
        candidates=("${usb[@]}")
    fi
    CAR_IFACE=${candidates[0]}
    is_usb "$CAR_IFACE" ||
        warn "$CAR_IFACE is the onboard radio, not a USB adapter; range to the car may be short"
fi
[[ "$CAR_IFACE" != "$MAIN_IFACE" ]] ||
    die "$CAR_IFACE carries the main connection; the car needs a separate adapter"
CAR_MAC=$(perm_mac "$CAR_IFACE")
[[ -n "$CAR_MAC" ]] || die "couldn't read the MAC of $CAR_IFACE"
DRIVER=$(basename "$(readlink -f "/sys/class/net/$CAR_IFACE/device/driver" 2>/dev/null)" 2>/dev/null || true)
say "Main connection: $MAIN_IFACE   Car adapter: $CAR_IFACE ($CAR_MAC, driver ${DRIVER:-unknown})"
[[ -n "$OLD_MAC" && "${OLD_MAC^^}" != "$CAR_MAC" ]] &&
    warn "the car adapter changed from $OLD_MAC. If the car was paired with the old one, pair again or use --clone-mac $OLD_MAC"

PROFILE_EXISTS=0
nmcli -g NAME connection show | grep -qxF "$PROFILE" && PROFILE_EXISTS=1
OLD_SSID=
(( PROFILE_EXISTS )) && OLD_SSID=$(nmcli -g 802-11-wireless.ssid connection show "$PROFILE")
[[ "$OLD_SSID" == unset ]] && OLD_SSID=
OLD_SERVER=
[[ -f "$ENV_FILE" ]] && OLD_SERVER=$(sed -n 's/^MQTT_SERVER=//p' "$ENV_FILE")

# --- questions (only in a terminal, only for things not set yet) ----------------
if [[ -t 0 ]] && (( ! ASSUME_YES )); then
    if [[ -z "$CAR_SSID" && -z "$OLD_SSID" ]]; then
        read -rp "Car hotspot name, from the label in the car (Enter to set it later): " CAR_SSID
        [[ -n "$CAR_SSID" && -z "$CAR_PSK" ]] && { read -rsp "Car hotspot password: " CAR_PSK; echo; }
    fi
    if [[ -z "$MQTT_SERVER" && -z "$OLD_SERVER" ]]; then
        read -rp "MQTT broker host[:port] (Enter to set it later): " MQTT_SERVER
        if [[ -n "$MQTT_SERVER" ]]; then
            (( SET_MQTT_USER )) || { read -rp "MQTT username (Enter for none): " MQTT_USER; SET_MQTT_USER=1; }
            (( SET_MQTT_PASS )) || { read -rsp "MQTT password (Enter for none): " MQTT_PASS; echo; SET_MQTT_PASS=1; }
        fi
    fi
fi

# --- packages --------------------------------------------------------------------
missing=()
command -v iw >/dev/null || missing+=(iw)
command -v ping >/dev/null || missing+=(iputils-ping)
if (( ${#missing[@]} )); then
    say "Installing ${missing[*]}"
    # A fresh image may have stale or empty package lists; update only if needed.
    run apt-get install -y "${missing[@]}" ||
        { run apt-get update && run apt-get install -y "${missing[@]}"; } ||
        die "couldn't install ${missing[*]}; check the Pi can reach the internet"
fi

# --- phev2mqtt ---------------------------------------------------------------------
say "phev2mqtt"
if [[ -f /usr/local/bin/phev2mqtt ]] && ! cmp -s "$HERE/$BIN" /usr/local/bin/phev2mqtt; then
    run cp -p /usr/local/bin/phev2mqtt /usr/local/bin/phev2mqtt.prev
fi
install_file "$BIN" /usr/local/bin/phev2mqtt 755
install_file pi/phev2mqtt.service /etc/systemd/system/phev2mqtt.service 644

if [[ ! -f "$ENV_FILE" ]]; then
    note "$ENV_FILE (new)"
    run install -d -m 755 /etc/phev2mqtt
    # Raw register writes reach the car's remote-control module directly; see README.
    (( DRY_RUN )) || (umask 077; echo "MQTT_DISABLE_REGISTER_SET_COMMAND=true" > "$ENV_FILE") ||
        die "couldn't create $ENV_FILE (is the disk full or read-only?)"
    CHANGED+=("$ENV_FILE")
fi
if [[ -n "$MQTT_SERVER" ]]; then
    s=${MQTT_SERVER#*://}
    [[ "$s" == *:* ]] || s="$s:1883"
    set_env MQTT_SERVER "tcp://$s"
fi
(( SET_MQTT_USER )) && set_env MQTT_USERNAME "$MQTT_USER"
(( SET_MQTT_PASS )) && set_env MQTT_PASSWORD "$MQTT_PASS"
[[ -n "$MQTT_PREFIX" ]] && set_env MQTT_TOPIC_PREFIX "$MQTT_PREFIX"

# --- bridge config read by the watchdog and the web page ----------------------------
NEW_CONF="# Written by install.sh. The car adapter is found by its own MAC, since
# interface names can change between boots.
CAR_MAC=$CAR_MAC
CAR_PROFILE=$PROFILE
CAR_IP=$CAR_IP
"
if [[ "$(cat "$CONF" 2>/dev/null)" != "${NEW_CONF%$'\n'}" ]]; then
    note "$CONF"
    (( DRY_RUN )) || printf '%s' "$NEW_CONF" > "$CONF"
    CHANGED+=("$CONF")
fi

# --- car wifi profile ------------------------------------------------------------------
say "Car wifi profile '$PROFILE'"
if (( ! PROFILE_EXISTS )); then
    # Created with autoconnect off: the modify below adds the password and MAC pin and only
    # then turns it on. A half-made profile that tries to join fails as "no-secrets", and
    # NetworkManager then stops autoconnecting it.
    run nmcli connection add type wifi con-name "$PROFILE" ssid "${CAR_SSID:-unset}" \
        connection.autoconnect no 802-11-wireless.cloned-mac-address permanent
fi
# Pinned to the adapter's MAC rather than its name; retry forever since the car comes
# and goes; never take the default route or DNS from the car.
args=(connection.interface-name "" 802-11-wireless.mac-address "$CAR_MAC"
      connection.autoconnect-retries 0 802-11-wireless.powersave 2
      ipv4.never-default yes ipv4.ignore-auto-dns yes ipv4.route-metric 900 ipv6.method ignore)
if [[ -n "$CAR_STATIC" ]]; then
    args+=(ipv4.method manual ipv4.addresses "$CAR_STATIC" ipv4.gateway "")
else
    args+=(ipv4.method auto ipv4.addresses "")
fi
if [[ -n "$CAR_SSID" ]]; then
    args+=(802-11-wireless.ssid "$CAR_SSID" connection.autoconnect yes)
fi
[[ -n "$CAR_PSK" ]] && args+=(wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$CAR_PSK")
[[ -n "$CLONE_MAC" ]] && args+=(802-11-wireless.cloned-mac-address "${CLONE_MAC^^}")
run nmcli connection modify "$PROFILE" "${args[@]}"
note "network: ${CAR_SSID:-${OLD_SSID:-not set yet (choose it in the web page)}}"
note "address: ${CAR_STATIC:-DHCP}; car expected at $CAR_IP"

# --- main wifi -----------------------------------------------------------------------------
# A USB adapter can come up as wlan0 and the onboard one as wlan1. Pinning the main
# profile to the onboard adapter's MAC stops it landing on the car adapter.
if (( PIN_MAIN )) && is_wifi "$MAIN_IFACE" && ! is_usb "$MAIN_IFACE"; then
    MAIN_CON=$(nmcli -g GENERAL.CONNECTION device show "$MAIN_IFACE")
    MAIN_MAC=$(perm_mac "$MAIN_IFACE")
    # nmcli -g escapes the colons in a MAC as \:
    if [[ -n "$MAIN_CON" && -n "$MAIN_MAC" &&
          "$(nmcli -g 802-11-wireless.mac-address connection show "$MAIN_CON" | tr -d '\\')" != "$MAIN_MAC" ]]; then
        say "Pinning main wifi profile '$MAIN_CON' to $MAIN_MAC (applies from the next reconnect)"
        run nmcli connection modify "$MAIN_CON" 802-11-wireless.mac-address "$MAIN_MAC"
    fi
fi

# --- web page, watchdog, preheat, logging -------------------------------------------------
say "Services and scripts"
install_file pi/phev-web /usr/local/sbin/phev-web 755
install_file pi/phev-web.html /usr/local/share/phev-web/phev-web.html 644
install_file pi/phev-web.service /etc/systemd/system/phev-web.service 644
install_file pi/wlan1-watchdog /usr/local/sbin/wlan1-watchdog 755
install_file pi/wlan1-watchdog.service /etc/systemd/system/wlan1-watchdog.service 644
install_file pi/wlan1-watchdog.timer /etc/systemd/system/wlan1-watchdog.timer 644
install_file pi/phev-preheat /usr/local/sbin/phev-preheat 755
install_file pi/journald-persistent.conf /etc/systemd/journald.conf.d/50-persistent.conf 644

run systemctl daemon-reload
if changed /etc/systemd/journald.conf.d/50-persistent.conf; then
    run mkdir -p /var/log/journal
    run systemctl restart systemd-journald
fi
run systemctl enable --quiet phev2mqtt.service phev-web.service wlan1-watchdog.timer
run systemctl start wlan1-watchdog.timer
if changed /usr/local/bin/phev2mqtt || changed /etc/systemd/system/phev2mqtt.service || changed "$ENV_FILE"; then
    run systemctl restart phev2mqtt
else
    run systemctl start phev2mqtt
fi
if changed /usr/local/sbin/phev-web || changed /usr/local/share/phev-web/phev-web.html ||
   changed /etc/systemd/system/phev-web.service || changed "$CONF" || changed "$ENV_FILE"; then
    run systemctl restart phev-web
else
    run systemctl start phev-web
fi
(( ${#CHANGED[@]} )) || note "everything was already up to date"

# --- done ------------------------------------------------------------------------------------
IP=$(ip -4 -o addr show dev "$MAIN_IFACE" | awk '{ split($4, a, "/"); print a[1]; exit }')
echo
say "Done. Web page: http://${IP:-<pi address>}/"
cat <<EOF
    Next:
    1. In the web page, set the MQTT broker if you haven't, and check that it connects.
    2. With the car nearby, choose its hotspot under "Car wifi" if you haven't, then wait
       for "Car wifi" to go green.
    3. If this adapter isn't paired with the car yet: in the car, start "Setup Your
       Vehicle" (registration mode), then press "Pair with car" in the web page.
EOF

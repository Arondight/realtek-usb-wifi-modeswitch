#!/usr/bin/env bash
#
# realtek-usb-wifi-modeswitch - Linux helper for Realtek USB Wi-Fi adapters
# that come up as a CD-ROM ("driver installer") device and must be switched
# to Wi-Fi mode.
#
# Many low-cost Realtek USB Wi-Fi dongles (RTL8192FU, RTL8821CU, RTL8811CU,
# RTL8822BU, RTL8822CU, ...) enumerate as a USB CD-ROM drive when first
# plugged in, so that Windows can auto-run the bundled driver. Linux only
# sees the fake CD-ROM; the Wi-Fi function stays hidden until the device is
# told to switch modes.
#
# This script:
#   1. detects Realtek USB devices that are stuck in CD-ROM mode
#   2. switches them to Wi-Fi mode (usb_modeswitch, SCSI eject as fallback)
#   3. finds a kernel module that claims the device's Wi-Fi USB ID and loads it
#   4. detects and repairs bindings to the wrong driver
#   5. optionally installs a udev rule so the switch happens on every plug-in
#   6. verifies that a wireless interface showed up
#
# Copyright (c) 2026 秦凡东 (shell_way@foxmail.com)
# SPDX-License-Identifier: MIT
#
set -uo pipefail

readonly PROG="modeswitch"
readonly PROJECT="realtek-usb-wifi-modeswitch"
readonly VERSION="1.0.0"

readonly PROJECT_URL="https://github.com/Arondight/realtek-usb-wifi-modeswitch"

SELF="$0"

# ===========================================================================
# Device database
# ===========================================================================

readonly RT_VENDOR="0bda"

# Standard vendor-specific message used by most Realtek install-mode devices.
readonly DEFAULT_MSG='5553424312345678000000000000061e000000000000000000000000000000'

# Known CD-ROM-mode ("ZeroCD", "Driver CDROM Mode") product IDs. These two
# are the only Realtek IDs registered both in the Linux kernel
# (drivers/usb/storage/unusual_devs.h) and in usb-modeswitch upstream; all
# other Realtek ZeroCD devices found in the wild report one of them too.
# Format: "<pid>:<message|->:<chip>"; a message of "-" means DEFAULT_MSG.
readonly CD_PIDS=(
    "1a2b:-:RTL8188GU / RTL8821CU / RTL8852x"
    "a192:-:RTL8192FU / RTL8832BU"
)

# Configuration written by this tool.
readonly UDEV_RULE="/etc/udev/rules.d/99-realtek-usb-wifi-modeswitch.rules"
readonly BLACKLIST_FILE="/etc/modprobe.d/realtek-usb-wifi-modeswitch-blacklist.conf"
readonly USB_STORAGE_QUIRK_FILE="/etc/modprobe.d/realtek-usb-wifi-modeswitch-usb-storage.conf"

# Files left behind by older third-party scripts (reported, never removed).
readonly LEGACY_UDEV="/etc/udev/rules.d/99-rtl8821cu-modeswitch.rules"
readonly LEGACY_BLACKLIST="/etc/modprobe.d/8821cu.conf"

# ===========================================================================
# Output helpers
# ===========================================================================

C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_CYAN=""
C_BOLD=""
C_RESET=""

setup_colors() {
    local enable=0
    case "$OPT_COLOR" in
        always) enable=1 ;;
        never) enable=0 ;;
        auto)
            if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
                enable=1
            fi
            ;;
    esac
    if ((enable)); then
        C_RED=$'\033[0;31m'
        C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[1;33m'
        C_BLUE=$'\033[0;34m'
        C_CYAN=$'\033[0;36m'
        C_BOLD=$'\033[1m'
        C_RESET=$'\033[0m'
    fi
}

log() { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
info() { printf '%s[info]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
step() { printf '\n%s==>%s %s\n' "$C_BOLD$C_CYAN" "$C_RESET" "$*" >&2; }

debug() {
    if ((OPT_VERBOSE)); then
        printf '%s[dbg ]%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2
    fi
    return 0
}

# ===========================================================================
# Command line
# ===========================================================================

CMD=""
OPT_YES=0
OPT_DRY_RUN=0
OPT_PERSIST=1
OPT_DEPS=1
OPT_COLOR="auto"
OPT_VERBOSE=0
OPT_PID=""
OPT_MESSAGE=""
ARGS=()
ROOT_WARNED=0
SWITCHED_IDS=()

fail_usage() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    printf "Run '%s help' for usage.\n" "$PROG" >&2
    exit 2
}

parse_args() {
    while (($#)); do
        case "$1" in
            -h | --help) CMD="help" ;;
            -V | --version) CMD="version" ;;
            --uninstall) CMD="clean" ;;
            -y | --yes) OPT_YES=1 ;;
            -n | --dry-run) OPT_DRY_RUN=1 ;;
            --no-persist) OPT_PERSIST=0 ;;
            --no-deps) OPT_DEPS=0 ;;
            --no-color) OPT_COLOR="never" ;;
            --color) OPT_COLOR="always" ;;
            -v | --verbose) OPT_VERBOSE=1 ;;
            --pid)
                (($# >= 2)) && [[ -n "$2" ]] || fail_usage "--pid requires an argument"
                OPT_PID="$2"
                shift
                ;;
            --pid=*)
                OPT_PID="${1#*=}"
                [[ -n "$OPT_PID" ]] || fail_usage "--pid requires an argument"
                ;;
            --message)
                (($# >= 2)) && [[ -n "$2" ]] || fail_usage "--message requires an argument"
                OPT_MESSAGE="$2"
                shift
                ;;
            --message=*)
                OPT_MESSAGE="${1#*=}"
                [[ -n "$OPT_MESSAGE" ]] || fail_usage "--message requires an argument"
                ;;
            --)
                shift
                while (($#)); do
                    if [[ -z "$CMD" ]]; then CMD="$1"; else ARGS+=("$1"); fi
                    shift
                done
                break
                ;;
            -*) fail_usage "unknown option: $1" ;;
            *)
                if [[ -z "$CMD" ]]; then CMD="$1"; else ARGS+=("$1"); fi
                ;;
        esac
        shift
    done

    [[ -n "$CMD" ]] || CMD="setup"

    if [[ -n "$OPT_PID" && ! "$OPT_PID" =~ ^[0-9a-fA-F]{4}$ ]]; then
        fail_usage "invalid --pid '$OPT_PID' (expected 4 hex digits, e.g. a192)"
    fi
    OPT_PID="${OPT_PID,,}"

    if [[ -n "$OPT_MESSAGE" ]]; then
        if [[ ! "$OPT_MESSAGE" =~ ^[0-9a-fA-F]+$ ]]; then
            fail_usage "invalid --message '$OPT_MESSAGE' (expected a hex string)"
        fi
        if ((${#OPT_MESSAGE} % 2 != 0)); then
            fail_usage "--message must contain an even number of hex digits"
        fi
        OPT_MESSAGE="${OPT_MESSAGE,,}"
    fi
}

usage() {
    cat <<EOF
Usage: $PROG [command] [options]

Switch Realtek USB Wi-Fi adapters out of CD-ROM ("driver installer") mode,
load a suitable kernel driver and make the switch persistent.

Commands:
  setup            Detect, switch mode, load driver, install udev rule and
                   verify (this is the default when no command is given)
  switch           Only switch devices from CD-ROM to Wi-Fi mode
  status           Show detected devices, modes, drivers and configuration
  list             List known install-mode product IDs
  clean            Remove the udev rule, blacklist and usb-storage quirk
                   created by this tool (aliases: uninstall, --uninstall)
  blacklist MOD... Prevent kernel module(s) from being auto-loaded
  unblacklist MOD... Undo 'blacklist' for kernel module(s)
  help             Show this help
  version          Show version information

Options:
  -y, --yes            Answer "yes" to all questions; required when not
                       running interactively
  -n, --dry-run        Show what would be done, change nothing. Works
                       without root as well.
      --no-persist     Do not install the udev rule
      --no-deps        Do not try to install missing packages
      --pid PID        Only handle the device with this product ID (CD-ROM
                       or Wi-Fi mode, 4 hex digits, e.g. a192 or f192)
      --message HEX    Use this switch message instead of the built-in one
                       (also wins over a usb-modeswitch config file)
      --no-color       Disable colored output (NO_COLOR is honoured too)
      --color          Force colored output
  -v, --verbose        Print debug information
  -h, --help           Show this help
  -V, --version        Show version information

Examples:
  sudo $PROG                       # full setup
  sudo $PROG switch --pid a192     # switch one specific device
  $PROG status                     # inspect the system, no root required
  sudo $PROG clean                 # remove the udev rule / blacklist / quirk

More information: $PROJECT_URL
EOF
}

# ===========================================================================
# Generic helpers
# ===========================================================================

require_root() {
    if ((EUID != 0)); then
        if ((OPT_DRY_RUN)); then
            if ((! ROOT_WARNED)); then
                warn "not running as root: this is a dry run, nothing will be changed"
                ROOT_WARNED=1
            fi
            return 0
        fi
        err "root privileges are required; run: sudo $SELF $CMD"
        exit 1
    fi
    return 0
}

confirm() {
    if ((OPT_YES || OPT_DRY_RUN)); then
        return 0
    fi
    [[ -t 0 ]] || return 1
    local answer=""
    printf '%s [Y/n] ' "$1" >&2
    read -r answer || return 1
    [[ "$answer" != [nN]* ]]
}

run() {
    if ((OPT_DRY_RUN)); then
        printf '%s[dry-run]%s' "$C_CYAN" "$C_RESET" >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        return 0
    fi
    debug "run: $*"
    "$@"
}

write_file() {
    local path="$1" content="$2" mode="${3:-644}" dir tmp
    if ((OPT_DRY_RUN)); then
        info "would write $path:"
        printf '%s\n' "$content" | sed 's/^/    /' >&2
        return 0
    fi
    dir=$(dirname -- "$path")
    tmp=$(mktemp "$dir/.realtek-usb-wifi-modeswitch.XXXXXX") || {
        err "cannot create a temporary file in $dir"
        return 1
    }
    if ! printf '%s\n' "$content" >"$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        err "could not write $path"
        return 1
    fi
    return 0
}

sysfs_write() {
    local path="$1" value="$2"
    if ((OPT_DRY_RUN)); then
        info "would write '$value' to $path"
        return 0
    fi
    printf '%s\n' "$value" >"$path" 2>/dev/null
}

os_pretty_name() {
    local name=""
    if [[ -r /etc/os-release ]]; then
        name=$(grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')
    fi
    printf '%s\n' "${name:-unknown}"
}

pkg_manager() {
    local m
    for m in apt-get dnf yum zypper pacman apk; do
        if command -v "$m" >/dev/null 2>&1; then
            printf '%s\n' "$m"
            return 0
        fi
    done
    return 1
}

# True when an executable is an absolute, root-owned path without characters
# that would break the generated udev RUN value.
path_is_trusted() {
    local p="$1" owner
    [[ "$p" == /* && -x "$p" ]] || return 1
    case "$p" in
        *[[:space:]\"\'%]*) return 1 ;;
    esac
    owner=$(stat -L -c %u -- "$p" 2>/dev/null) || return 1
    [[ "$owner" == 0 ]]
}

# True when a modprobe.d file blacklists this module.
module_blacklisted() {
    local mod="$1"
    grep -rqsE "^[[:space:]]*blacklist[[:space:]]+${mod}([[:space:]]|$)" \
        /etc/modprobe.d /run/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d 2>/dev/null
}

usb_modeswitch_pkg() {
    case "$1" in
        apt-get | apk) printf 'usb-modeswitch\n' ;;
        *) printf 'usb_modeswitch\n' ;;
    esac
}

install_usb_modeswitch() {
    local pm pkg
    pm=$(pkg_manager) || {
        warn "no supported package manager found"
        return 1
    }
    pkg=$(usb_modeswitch_pkg "$pm")
    confirm "Install '$pkg' using $pm?" || return 1
    case "$pm" in
        apt-get) run apt-get update -qq && run apt-get install -y "$pkg" ;;
        dnf | yum) run "$pm" install -y "$pkg" ;;
        zypper) run zypper --non-interactive install "$pkg" ;;
        pacman) run pacman -S --needed --noconfirm "$pkg" ;;
        apk) run apk add "$pkg" ;;
    esac
}

# ===========================================================================
# USB device discovery (sysfs based, no lsusb required)
# ===========================================================================

# All USB device directories (any vendor).
usb_device_dirs() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [[ -d "$d" && -r "$d/idVendor" && -r "$d/idProduct" && -r "$d/bDeviceClass" ]] || continue
        printf '%s\n' "$d"
    done
    return 0
}

realtek_device_dirs() {
    local d
    while read -r d; do
        [[ "$(dir_vid "$d")" == "$RT_VENDOR" ]] || continue
        printf '%s\n' "$d"
    done < <(usb_device_dirs)
}

dir_vid() { cat "$1/idVendor" 2>/dev/null; }
dir_pid() { cat "$1/idProduct" 2>/dev/null; }

# "cdrom" when the device is in mass-storage installer mode, else "device".
dir_mode() {
    local d="$1" f cls
    cls=$(cat "$d/bDeviceClass" 2>/dev/null) || cls="00"
    if [[ "$cls" == "08" ]]; then
        printf 'cdrom\n'
        return 0
    fi
    for f in "$d"/*:*/bInterfaceClass; do
        [[ -r "$f" ]] || continue
        cls=$(<"$f")
        if [[ "$cls" == "08" ]]; then
            printf 'cdrom\n'
            return 0
        fi
    done
    printf 'device\n'
}

chip_name() {
    case "${1,,}" in
        f192 | 318b) printf 'RTL8192FU\n' ;;
        d723) printf 'RTL8723DU\n' ;;
        2005) printf 'RTL8188GU\n' ;;
        b711) printf 'RTL8188GU / RTL8710BU\n' ;;
        c811 | 2006 | 8731 | 8811 | b820 | b82b | c821 | c82a | c82b) printf 'RTL8811CU / RTL8821CU\n' ;;
        c820 | c80c) printf 'RTL8821CU / RTL8811CU\n' ;;
        a811 | 0811 | 0820 | 0821 | 0823 | 8822) printf 'RTL8811AU / RTL8821AU\n' ;;
        b811) printf 'RTL8811AU\n' ;;
        8812 | 881a | 881b | 881c) printf 'RTL8812AU\n' ;;
        8813 | 8814) printf 'RTL8814AU\n' ;;
        2102 | b812 | b81a | b82c) printf 'RTL8822BU\n' ;;
        c812 | c82c | c82e | d820 | d82b) printf 'RTL8822CU\n' ;;
        b832) printf 'RTL8852BU / RTL8832BU\n' ;;
        8832) printf 'RTL8832AU / RTL8852AU\n' ;;
        885a | 885c) printf 'RTL8852AU\n' ;;
        a85b) printf 'RTL8852BT\n' ;;
        b83a | b852 | b85a) printf 'RTL8852BU\n' ;;
        b831 | b851) printf 'RTL8851BU\n' ;;
        c832) printf 'RTL8852CU / RTL8832CU\n' ;;
        c85a | c85d) printf 'RTL8852CU\n' ;;
        8912) printf 'RTL8922AU\n' ;;
        b720) printf 'RTL8723BU\n' ;;
        f179) printf 'RTL8188FU\n' ;;
        ffef) printf 'RTL8188EU\n' ;;
        818b) printf 'RTL8192EU\n' ;;
        8179) printf 'RTL8188EUS\n' ;;
        8178) printf 'RTL8188CUS\n' ;;
        8176) printf 'RTL8188CU\n' ;;
        *) printf 'Realtek USB Wi-Fi\n' ;;
    esac
}

# Directories of all Realtek devices currently in CD-ROM mode (honours --pid).
cd_mode_dirs() {
    local d
    while read -r d; do
        [[ "$(dir_mode "$d")" == "cdrom" ]] || continue
        [[ -z "$OPT_PID" || "$(dir_pid "$d")" == "$OPT_PID" ]] || continue
        printf '%s\n' "$d"
    done < <(realtek_device_dirs)
}

# True when the device exposes a vendor-specific (0xff) USB interface, which
# is how Realtek Wi-Fi adapters look in device mode. Bluetooth adapters use
# class 0xe0 and mass storage (CD-ROM mode) uses 0x08.
dir_is_wifi() {
    local d="$1" f cls
    for f in "$d"/*:*/bInterfaceClass; do
        [[ -r "$f" ]] || continue
        cls=$(<"$f")
        [[ "$cls" == "ff" ]] && return 0
    done
    return 1
}

# Directories of Realtek Wi-Fi devices that are already in Wi-Fi mode.
wifi_mode_dirs() {
    local d
    while read -r d; do
        [[ "$(dir_mode "$d")" == "device" ]] || continue
        dir_is_wifi "$d" || continue
        printf '%s\n' "$d"
    done < <(realtek_device_dirs)
}

# Find the sysfs directory of an arbitrary USB device by vendor:product.
# Also works when a ZeroCD device switches to another vendor's USB ID.
find_device_dir_by_id() {
    local vid="${1,,}" pid="${2,,}" d fallback=""
    while read -r d; do
        [[ "$(dir_vid "$d")" == "$vid" && "$(dir_pid "$d")" == "$pid" ]] || continue
        if [[ "$(dir_mode "$d")" == "device" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
        [[ -z "$fallback" ]] && fallback="$d"
    done < <(usb_device_dirs)
    if [[ -n "$fallback" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi
    return 1
}

# Names of USB-backed wireless interfaces (excludes built-in PCIe cards).
usb_wifi_interfaces() {
    local n dev
    for n in /sys/class/net/*; do
        [[ -d "$n/wireless" ]] || continue
        dev=$(readlink -f "$n/device" 2>/dev/null) || continue
        [[ "$dev" == *"/usb"* ]] || continue
        basename "$n"
    done
    return 0
}

# Print the wireless interface belonging to the given USB device, waiting up
# to <tries> seconds for it to appear.
wait_for_device_interface() {
    local vid="${1,,}" pid="${2,,}" tries="${3:-10}" i n dev d
    for ((i = 0; i < tries; i++)); do
        for n in /sys/class/net/*; do
            [[ -d "$n/wireless" ]] || continue
            dev=$(readlink -f "$n/device" 2>/dev/null) || continue
            [[ "$dev" == *"/usb"* ]] || continue
            d=$(dirname "$dev")
            if [[ "$(dir_vid "$d")" == "$vid" && "$(dir_pid "$d")" == "$pid" ]]; then
                printf '%s\n' "$(basename "$n")"
                return 0
            fi
        done
        sleep 1
    done
    return 1
}

# ===========================================================================
# Mode switching
# ===========================================================================

switch_message_for_pid() {
    local pid="${1,,}" entry p m
    for entry in "${CD_PIDS[@]}"; do
        p="${entry%%:*}"
        [[ "$p" == "$pid" ]] || continue
        m="${entry#*:}"
        m="${m%%:*}"
        if [[ -n "$m" && "$m" != "-" ]]; then
            printf '%s\n' "$m"
            return 0
        fi
        break
    done
    printf '%s\n' "$DEFAULT_MSG"
}

# /dev/sr* devices provided by this USB device (only exists in CD-ROM mode).
sr_devices_for() {
    local devdir="$1" real target n
    real=$(readlink -f -- "$devdir" 2>/dev/null) || return 0
    for n in /sys/class/block/sr[0-9]*; do
        [[ -e "$n" ]] || continue
        target=$(readlink -f -- "$n/device" 2>/dev/null) || continue
        if [[ "$target" == "$real"/* ]]; then
            printf '/dev/%s\n' "$(basename "$n")"
        fi
    done
    return 0
}

# Remember the vendor:product ID of a device that switched modes. Some
# devices come back under a different vendor (e.g. D-Link 2001:331d), so
# cmd_setup must not rely only on scanning Realtek's vendor ID.
remember_switched() {
    local id="$1" existing
    if ((${#SWITCHED_IDS[@]} > 0)); then
        for existing in "${SWITCHED_IDS[@]}"; do
            [[ "$existing" == "$id" ]] && return 0
        done
    fi
    SWITCHED_IDS+=("$id")
}

wait_for_mode_switch() {
    local devdir="$1" oldpid="$2" before="$3" i newpid d newvid id
    for ((i = 0; i < 8; i++)); do
        sleep 2
        # The same USB port may re-enumerate with a new vendor/product ID
        # (some ZeroCD devices come back under a different vendor, e.g.
        # D-Link 2001:331d instead of Realtek 0bda:*).
        if [[ -r "$devdir/idProduct" ]]; then
            newpid=$(dir_pid "$devdir")
            newvid=$(dir_vid "$devdir")
            if [[ "$newpid" != "$oldpid" && "$(dir_mode "$devdir")" == "device" ]]; then
                id="$newvid:$newpid"
                remember_switched "$id"
                log "switched to Wi-Fi mode: $id ($(chip_name "$newpid"))"
                return 0
            fi
        fi
        # ... or the device may have re-appeared on a different port.
        while read -r d; do
            grep -qxF "$d" <<<"$before" && continue
            newpid=$(dir_pid "$d")
            newvid=$(dir_vid "$d")
            id="$newvid:$newpid"
            remember_switched "$id"
            log "detected Wi-Fi-mode device after the switch: $id ($(chip_name "$newpid"))"
            return 0
        done < <(wifi_mode_dirs)
    done
    return 1
}

switch_device() {
    local devdir="$1"
    local pid msg attempt sr="" has_um=0 has_eject=0 eject_used=0 before="" cfg="" c args=()

    pid=$(dir_pid "$devdir")
    msg="${OPT_MESSAGE:-$(switch_message_for_pid "$pid")}"

    info "device $RT_VENDOR:$pid ($(chip_name "$pid")) is in CD-ROM mode"

    command -v usb_modeswitch >/dev/null 2>&1 && has_um=1
    command -v eject >/dev/null 2>&1 && has_eject=1
    if ((! has_um && OPT_DEPS)); then
        install_usb_modeswitch || true
        if ((OPT_DRY_RUN)) || command -v usb_modeswitch >/dev/null 2>&1; then
            has_um=1
        fi
    fi
    if ((! has_um && ! has_eject)); then
        err "neither 'usb_modeswitch' nor 'eject' is installed"
        return 1
    fi

    # Prefer a tested config shipped by usb-modeswitch-data, unless the user
    # explicitly asked for a specific message.
    if [[ -z "$OPT_MESSAGE" ]]; then
        for c in "/etc/usb_modeswitch.d/${RT_VENDOR}:${pid}" "/usr/share/usb_modeswitch/${RT_VENDOR}:${pid}"; do
            if [[ -r "$c" ]]; then
                cfg="$c"
                break
            fi
        done
    fi
    if [[ -n "$cfg" ]]; then
        info "using usb-modeswitch config: $cfg"
    fi

    sr=$(sr_devices_for "$devdir" | head -n1)
    if [[ -n "$sr" ]]; then
        info "associated CD-ROM device: $sr"
    fi

    before=$(wifi_mode_dirs)

    for attempt in 1 2 3; do
        if ((attempt <= 2)) && ((has_um)); then
            args=()
            if [[ -n "$cfg" && $attempt -eq 1 ]]; then
                args=(-v "$RT_VENDOR" -p "$pid" -c "$cfg")
            else
                args=(-v "$RT_VENDOR" -p "$pid" -M "$msg" -K)
                ((attempt == 2)) && args+=(-R)
            fi
            ((OPT_VERBOSE)) && args+=(-W)
            info "usb_modeswitch attempt $attempt/2"
            run usb_modeswitch "${args[@]}" 2>&1 | sed 's/^/    /' >&2 || true
        elif ((has_eject)) && ((! eject_used)) && [[ -n "$sr" && -b "$sr" ]]; then
            eject_used=1
            info "falling back to SCSI eject on $sr"
            run eject "$sr" 2>&1 | sed 's/^/    /' >&2 || true
        else
            break
        fi
        if ((OPT_DRY_RUN)); then
            return 0
        fi
        sleep 3
        if wait_for_mode_switch "$devdir" "$pid" "$before"; then
            return 0
        fi
    done

    err "device $RT_VENDOR:$pid did not switch to Wi-Fi mode"
    err "try unplugging and re-plugging the adapter, then: sudo $SELF switch"
    return 1
}

# ===========================================================================
# Driver discovery and binding
# ===========================================================================

# Kernel modules whose USB alias table mentions this vendor/product ID.
drivers_for_id() {
    local vid="${1,,}" pid="${2,,}" out="" alias_file
    if command -v modprobe >/dev/null 2>&1; then
        out=$(modprobe -n -c 2>/dev/null | awk -v v="$vid" -v p="$pid" '
            tolower($1) == "alias" && tolower($2) ~ ("usb:v" v "p" p "d") { print $NF }')
    fi
    if [[ -z "$out" ]]; then
        alias_file="/lib/modules/$(uname -r)/modules.alias"
        if [[ -r "$alias_file" ]]; then
            out=$(awk -v v="$vid" -v p="$pid" '
                tolower($1) == "alias" && tolower($2) ~ ("usb:v" v "p" p "d") { print $NF }' "$alias_file")
        fi
    fi
    [[ -n "$out" ]] || return 0
    printf '%s\n' "$out" | sort -u
}

driver_rank() {
    local pid="$1" mod="$2"
    case "$mod" in
        8192fu) if [[ "$pid" == "f192" ]]; then echo 5; else echo 90; fi ;;
        rtw88_* | rtw89_*) echo 10 ;;
        rtl8xxxu) echo 20 ;;
        8822cu | rtl8822cu | 8822bu | rtl8822bu) echo 25 ;;
        *8812au* | *8814au* | *8821au*) echo 30 ;;
        *8821cu* | *8811cu*) echo 35 ;;
        *8822cu* | *8822bu*) echo 35 ;;
        *8851bu* | *8852au* | *8852bu* | *8852cu* | *8922au*) echo 35 ;;
        *) echo 50 ;;
    esac
}

pick_driver() {
    local pid="$1"
    shift
    local mod
    for mod in "$@"; do
        printf '%d %s\n' "$(driver_rank "$pid" "$mod")" "$mod"
    done | sort -k1,1n -k2,2 | awk 'NR == 1 { print $2 }'
}

is_module_loaded() {
    grep -qE "^${1//-/_}[[:space:]]" /proc/modules 2>/dev/null
}

load_module() {
    local mod="$1" ko out
    if is_module_loaded "$mod"; then
        info "kernel module '$mod' is already loaded"
        return 0
    fi
    if ((OPT_DRY_RUN)); then
        run modprobe "$mod"
        return 0
    fi
    if out=$(modprobe "$mod" 2>&1); then
        log "loaded kernel module: $mod"
        return 0
    fi
    debug "modprobe $mod failed: $out"
    if module_blacklisted "$mod"; then
        err "kernel module '$mod' is blacklisted; not loading it"
        return 1
    fi
    # Vendor drivers are sometimes installed outside the modprobe search path.
    ko=$(find "/lib/modules/$(uname -r)" -type f \
        \( -name "${mod}.ko" -o -name "${mod}.ko.xz" -o -name "${mod}.ko.zst" \) \
        2>/dev/null | head -n1)
    if [[ -n "$ko" ]]; then
        if run insmod "$ko"; then
            log "loaded kernel module: $ko"
            return 0
        fi
        err "insmod failed: $ko"
        return 1
    fi
    err "could not load kernel module '$mod'"
    return 1
}

# Name of the /sys/bus/usb/drivers directory registered by a module,
# e.g. module 8192fu -> driver directory rtl8192fu.
find_driver_dir() {
    local mod="$1" d name
    for d in /sys/bus/usb/drivers/*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        if [[ "$name" == "$mod" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    for d in /sys/bus/usb/drivers/*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        case "$name" in
            "rtl$mod" | "rtw$mod" | "rtw88_$mod")
                printf '%s\n' "$name"
                return 0
                ;;
        esac
    done
    for d in /sys/bus/usb/drivers/*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        if [[ "$name" == *"$mod"* ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    return 1
}

bind_device() {
    local devdir="$1" mod="$2" vid="$3" pid="$4"
    local bindname="" t name cur ok=0 attempt i
    local targets=() x

    for ((i = 0; i < 5; i++)); do
        bindname=$(find_driver_dir "$mod") || bindname=""
        [[ -n "$bindname" ]] && break
        ((OPT_DRY_RUN)) && break
        sleep 1
    done
    if [[ -z "$bindname" ]]; then
        warn "module '$mod' does not register a USB driver; cannot bind"
        return 1
    fi

    # Interfaces first; the device-level node is only needed for
    # non-composite devices.
    for x in "$devdir"/*:* "$devdir"; do
        [[ -e "$x" ]] && targets+=("$x")
    done
    if ((${#targets[@]} == 0)); then
        warn "no sysfs entries found for $devdir; cannot bind"
        return 1
    fi

    for t in ${targets[@]+"${targets[@]}"}; do
        [[ -e "$t/driver" ]] || continue
        cur=$(basename "$(readlink -f "$t/driver")")
        [[ "$cur" == "$bindname" ]] || continue
        log "$(basename "$t") is already bound to $bindname"
        return 0
    done

    # Unbind interfaces that were claimed by the wrong driver.
    for t in ${targets[@]+"${targets[@]}"}; do
        [[ -e "$t/driver" ]] || continue
        cur=$(basename "$(readlink -f "$t/driver")")
        [[ "$cur" == "$bindname" || "$cur" == "usb" ]] && continue
        name=$(basename "$t")
        warn "$name is bound to '$cur'; unbinding to use '$bindname' instead"
        sysfs_write "/sys/bus/usb/drivers/$cur/unbind" "$name" || warn "unbind failed"
    done
    sleep 1

    # Bind interfaces first, then the device itself (non-composite devices).
    for t in ${targets[@]+"${targets[@]}"}; do
        name=$(basename "$t")
        sysfs_write "/sys/bus/usb/drivers/$bindname/bind" "$name" || continue
        if ((OPT_DRY_RUN)); then
            ok=1
            break
        fi
        for attempt in 1 2 3; do
            sleep 1
            if [[ -e "$t/driver" ]] && [[ "$(basename "$(readlink -f "$t/driver")")" == "$bindname" ]]; then
                log "bound $name to $bindname"
                ok=1
                break 2
            fi
        done
    done
    ((ok)) && return 0

    if ((OPT_DRY_RUN)); then
        info "would add dynamic ID $vid:$pid to $bindname"
        return 0
    fi

    # The driver may not know this ID: teach it dynamically.
    info "driver '$bindname' does not list $vid:$pid; adding dynamic ID"
    if sysfs_write "/sys/bus/usb/drivers/$bindname/new_id" "$vid $pid"; then
        sleep 2
        for t in ${targets[@]+"${targets[@]}"}; do
            [[ -e "$t/driver" ]] || continue
            cur=$(basename "$(readlink -f "$t/driver")")
            if [[ "$cur" == "$bindname" ]]; then
                log "bound $(basename "$t") to $bindname"
                return 0
            fi
        done
    fi

    warn "could not bind $vid:$pid to '$bindname'"
    return 1
}

setup_driver() {
    local vid="$1" pid="$2"
    step "Driver setup for $vid:$pid ($(chip_name "$pid"))"

    local candidates=()
    mapfile -t candidates < <(drivers_for_id "$vid" "$pid")
    if ((${#candidates[@]} == 0)); then
        err "no kernel module in this system claims USB ID $vid:$pid"
        print_driver_hints
        return 1
    fi
    info "kernel modules claiming $vid:$pid: ${candidates[*]}"

    local mod
    mod=$(pick_driver "$pid" "${candidates[@]}")
    if [[ -z "$mod" ]]; then
        err "could not select a driver for $vid:$pid"
        return 1
    fi
    log "selected driver: $mod"

    load_module "$mod" || return 1
    ((OPT_DRY_RUN)) && return 0

    local devdir
    if ! devdir=$(find_device_dir_by_id "$vid" "$pid"); then
        warn "sysfs device for $vid:$pid disappeared; skipping bind check"
        return 0
    fi
    if [[ "$(dir_mode "$devdir")" == "cdrom" ]]; then
        warn "device $vid:$pid is still in CD-ROM mode; skipping bind check"
        return 0
    fi
    sleep 1
    bind_device "$devdir" "$mod" "$vid" "$pid" || return 1

    local iface=""
    if iface=$(wait_for_device_interface "$vid" "$pid" 10); then
        log "wireless interface present: $iface"
    else
        warn "driver loaded but no wireless interface appeared for $vid:$pid"
        warn "try re-plugging the adapter; see $PROJECT_URL/blob/main/docs/TROUBLESHOOTING.md"
    fi
    return 0
}

print_driver_hints() {
    cat >&2 <<EOF

No driver currently present in this system claims this device.

What you can do:
  * Use a newer kernel. In-kernel USB support on Linux:
      - rtw88 USB (6.2+): RTL8723DU, RTL8811CU/8821CU, RTL8822BU, RTL8822CU
      - rtw88 USB (6.13+): RTL8821AU/8811AU; RTL8814AU (6.15+)
      - rtw89 USB (6.17+): RTL8851BU, RTL8852BU
      - rtw89 USB (6.19+): RTL8852AU, RTL8852CU
      - rtw89 USB (7.2+): RTL8922AU
      - rtl8xxxu (6.5+): RTL8192FU, plus RTL8188GU and older chips
    On kernels older than these, use an out-of-tree driver.
  * Install an out-of-tree driver for your chip. See:
      $PROJECT_URL/blob/main/docs/DRIVERS.md
      https://github.com/morrownr/USB-WiFi
  * If a vendor driver is already installed but not loaded, try:
      sudo modprobe <module-name>
EOF
}

# ===========================================================================
# Commands
# ===========================================================================

cmd_switch() {
    require_root
    step "Switching Realtek USB Wi-Fi devices to Wi-Fi mode"

    local dirs=()
    mapfile -t dirs < <(cd_mode_dirs)
    if ((${#dirs[@]} == 0)); then
        if [[ -n "$(wifi_mode_dirs)" || -n "$(usb_wifi_interfaces)" ]]; then
            log "no Realtek device is in CD-ROM mode; nothing to switch"
            return 0
        fi
        warn "no Realtek USB Wi-Fi device found (vendor ID $RT_VENDOR)"
        warn "check that the adapter is plugged in: lsusb -d $RT_VENDOR:"
        return 1
    fi

    SWITCHED_IDS=()
    local d ok=0
    for d in "${dirs[@]}"; do
        if switch_device "$d"; then
            ok=1
        fi
    done
    ((ok))
}

cmd_persist() {
    require_root
    step "Installing persistent mode-switch rule"

    local ms=""
    if command -v usb_modeswitch >/dev/null 2>&1; then
        ms=$(command -v usb_modeswitch)
        if ! path_is_trusted "$ms"; then
            err "refusing to use untrusted usb_modeswitch path: $ms"
            return 1
        fi
    elif ((OPT_DRY_RUN)); then
        ms="/usr/sbin/usb_modeswitch"
        warn "usb_modeswitch is not installed; previewing the rule with a placeholder path"
    else
        warn "usb_modeswitch is not installed; skipping the udev rule"
        warn "install it and re-run 'sudo $SELF setup' to enable automatic switching"
        return 1
    fi

    local rules=()
    local -A seen=()
    local entry pid d

    add_rule() {
        local p="$1"
        [[ -n "${seen[$p]:-}" ]] && return 0
        seen[$p]=1
        local m="${OPT_MESSAGE:-$(switch_message_for_pid "$p")}"
        rules+=("ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$RT_VENDOR\", ATTR{idProduct}==\"$p\", RUN+=\"$ms -v $RT_VENDOR -p $p -M $m -K\"")
    }

    # Persist the devices found right now first, then the known install-mode
    # IDs. With --pid only the matching product ID is persisted.
    while read -r d; do
        add_rule "$(dir_pid "$d")"
    done < <(cd_mode_dirs)
    for entry in ${CD_PIDS[@]+"${CD_PIDS[@]}"}; do
        pid="${entry%%:*}"
        [[ -z "$OPT_PID" || "$pid" == "$OPT_PID" ]] || continue
        add_rule "$pid"
    done

    if ((${#rules[@]} == 0)); then
        warn "no install-mode product ID matches --pid $OPT_PID; skipping the udev rule"
        return 1
    fi

    local content
    content="# Managed by $PROJECT $VERSION - remove with 'sudo $PROG clean'
# Realtek USB Wi-Fi: switch install-mode (CD-ROM) devices to Wi-Fi mode.
$(printf '%s\n' ${rules[@]+"${rules[@]}"})"

    if ((OPT_DRY_RUN)); then
        write_file "$UDEV_RULE" "$content" 644
        return 0
    fi

    write_file "$UDEV_RULE" "$content" 644 || return 1
    if command -v udevadm >/dev/null 2>&1; then
        run udevadm control --reload-rules || true
    fi
    log "installed $UDEV_RULE"
    log "the adapter will now switch automatically on plug-in and boot"
}

cmd_setup() {
    require_root
    step "Realtek USB Wi-Fi setup"
    info "kernel: $(uname -r)"
    info "distribution: $(os_pretty_name)"

    if ! cmd_switch; then
        warn "mode switch did not complete"
        confirm "Continue with driver setup anyway?" || exit 1
    fi

    local count=0 failed=0
    local -A done_ids=()
    local id vid pid d

    # Devices that completed the switch in this run, including devices that
    # came back under a different vendor ID (for example D-Link 2001:331d).
    if ((${#SWITCHED_IDS[@]} > 0)); then
        for id in "${SWITCHED_IDS[@]}"; do
            [[ -n "${done_ids[$id]:-}" ]] && continue
            done_ids["$id"]=1
            count=$((count + 1))
            vid="${id%%:*}"
            pid="${id#*:}"
            setup_driver "$vid" "$pid" || {
                warn "driver setup for $id did not complete"
                failed=$((failed + 1))
            }
        done
    fi

    # Devices that were already in Wi-Fi mode before this run. With --pid,
    # filter to that product ID (which may be the Wi-Fi-mode ID when the
    # device was already switched).
    while read -r d; do
        pid=$(dir_pid "$d")
        [[ -z "$OPT_PID" || "$pid" == "$OPT_PID" ]] || continue
        id="$RT_VENDOR:$pid"
        [[ -n "${done_ids[$id]:-}" ]] && continue
        done_ids["$id"]=1
        count=$((count + 1))
        setup_driver "$RT_VENDOR" "$pid" || {
            warn "driver setup for $id did not complete"
            failed=$((failed + 1))
        }
    done < <(wifi_mode_dirs)

    if ((count == 0)); then
        warn "no Wi-Fi-mode Realtek device detected; skipping driver setup"
    fi

    if ((OPT_PERSIST)); then
        cmd_persist || warn "could not install the udev rule"
    else
        info "skipping the udev rule (--no-persist)"
    fi

    verify_interfaces || true

    if ((failed > 0)); then
        err "$failed device(s) could not be set up; see the messages above"
        return 1
    fi

    if ((OPT_PERSIST)); then
        cat >&2 <<EOF

$(printf '%sSetup complete.%s' "$C_BOLD$C_GREEN" "$C_RESET")

Connect to a network with your desktop's network menu, or:
  nmcli device wifi connect "<SSID>" password "<password>"

From now on the adapter switches automatically when plugged in.
Remove everything with: sudo $SELF clean
EOF
    else
        cat >&2 <<EOF

$(printf '%sSetup complete.%s' "$C_BOLD$C_GREEN" "$C_RESET")

Connect to a network with your desktop's network menu, or:
  nmcli device wifi connect "<SSID>" password "<password>"

No udev rule was installed (--no-persist).
EOF
    fi
}

# USB wireless interfaces that belong to a Realtek device or to a
# vendor:product ID that was switched in this run.
target_wifi_interfaces() {
    local n dev d id existing hit
    for n in /sys/class/net/*; do
        [[ -d "$n/wireless" ]] || continue
        dev=$(readlink -f "$n/device" 2>/dev/null) || continue
        [[ "$dev" == *"/usb"* ]] || continue
        d=$(dirname "$dev")
        id="$(dir_vid "$d"):$(dir_pid "$d")"
        hit=0
        [[ "${id%%:*}" == "$RT_VENDOR" ]] && hit=1
        for existing in ${SWITCHED_IDS[@]+"${SWITCHED_IDS[@]}"}; do
            [[ "$existing" == "$id" ]] && hit=1
        done
        ((hit)) && basename "$n"
    done
    return 0
}

verify_interfaces() {
    step "Verifying"
    local ifaces=()
    mapfile -t ifaces < <(target_wifi_interfaces)
    if ((${#ifaces[@]} == 0)); then
        warn "no wireless interface for the handled adapter(s) found (yet)"
        warn "if the driver is missing, see $PROJECT_URL/blob/main/docs/DRIVERS.md"
        return 1
    fi
    local i
    for i in ${ifaces[@]+"${ifaces[@]}"}; do
        log "wireless interface ready: $i"
    done
    if ((OPT_VERBOSE)) && command -v nmcli >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        info "nearby networks (first 5):"
        timeout 20 nmcli -t -f SSID,SIGNAL dev wifi list ifname "${ifaces[0]}" 2>/dev/null |
            head -n5 | sed 's/^/    /' >&2 || true
    fi
    return 0
}

cmd_status() {
    printf '%s %s\n' "$PROG" "$VERSION"
    printf '  kernel         : %s\n' "$(uname -r)"
    printf '  distribution   : %s\n' "$(os_pretty_name)"
    if command -v usb_modeswitch >/dev/null 2>&1; then
        printf '  usb_modeswitch : %s\n' "$(command -v usb_modeswitch)"
    else
        printf '  usb_modeswitch : not installed\n'
    fi
    if [[ -e "$UDEV_RULE" ]]; then
        printf '  udev rule      : %s\n' "$UDEV_RULE"
    else
        printf '  udev rule      : not installed\n'
    fi
    if [[ -e "$BLACKLIST_FILE" ]]; then
        printf '  blacklist      : %s\n' "$BLACKLIST_FILE"
    else
        printf '  blacklist      : not installed\n'
    fi
    if [[ -e "$USB_STORAGE_QUIRK_FILE" ]]; then
        printf '  usb_storage    : %s\n' "$USB_STORAGE_QUIRK_FILE"
    else
        printf '  usb_storage    : no quirk installed\n'
    fi

    printf '\nRealtek USB devices (vendor %s):\n' "$RT_VENDOR"
    local d pid mode found=0 t cur label note
    while read -r d; do
        found=1
        pid=$(dir_pid "$d")
        mode=$(dir_mode "$d")
        if [[ "$mode" == "cdrom" ]]; then
            label="CD-ROM"
            note=$(chip_name "$pid")
        elif dir_is_wifi "$d"; then
            label="Wi-Fi"
            note=$(chip_name "$pid")
        else
            label="other"
            note="not a Wi-Fi interface"
        fi
        printf '  %-9s %s:%s  %-6s  %s\n' "$(basename "$d")" "$RT_VENDOR" "$pid" "$label" "$note"
        for t in "$d"/*:*; do
            [[ -e "$t/driver" ]] || continue
            cur=$(basename "$(readlink -f "$t/driver")")
            printf '            %s -> driver %s\n' "$(basename "$t")" "$cur"
        done
    done < <(realtek_device_dirs)
    ((found)) || printf '  (none found)\n'

    printf '\nUSB wireless interfaces:\n'
    local ifaces=()
    mapfile -t ifaces < <(usb_wifi_interfaces)
    if ((${#ifaces[@]} == 0)); then
        printf '  (none found)\n'
    else
        printf '  %s\n' "${ifaces[@]}"
    fi

    printf '\nRealtek-related kernel modules loaded:\n'
    local mods=""
    mods=$(lsmod 2>/dev/null | awk 'NR > 1 && $1 ~ /^(rtw|rtl|8188|8192|8723|8811|8812|8813|8814|8821|8822|8832|8851|8852|8922|88x2)/ { printf "  %s\n", $1 }')
    if [[ -n "$mods" ]]; then
        printf '%s\n' "$mods"
    else
        printf '  (none)\n'
    fi

    if [[ -e "$LEGACY_UDEV" || -e "$LEGACY_BLACKLIST" ]]; then
        printf '\nNote: files left behind by older third-party scripts were found:\n'
        [[ -e "$LEGACY_UDEV" ]] && printf '  %s\n' "$LEGACY_UDEV"
        [[ -e "$LEGACY_BLACKLIST" ]] && printf '  %s\n' "$LEGACY_BLACKLIST"
    fi
}

cmd_list() {
    printf 'Known Realtek USB Wi-Fi install-mode (CD-ROM) product IDs:\n\n'
    printf '  %-6s  %-34s  %s\n' "PID" "LIKELY CHIP" "SWITCH MESSAGE"
    printf '  %-6s  %-34s  %s\n' "------" "----------------------------------" "--------------"
    local entry pid chip
    for entry in "${CD_PIDS[@]}"; do
        pid="${entry%%:*}"
        chip="${entry##*:}"
        if [[ "$(switch_message_for_pid "$pid")" == "$DEFAULT_MSG" ]]; then
            printf '  %-6s  %-34s  %s\n' "$pid" "$chip" "standard"
        else
            printf '  %-6s  %-34s  %s\n' "$pid" "$chip" "custom"
        fi
    done
    cat <<EOF

These are the only Realtek ZeroCD IDs registered in the Linux kernel
(drivers/usb/storage/unusual_devs.h) and in usb-modeswitch upstream. A device
may come back with a different product ID after switching - occasionally even
under a different vendor ID (for example D-Link 2001:331d) - and the correct
driver is selected automatically from that ID.
To add a custom switch message, extend CD_PIDS in modeswitch.sh and open a pull request.
EOF
}

cmd_blacklist() {
    ((${#ARGS[@]})) || fail_usage "blacklist needs at least one module name"
    require_root

    local lines=() m line
    if [[ -r "$BLACKLIST_FILE" ]]; then
        mapfile -t lines <"$BLACKLIST_FILE"
    else
        lines=("# Managed by $PROJECT - kernel modules that must not be auto-loaded")
    fi

    local added=0 present=0
    for m in ${ARGS[@]+"${ARGS[@]}"}; do
        [[ "$m" =~ ^[A-Za-z0-9_-]+$ ]] || fail_usage "invalid module name: $m"
        m="${m//-/_}"
        present=0
        for line in ${lines[@]+"${lines[@]}"}; do
            [[ "$line" == "blacklist $m" ]] && present=1
        done
        if ((present)); then
            info "'$m' is already blacklisted"
            continue
        fi
        lines+=("blacklist $m")
        added=1
        if ((OPT_DRY_RUN)); then
            info "would blacklist kernel module: $m"
        else
            log "blacklisted kernel module: $m"
        fi
    done
    ((added)) || return 0

    write_file "$BLACKLIST_FILE" "$(printf '%s\n' ${lines[@]+"${lines[@]}"})" 644 || return 1
    if ((! OPT_DRY_RUN)); then
        info "unload a module that is currently in use with 'sudo rmmod <module>', or reboot"
    fi
}

cmd_unblacklist() {
    ((${#ARGS[@]})) || fail_usage "unblacklist needs at least one module name"
    require_root

    if [[ ! -e "$BLACKLIST_FILE" ]]; then
        info "no blacklist file exists ($BLACKLIST_FILE)"
        return 0
    fi

    local lines=() m new l found=0
    mapfile -t lines <"$BLACKLIST_FILE"

    for m in ${ARGS[@]+"${ARGS[@]}"}; do
        [[ "$m" =~ ^[A-Za-z0-9_-]+$ ]] || fail_usage "invalid module name: $m"
        m="${m//-/_}"
        new=()
        found=0
        for l in ${lines[@]+"${lines[@]}"}; do
            if [[ "$l" == "blacklist $m" ]]; then
                found=1
            else
                new+=("$l")
            fi
        done
        if ((found)); then
            lines=(${new[@]+"${new[@]}"})
            if ((OPT_DRY_RUN)); then
                info "would remove blacklist entry: $m"
            else
                log "removed blacklist entry: $m"
            fi
        else
            info "'$m' was not blacklisted"
        fi
    done

    if ((${#lines[@]} == 0)); then
        if ((OPT_DRY_RUN)); then
            info "would remove empty blacklist file: $BLACKLIST_FILE"
        else
            rm -f "$BLACKLIST_FILE" || return 1
            log "removed empty blacklist file: $BLACKLIST_FILE"
        fi
        return 0
    fi

    write_file "$BLACKLIST_FILE" "$(printf '%s\n' ${lines[@]+"${lines[@]}"})" 644 || return 1
}

cmd_clean() {
    require_root
    step "Removing configuration installed by $PROG"

    local removed=0
    if [[ -e "$UDEV_RULE" ]]; then
        run rm -f "$UDEV_RULE"
        removed=1
    fi
    if [[ -e "$BLACKLIST_FILE" ]]; then
        run rm -f "$BLACKLIST_FILE"
        removed=1
    fi
    if [[ -e "$USB_STORAGE_QUIRK_FILE" ]]; then
        run rm -f "$USB_STORAGE_QUIRK_FILE"
        removed=1
    fi

    if ((removed)); then
        if ((OPT_DRY_RUN)); then
            info "dry run: nothing was removed"
        else
            if command -v udevadm >/dev/null 2>&1; then
                run udevadm control --reload-rules || true
            fi
            log "configuration removed"
        fi
    else
        info "nothing to remove"
    fi

    if [[ -e "$LEGACY_UDEV" || -e "$LEGACY_BLACKLIST" ]]; then
        warn "files from older third-party scripts are present and were left untouched:"
        [[ -e "$LEGACY_UDEV" ]] && printf '    %s\n' "$LEGACY_UDEV" >&2
        [[ -e "$LEGACY_BLACKLIST" ]] && printf '    %s\n' "$LEGACY_BLACKLIST" >&2
        info "delete them manually if they conflict with this tool"
    fi

    info "kernel modules are not unloaded; reboot if you want a clean slate"
}

# ===========================================================================
# Entry point
# ===========================================================================

preflight() {
    if ((BASH_VERSINFO[0] < 4)); then
        printf '%s requires Bash 4.0 or newer (found %s)\n' "$PROG" "$BASH_VERSION" >&2
        exit 1
    fi
    if [[ "$(uname -s)" != "Linux" ]]; then
        printf '%s only supports Linux (found %s)\n' "$PROG" "$(uname -s)" >&2
        exit 1
    fi
}

main() {
    parse_args "$@"
    setup_colors

    # help/version work everywhere, even without Linux or Bash 4.
    case "$CMD" in
        help)
            usage
            return 0
            ;;
        version)
            printf '%s %s\n' "$PROG" "$VERSION"
            return 0
            ;;
    esac

    preflight

    case "$CMD" in
        setup | switch | status | list | clean | uninstall)
            ((${#ARGS[@]} == 0)) || fail_usage "unexpected argument: ${ARGS[0]}"
            ;;
    esac

    case "$CMD" in
        setup) cmd_setup ;;
        switch) cmd_switch ;;
        status) cmd_status ;;
        list) cmd_list ;;
        clean | uninstall) cmd_clean ;;
        blacklist) cmd_blacklist ;;
        unblacklist) cmd_unblacklist ;;
        *)
            printf '%s: unknown command: %s\n' "$PROG" "$CMD" >&2
            usage >&2
            exit 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

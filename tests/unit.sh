#!/usr/bin/env bash
#
# Unit tests for realtek-usb-wifi-modeswitch. These source the script (safe: main is only
# run when the script is executed, not sourced) and exercise helper functions
# with a fake sysfs tree, so they touch nothing real.
#
# Copyright (c) 2026 秦凡东 (shell_way@foxmail.com)
# SPDX-License-Identifier: MIT
#
set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=modeswitch.sh
source ./modeswitch.sh

pass=0
fail=0

ok() {
    printf 'ok   - %s\n' "$1"
    pass=$((pass + 1))
}
bad() {
    printf 'FAIL - %s\n' "$1"
    fail=$((fail + 1))
}

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        ok "$desc"
    else
        bad "$desc (expected '$expected', got '$actual')"
    fi
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        ok "$desc"
    else
        bad "$desc (missing '$needle' in '$haystack')"
    fi
}

# --- chip names and messages ---------------------------------------------
check_contains "chip_name f192" "RTL8192FU" "$(chip_name f192)"
check_contains "chip_name b851" "RTL8851BU" "$(chip_name b851)"
check_contains "chip_name unknown" "Realtek USB Wi-Fi" "$(chip_name 1234)"
check_contains "chip_name 818b" "RTL8192EU" "$(chip_name 818b)"
check_contains "chip_name 8813" "RTL8814AU" "$(chip_name 8813)"
check_eq "default message for a192" "$DEFAULT_MSG" "$(switch_message_for_pid a192)"
check_eq "default message for 1a2b" "$DEFAULT_MSG" "$(switch_message_for_pid 1a2b)"
check_eq "default message for unknown pid" "$DEFAULT_MSG" "$(switch_message_for_pid dead)"

# --- driver ranking -------------------------------------------------------
check_eq "8192fu wins for f192" "8192fu" "$(pick_driver f192 8192fu rtl8xxxu rtw88_8821cu)"
check_eq "rtw88 wins for c820" "rtw88_8821cu" "$(pick_driver c820 8821cu rtw88_8821cu)"
check_eq "rtl8xxxu beats generic for 2005" "rtl8xxxu" "$(pick_driver 2005 rtl8xxxu 8188gu)"
check_eq "rtw89 wins over out-of-tree for b851" "rtw89_8851bu" "$(pick_driver b851 8851bu rtw89_8851bu)"
check_eq "rtw89 wins over out-of-tree for c832" "rtw89_8852cu" "$(pick_driver c832 rtl8852cu rtw89_8852cu)"

# --- fake sysfs tree ------------------------------------------------------
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# mkdev <name> <vid> <pid> <bDeviceClass> [interface classes...]
mkdev() {
    local name="$1" vid="$2" pid="$3" cls="$4"
    shift 4
    local d="$tmp/$name" i=0 c
    mkdir -p "$d"
    printf '%s\n' "$vid" >"$d/idVendor"
    printf '%s\n' "$pid" >"$d/idProduct"
    printf '%s\n' "$cls" >"$d/bDeviceClass"
    for c in "$@"; do
        mkdir -p "$d/1-2:$i.0"
        printf '%s\n' "$c" >"$d/1-2:$i.0/bInterfaceClass"
        i=$((i + 1))
    done
}

mkdev cd-iface 0bda a192 00 08 # CD-ROM via interface class
mkdev cd-class 0bda 1a2b 08 ff # CD-ROM via device class
mkdev wifi 0bda f192 00 ff
mkdev bt 0bda 8771 00 e0

check_eq "dir_mode cd via interface class" "cdrom" "$(dir_mode "$tmp/cd-iface")"
check_eq "dir_mode cd via device class" "cdrom" "$(dir_mode "$tmp/cd-class")"
check_eq "dir_mode device mode" "device" "$(dir_mode "$tmp/wifi")"
check_eq "dir_is_wifi true" "yes" "$(dir_is_wifi "$tmp/wifi" && echo yes || echo no)"
check_eq "dir_is_wifi false for bluetooth-class" "no" "$(dir_is_wifi "$tmp/bt" && echo yes || echo no)"
check_eq "dir_pid" "f192" "$(dir_pid "$tmp/wifi")"
check_eq "dir_vid" "0bda" "$(dir_vid "$tmp/wifi")"

# --- switched ID bookkeeping ---------------------------------------------
SWITCHED_IDS=()
remember_switched "0bda:f192"
remember_switched "0bda:f192"
remember_switched "2001:331d"
check_eq "remember_switched dedupes" "2" "${#SWITCHED_IDS[@]}"

# --- summary --------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))

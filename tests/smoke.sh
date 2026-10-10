#!/usr/bin/env bash
#
# Smoke tests for realtek-usb-wifi-modeswitch. These tests are safe to run: they only
# exercise read-only commands and dry-run mode.
#
# Copyright (c) 2026 秦凡东 (shell_way@foxmail.com)
# SPDX-License-Identifier: MIT
#
set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
SCRIPT="./modeswitch.sh"

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

check_exit() {
    local desc="$1" expected="$2"
    shift 2
    "$@" >/dev/null 2>&1
    local rc=$?
    if [[ "$rc" == "$expected" ]]; then
        ok "$desc"
    else
        bad "$desc (expected exit $expected, got $rc)"
    fi
}

check_contains() {
    local desc="$1" needle="$2"
    shift 2
    local out
    out=$("$@" 2>&1)
    if grep -qF -- "$needle" <<<"$out"; then
        ok "$desc"
    else
        bad "$desc (missing: $needle)"
    fi
}

# --- syntax ---------------------------------------------------------------
if bash -n "$SCRIPT"; then
    ok "bash -n $SCRIPT"
else
    bad "bash -n $SCRIPT"
fi

if bash -n install.sh; then
    ok "bash -n install.sh"
else
    bad "bash -n install.sh"
fi

# --- basic commands -------------------------------------------------------
check_exit "--help exits with 0" 0 "$SCRIPT" --help
check_exit "--version exits with 0" 0 "$SCRIPT" --version
check_exit "help command exits with 0" 0 "$SCRIPT" help
check_contains "--version prints the version" "1.0.0" "$SCRIPT" --version
check_contains "--help prints usage" "Usage:" "$SCRIPT" --help
check_contains "help command works" "Commands:" "$SCRIPT" help
check_contains "list command works" "product IDs" "$SCRIPT" list
check_contains "status command works" "kernel" "$SCRIPT" status
check_contains "-V prints the version" "modeswitch" "$SCRIPT" -V

# --- option handling ------------------------------------------------------
check_exit "unknown option exits with 2" 2 "$SCRIPT" --definitely-not-an-option
check_exit "unknown command exits with 2" 2 "$SCRIPT" frobnicate
check_exit "invalid --pid exits with 2" 2 "$SCRIPT" status --pid zz
check_exit "odd-length --message exits with 2" 2 "$SCRIPT" status --message abc
check_exit "empty --pid exits with 2" 2 "$SCRIPT" status --pid=
check_exit "empty --message exits with 2" 2 "$SCRIPT" status --message=
check_exit "unexpected extra argument exits with 2" 2 "$SCRIPT" status extra

# --- device list content --------------------------------------------------
check_contains "list includes 0bda:1a2b" "1a2b" "$SCRIPT" list
check_contains "list includes 0bda:a192" "a192" "$SCRIPT" list
check_contains "help documents the uninstall alias" "aliases: uninstall" "$SCRIPT" help

# --- aliases and extra options -------------------------------------------
check_contains "--uninstall is an alias for clean" "Removing configuration" \
    "$SCRIPT" --dry-run --uninstall
check_exit "blacklist without module exits with 2" 2 "$SCRIPT" --dry-run blacklist
check_contains "valid --message is accepted" "Switching" \
    "$SCRIPT" --dry-run --yes --no-persist \
    --message 5553424312345678000000000000061b000000020000000000000000000000 setup

# --- dry-run --------------------------------------------------------------
check_contains "dry-run setup shows the mode-switch step" "Switching" \
    "$SCRIPT" --dry-run --yes --no-persist setup
if command -v usb_modeswitch >/dev/null 2>&1; then
    check_contains "dry-run persist prints the rule" "Managed by" \
        "$SCRIPT" --dry-run --yes setup
else
    check_contains "dry-run persist handles missing usb_modeswitch" \
        "usb_modeswitch is not installed" "$SCRIPT" --dry-run --yes setup
fi
check_contains "clean dry-run works" "Removing configuration" \
    "$SCRIPT" --dry-run clean

# --- --pid / --message persistence ---------------------------------------
out=$("$SCRIPT" --dry-run --yes setup --pid a192 2>&1)
if grep -qF 'ATTR{idProduct}=="a192"' <<<"$out" &&
    ! grep -qF 'ATTR{idProduct}=="1a2b"' <<<"$out"; then
    ok "dry-run persist honours --pid"
else
    bad "dry-run persist honours --pid"
fi

out=$("$SCRIPT" --dry-run --yes --message abcdef --pid a192 setup 2>&1)
if grep -qF -- '-M abcdef' <<<"$out"; then
    ok "dry-run persist applies --message"
else
    bad "dry-run persist applies --message"
fi

# --- install.sh staging (no root required) --------------------------------
tmpinstall=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpinstall"' EXIT

if ./install.sh --destdir "$tmpinstall" --prefix /usr >/dev/null 2>&1 &&
    [[ -x "$tmpinstall/usr/bin/modeswitch" ]] &&
    "$tmpinstall/usr/bin/modeswitch" --version | grep -q '^modeswitch ' &&
    [[ -f "$tmpinstall/usr/share/man/man8/modeswitch.8" ]]; then
    ok "install.sh stages an install without root"
else
    bad "install.sh stages an install without root"
fi

if DESTDIR="$tmpinstall" ./install.sh --prefix /usr2 >/dev/null 2>&1 &&
    [[ -x "$tmpinstall/usr2/bin/modeswitch" ]]; then
    ok "install.sh honours the DESTDIR environment variable"
else
    bad "install.sh honours the DESTDIR environment variable"
fi

if ./install.sh --destdir "$tmpinstall" --bindir /opt/bin --mandir /opt/man >/dev/null 2>&1 &&
    [[ -x "$tmpinstall/opt/bin/modeswitch" && -f "$tmpinstall/opt/man/modeswitch.8" ]]; then
    ok "install.sh honours --bindir and --mandir"
else
    bad "install.sh honours --bindir and --mandir"
fi

check_contains "install.sh --dry-run prints commands" "[dry-run]" \
    ./install.sh --destdir "$tmpinstall" --prefix /usr --dry-run

check_exit "install.sh --help exits with 0" 0 ./install.sh --help
check_exit "install.sh rejects unknown options with 2" 2 ./install.sh --bogus
check_exit "install.sh rejects missing arguments with 2" 2 ./install.sh --prefix

./install.sh --destdir "$tmpinstall" --prefix /usr --uninstall >/dev/null 2>&1
if [[ ! -e "$tmpinstall/usr/bin/modeswitch" && ! -e "$tmpinstall/usr/share/man/man8/modeswitch.8" ]]; then
    ok "install.sh --uninstall removes staged files"
else
    bad "install.sh --uninstall removes staged files"
fi
rm -rf "$tmpinstall"

# --- summary --------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))

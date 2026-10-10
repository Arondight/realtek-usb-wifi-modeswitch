#!/usr/bin/env bash
#
# Installer for realtek-usb-wifi-modeswitch.
#
# Installs the modeswitch executable and its manual page. Staged installs
# (DESTDIR) and separate prefix/bindir/mandir directories are supported so the
# script can be used from distribution build recipes without root privileges.
#
# Copyright (c) 2026 秦凡东 (shell_way@foxmail.com)
# SPDX-License-Identifier: MIT
#
set -euo pipefail

PROG="modeswitch"
PREFIX="/usr/local"
DESTDIR="${DESTDIR:-}"
BINDIR=""
MANDIR=""
ACTION="install"
DRY_RUN=0

# Configuration files managed by the modeswitch tool (see 'modeswitch clean').
RULE_FILE="/etc/udev/rules.d/99-realtek-usb-wifi-modeswitch.rules"
BLACKLIST_FILE="/etc/modprobe.d/realtek-usb-wifi-modeswitch-blacklist.conf"
QUIRK_FILE="/etc/modprobe.d/realtek-usb-wifi-modeswitch-usb-storage.conf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: sudo ./install.sh [options]

Install $PROG and its manual page. Distribution packaging can stage the
install into a build root without root privileges.

Options:
  --prefix DIR    installation prefix (default: /usr/local)
  --bindir DIR    directory for the executable (default: PREFIX/bin)
  --mandir DIR    directory for the manual page (default: PREFIX/share/man/man8)
  --destdir DIR   staging root prepended to every path; also read from the
                  DESTDIR environment variable (used by package builds)
  -n, --dry-run   print what would be done, change nothing
  --uninstall     remove the installed files from the chosen locations
  -h, --help      show this help

Examples:
  sudo ./install.sh                              # install into /usr/local
  sudo ./install.sh --prefix /usr                # install into /usr
  ./install.sh --destdir /tmp/pkg --prefix /usr  # stage a package (no root)
  sudo ./install.sh --prefix /usr --uninstall    # remove an installation
EOF
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

fail_usage() {
    printf 'error: %s\n' "$1" >&2
    printf "Run '%s --help' for usage.\n" "$0" >&2
    exit 2
}

run() {
    if ((DRY_RUN)); then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

while (($#)); do
    case "$1" in
        --prefix)
            (($# >= 2)) || fail_usage "--prefix requires a directory"
            PREFIX="$2"
            shift
            ;;
        --prefix=*) PREFIX="${1#*=}" ;;
        --bindir)
            (($# >= 2)) || fail_usage "--bindir requires a directory"
            BINDIR="$2"
            shift
            ;;
        --bindir=*) BINDIR="${1#*=}" ;;
        --mandir)
            (($# >= 2)) || fail_usage "--mandir requires a directory"
            MANDIR="$2"
            shift
            ;;
        --mandir=*) MANDIR="${1#*=}" ;;
        --destdir)
            (($# >= 2)) || fail_usage "--destdir requires a directory"
            DESTDIR="$2"
            shift
            ;;
        --destdir=*) DESTDIR="${1#*=}" ;;
        -n | --dry-run) DRY_RUN=1 ;;
        --uninstall) ACTION="uninstall" ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            fail_usage "unknown option: $1"
            ;;
    esac
    shift
done

# Normalise trailing slashes so paths never contain "//".
PREFIX="${PREFIX%/}"
DESTDIR="${DESTDIR%/}"
BINDIR="${BINDIR:-$PREFIX/bin}"
MANDIR="${MANDIR:-$PREFIX/share/man/man8}"
BINDIR="${BINDIR%/}"
MANDIR="${MANDIR%/}"

if ((DRY_RUN == 0)) && [[ -z "$DESTDIR" ]] && ((EUID != 0)); then
    fail "root privileges are required (or stage with --destdir/DESTDIR)"
fi

src_script="$SCRIPT_DIR/$PROG.sh"
src_man="$SCRIPT_DIR/man/$PROG.8"

case "$ACTION" in
    install)
        [[ -f "$src_script" ]] || fail "missing $src_script"
        [[ -f "$src_man" ]] || fail "missing $src_man"
        run install -d "${DESTDIR}${BINDIR}" "${DESTDIR}${MANDIR}"
        run install -m 0755 "$src_script" "${DESTDIR}${BINDIR}/$PROG"
        run install -m 0644 "$src_man" "${DESTDIR}${MANDIR}/$PROG.8"
        if ((DRY_RUN)); then
            printf 'Dry run: no files were installed.\n'
        else
            printf 'Installed %s to %s\n' "$PROG" "${DESTDIR}${BINDIR}/$PROG"
            printf 'Installed manual page to %s\n' "${DESTDIR}${MANDIR}/$PROG.8"
            printf 'Run: sudo %s setup\n' "$PROG"
        fi
        ;;
    uninstall)
        run rm -f "${DESTDIR}${BINDIR}/$PROG" "${DESTDIR}${MANDIR}/$PROG.8"
        if ((DRY_RUN)); then
            printf 'Dry run: nothing was removed.\n'
        elif [[ -n "$DESTDIR" ]]; then
            printf 'Removed %s from %s\n' "$PROG" "$DESTDIR"
        else
            printf 'Removed %s from %s\n' "$PROG" "$PREFIX"
            printf 'Configuration files are left in place. Remove them manually:\n'
            printf '  sudo rm -f %s\n' "$RULE_FILE"
            printf '  sudo rm -f %s\n' "$BLACKLIST_FILE"
            printf '  sudo rm -f %s\n' "$QUIRK_FILE"
            printf '  sudo udevadm control --reload-rules\n'
            printf 'Tip: run "sudo %s clean" before uninstalling to remove them.\n' "$PROG"
        fi
        ;;
esac

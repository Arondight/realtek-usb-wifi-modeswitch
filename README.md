# realtek-usb-wifi-modeswitch

[![CI](https://github.com/Arondight/realtek-usb-wifi-modeswitch/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Arondight/realtek-usb-wifi-modeswitch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)

One command to fix Realtek USB Wi-Fi dongles that show up as a **CD-ROM drive** on Linux instead of a wireless adapter.

```console
$ sudo ./modeswitch.sh
==> Switching Realtek USB Wi-Fi devices to Wi-Fi mode
[ ok ] switched to Wi-Fi mode: 0bda:f192 (RTL8192FU)
==> Driver setup for 0bda:f192 (RTL8192FU)
[ ok ] loaded kernel module: 8192fu
==> Installing persistent mode-switch rule
[ ok ] the adapter will now switch automatically on plug-in and boot
```

## Contents

- [The problem](#the-problem)
- [What this tool does](#what-this-tool-does)
- [Requirements](#requirements)
- [Tested hardware and status](#tested-hardware-and-status)
- [Installation](#installation)
- [Usage](#usage)
- [Affected adapters](#affected-adapters)
- [How automatic switching works](#how-automatic-switching-works)
- [What gets changed on the system](#what-gets-changed-on-the-system)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)
- [Project layout](#project-layout)
- [Contributing](#contributing)
- [License](#license)

## The problem

Many low-cost Realtek USB Wi-Fi adapters — RTL8192FU, RTL8821CU, RTL8811CU, RTL8822BU, RTL8822CU and friends — enumerate as a USB **CD-ROM drive** the first time they are plugged in. The fake CD-ROM contains the Windows driver, and the actual Wi-Fi function stays hidden until the device is told to switch modes.

On Linux you see:

```console
$ lsusb
Bus 001 Device 008: ID 0bda:a192 Realtek Semiconductor Corp. Mass Storage Device
$ ls /dev/sr0
/dev/sr0
```

...and no wireless interface at all.

## What this tool does

1. **Detects** Realtek USB devices (`0bda:*`) that expose a mass-storage (CD-ROM) interface, using sysfs — no `lsusb` required.
2. **Switches** them to Wi-Fi mode with `usb_modeswitch`, falling back to a plain SCSI `eject` if that is not available or does not work.
3. **Finds a driver**: searches the kernel module alias tables for a module that claims the device's Wi-Fi USB ID, prefers in-kernel `rtw88`/`rtw89`/`rtl8xxxu` over out-of-tree modules, loads it and verifies the binding.
   Devices that come back under a different vendor ID (e.g. D-Link `2001:331d`) are tracked across the switch.
4. **Repairs bindings**: if the wrong driver grabbed the device, it is unbound and the correct one is bound; a dynamic USB ID is registered if the driver does not know the ID yet.
5. **Persists** the fix by installing a udev rule, so the switch happens automatically on every plug-in and at boot.
6. **Verifies** that a wireless interface actually appeared.

Works on any modern Linux distribution (Debian/Ubuntu, Fedora, openSUSE, Arch, Alpine, Kylin, ...). The script is a single self-contained Bash file that only needs Bash 4.0+ and standard Linux tools (sysfs, udev, `modprobe`); `usb_modeswitch` and `eject` are optional but recommended.

## Requirements

- Linux with udev and Bash 4.0+ (any modern distribution)
- `usb_modeswitch` (the script offers to install it; `eject` alone also works as a fallback)
- A kernel driver for your chip.
  In-kernel USB support, by kernel version:
  - `rtw88` USB (6.2+): RTL8723DU, RTL8811CU/8821CU, RTL8822BU, RTL8822CU; `rtw88` RTL8821AU/8811AU (6.13+), RTL8814AU (6.15+)
  - `rtw89` USB (6.17+): RTL8851BU, RTL8852BU; RTL8852AU/CU (6.19+), RTL8922AU (7.2+)
  - `rtl8xxxu`: RTL8192FU (6.5+), RTL8188GU and older chips
- `sudo` for `setup`, `switch`, `blacklist`, `unblacklist` and `clean`; `status`, `list`, `help` and `version` run unprivileged.

> Older kernels need an out-of-tree driver, see [docs/DRIVERS.md](docs/DRIVERS.md).

## Tested hardware and status

The project is developed and tested on:

- **Platform**: Kylin V10 SP1 (`ID=kylin`, Debian-based), kernel `5.15.0-72-generic`
- **Adapter**: generic OEM RTL8192FU 802.11n USB adapter
  - USB IDs: `0bda:a192` (CD-ROM mode) → `0bda:f192` (Wi-Fi mode)
  - Product string `802.11n  WLAN Adapter`, MAC OUI `D4:83:04` (Shenzhen FAST Technologies)
  - Driver: vendor `8192fu` (module `8192fu`, USB driver `rtl8192fu`)
- **Verified**: driver detection and binding, `status` / `list`, `--dry-run` plan, udev-rule generation, Wi-Fi scan

The exact retail model of the test adapter is unknown: it is a generic OEM dongle, and the identifiers above are everything the device reports. The test suite (`shellcheck`, `tests/smoke.sh`, `tests/unit.sh`) passes on this platform.

Other distributions are supported by design — the tool only relies on sysfs, udev and optionally `usb_modeswitch`/`eject`/`modprobe`.
Debian 14 has not been tested with real hardware; its kernel 7.2 does have in-kernel drivers for every chip listed in [docs/DRIVERS.md](docs/DRIVERS.md).

## Installation

### From a git clone (recommended)

```bash
git clone https://github.com/Arondight/realtek-usb-wifi-modeswitch.git
cd realtek-usb-wifi-modeswitch
sudo ./modeswitch.sh   # run directly, or...
sudo ./install.sh      # ...install to /usr/local/bin
sudo modeswitch setup  # ...and run from anywhere
```

`install.sh` also installs the manual page (`man modeswitch`). It accepts `--prefix`, `--bindir` and `--mandir`, so `sudo ./install.sh --prefix /usr` installs elsewhere.

For distribution packaging, see below.

### Quick smoke test without changing anything

```bash
./modeswitch.sh status            # show what is detected
./modeswitch.sh --dry-run setup   # preview the full setup
```

### Packaging

Staged installs work without root, which is what distribution build recipes need:

```bash
./install.sh --destdir "$pkgdir" --prefix /usr   # install.sh directly
make install DESTDIR="$pkgdir" PREFIX=/usr       # or via the Makefile
```

`--destdir` (or the `DESTDIR` environment variable) is prepended to every installed path; `--bindir`/`--mandir` can override the two directories individually, and `--dry-run` prints the commands without changing anything. `./install.sh --uninstall` removes the files from the same locations.

## Usage

```
modeswitch [command] [options]
```

| Command              | Description                                                                                            |
| -------------------- | ------------------------------------------------------------------------------------------------------ |
| `setup`              | Detect, switch mode, load driver, install udev rule, verify (default)                                  |
| `switch`             | Only switch devices from CD-ROM to Wi-Fi mode                                                          |
| `status`             | Show devices, modes, drivers and configuration                                                         |
| `list`               | List known install-mode product IDs                                                                    |
| `clean`              | Remove the udev rule, blacklist and usb-storage quirk created by this tool (`--uninstall` is an alias) |
| `uninstall`          | Alias for `clean`                                                                                      |
| `blacklist MOD...`   | Prevent kernel module(s) from being auto-loaded                                                        |
| `unblacklist MOD...` | Undo `blacklist`                                                                                       |
| `help` / `version`   | Help / version information                                                                             |

| Option            | Description                                                                               |
| ----------------- | ----------------------------------------------------------------------------------------- |
| `-y`, `--yes`     | Answer "yes" to all questions (non-interactive)                                           |
| `-n`, `--dry-run` | Show what would be done, change nothing; works without root too                           |
| `--no-persist`    | Do not install the udev rule                                                              |
| `--no-deps`       | Do not try to install missing packages                                                    |
| `--pid PID`       | Only handle the device with this product ID (CD-ROM or Wi-Fi mode, e.g. `a192` or `f192`) |
| `--message HEX`   | Use a custom switch message (wins over a `usb-modeswitch` config)                         |
| `--no-color`      | Disable colors (`NO_COLOR` is honoured too)                                               |
| `--color`         | Force colors                                                                              |
| `-h`, `--help`    | Show help                                                                                 |
| `-V`, `--version` | Show version information                                                                  |
| `-v`, `--verbose` | Print debug information                                                                   |

Examples:

```bash
sudo modeswitch                        # full setup
sudo modeswitch switch --pid a192      # switch one specific device
modeswitch status                      # inspect, no root needed
sudo modeswitch blacklist 8821cu       # block a conflicting module
sudo modeswitch clean                  # remove udev rule/blacklist/quirk
```

## Affected adapters

### The two CD-ROM IDs

Every Realtek ZeroCD ("Driver CDROM Mode") device found in the wild reports one of **two** product IDs while it is in CD-ROM mode. Both are registered in the Linux kernel (`drivers/usb/storage/unusual_devs.h`) and in usb-modeswitch upstream:

- `0bda:1a2b` — RTL8188GU / RTL8710BU, RTL8811CU / RTL8821CU, RTL8822BU, RTL8851BU, RTL8852AU / BU / CU, RTL8832CU, ...
- `0bda:a192` — RTL8192FU, RTL8832BU, ...

The chip cannot be identified from the CD-ROM ID alone: the same ID is used by many chips. After switching, the device re-enumerates under a new USB ID, and that ID determines the driver.

On some OEM variants the device even comes back under a **different vendor ID** (for example D-Link `2001:331d`); the tool follows the device across the switch and handles this automatically.

### Adapters reported in the wild

A non-exhaustive list of adapters known to use Realtek ZeroCD mode (all sources checked 2026-10):

- **Techkey 5B12 / 5B10** — RTL8811CU → `0bda:c811` / `0bda:c820` ([morrownr How_to_Modeswitch](https://github.com/morrownr/USB-WiFi/blob/main/home/How_to_Modeswitch.md))
- **Tenda W311MI** (some revisions) — RTL8188GU → `0bda:b711` ([brektrou/rtl8821CU#175](https://github.com/brektrou/rtl8821CU/issues/175))
- **TOTOLINK N150UA-B** — RTL8188GU → `0bda:b711` / `0bda:2005` ([McMCCRU/rtl8188gu#27](https://github.com/McMCCRU/rtl8188gu/issues/27))
- **D-Link DWA-171 rev.C** — RTL8821CU → `2001:331d` ([usb-modeswitch-data](https://www.draisberghof.de/usb_modeswitch/), [Buildroot_MiSTer#189](https://github.com/mcfbytes/Buildroot_MiSTer/issues/189))
- **D-Link DWA-X1850** — RTL8852AU → `0bda:885a` / `0bda:885c` ([morrownr How_to_Modeswitch](https://github.com/morrownr/USB-WiFi/blob/main/home/How_to_Modeswitch.md), `morrownr/rtw89` ID table)
- **ALFA AWUS036AXER / AWUS036AX** — RTL8852AU / BU → `0bda:885a` / `0bda:b832` (How_to_Modeswitch, [rtl8852bu README](https://github.com/morrownr/rtl8852bu-20250826/blob/main/README.md) multi-state list)
- **ASUS USB-AX55 Nano** — RTL8852BU → `0bda:b832` and similar ([rtl8852bu README](https://github.com/morrownr/rtl8852bu-20250826/blob/main/README.md) multi-state list)
- **Brostrend AX1L / AX4L** — RTL8852BU → `0bda:b832` and similar ([rtl8852bu README](https://github.com/morrownr/rtl8852bu-20250826/blob/main/README.md) multi-state list)
- **TP-Link Archer TX10UB Nano** — RTL8851BU → `0bda:b851` ([fofajardo/rtl8851bu#14](https://github.com/fofajardo/rtl8851bu/issues/14))
- **Generic "AX900" adapters** — RTL8851BU → `0bda:b851` ([morrownr/USB-WiFi#573](https://github.com/morrownr/USB-WiFi/issues/573))
- **TP-Link TX50UH** — RTL8852CU / RTL8832CU → `0bda:c832` and similar ([morrownr/USB-WiFi#584](https://github.com/morrownr/USB-WiFi/issues/584); multi-state warning in the [in-kernel adapter list](https://github.com/morrownr/USB-WiFi/blob/main/home/USB_WiFi_Adapters_that_are_supported_with_Linux_in-kernel_drivers.md))
- **Generic RTL8192FU dongles** — RTL8192FU → `0bda:f192` ([usb-modeswitch-data](https://www.draisberghof.de/usb_modeswitch/); this project's [test adapter](#tested-hardware-and-status))
- **Generic RTL8832BU dongles** — RTL8832BU → `0bda:b832` ([RinCat/RTL88x2BU-Linux-Driver#271](https://github.com/RinCat/RTL88x2BU-Linux-Driver/issues/271))

The exact ID depends on the chip and firmware revision, so the tool never relies on this table: it looks up the driver from whatever ID appears after the switch (`drivers_for_id` searches the kernel's module alias tables).
The full in-kernel USB ID map is in [docs/DRIVERS.md](docs/DRIVERS.md).

### Evidence and sources

Checked 2026-10 against primary sources:

- **The two ZeroCD IDs** — the Linux kernel [`drivers/usb/storage/unusual_devs.h`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/usb/storage/unusual_devs.h) has exactly two Realtek entries, both marked "Ignore driver CD mode, otherwise usb_modeswitch may fail to switch the device into Wi-Fi mode".
- **Target IDs and switch method** — usb-modeswitch-data 20251207 ships `usb_modeswitch.d/0bda:1a2b` (→ `2001:331d`, `StandardEject=1`) and `usb_modeswitch.d/0bda:a192` (→ `0bda:f192`, `StandardEject=1`); <https://www.draisberghof.de/usb_modeswitch/>.
- **Boot-hang workaround** — `morrownr/rtw89` [`usb_storage.conf`](https://github.com/morrownr/rtw89/blob/main/usb_storage.conf): `options usb_storage quirks=0bda:1a2b:i,0bda:a192:i`.
- **`0bda:1a2b` chip coverage** — GitHub reports: [`brektrou/rtl8821CU#175`](https://github.com/brektrou/rtl8821CU/issues/175), [`morrownr/USB-WiFi#573`](https://github.com/morrownr/USB-WiFi/issues/573), [`mcfbytes/Buildroot_MiSTer#189`](https://github.com/mcfbytes/Buildroot_MiSTer/issues/189), [`Calculinux/meta-calculinux#185`](https://github.com/Calculinux/meta-calculinux/pull/185).
- **`0bda:a192` chip coverage** — usb-modeswitch-data (`a192` → `f192`) and [`RinCat/RTL88x2BU-Linux-Driver#271`](https://github.com/RinCat/RTL88x2BU-Linux-Driver/issues/271) (`a192` → `b832`).
- **Wi-Fi-mode ID map** — kernel sources under [`drivers/net/wireless/realtek`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/net/wireless/realtek): `rtw88/rtw8821cu.c`, `rtw88/rtw8822bu.c`, `rtw88/rtw8822cu.c`, `rtw88/rtw8723du.c`, `rtw88/rtw8821au.c`, `rtw88/rtw8812au.c`, `rtw88/rtw8814au.c`, `rtw89/rtw8851bu.c`, `rtw89/rtw8852au.c`, `rtw89/rtw8852bu.c`, `rtw89/rtw8852cu.c`, `rtw89/rtw8922au.c`, `rtl8xxxu/core.c`.
- **D-Link `2001:331d`** — claimed by `rtw88_8821cu` ([`rtw88/rtw8821cu.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/net/wireless/realtek/rtw88/rtw8821cu.c): `USB_DEVICE_AND_INTERFACE_INFO(0x2001, 0x331d, ...)`).
- **Kernel versions** — kernel.org tag checks: rtw88 USB 6.2, rtw88 RTL8821AU/8812AU 6.13 and RTL8814AU 6.15, rtw89 USB 6.17 (RTL8851BU/8852BU), 6.19 (RTL8852AU/CU, `b831` on RTL8851BU) and 7.2 (RTL8922AU), rtl8xxxu RTL8192FU 6.5.

Adapter model names come from the linked issues and from `morrownr/USB-WiFi` (`How_to_Modeswitch.md`, driver READMEs). Product IDs are reported by the devices themselves (`lsusb`/sysfs), so the adapter-to-chip mapping is as reliable as the vendor's own labeling.

## How automatic switching works

`setup` writes `/etc/udev/rules.d/99-realtek-usb-wifi-modeswitch.rules` with one rule per known install-mode product ID:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="a192", \
  RUN+="/usr/sbin/usb_modeswitch -v 0bda -p a192 -M 55534243... -K"
```

From then on udev runs `usb_modeswitch` for the adapter as soon as it is plugged in. Remove the rule with `sudo modeswitch clean` (or `sudo ./install.sh --uninstall` for the binary itself).

## What gets changed on the system

The tool is intentionally conservative and never deletes files it did not create. Everything it writes can be removed again with `sudo modeswitch clean`:

- `/etc/udev/rules.d/99-realtek-usb-wifi-modeswitch.rules` — written by `setup`; switches ZeroCD adapters automatically on plug-in
- `/etc/modprobe.d/realtek-usb-wifi-modeswitch-blacklist.conf` — written by `blacklist`; keeps a conflicting module from being auto-loaded
- `/etc/modprobe.d/realtek-usb-wifi-modeswitch-usb-storage.conf` — created manually (see [TROUBLESHOOTING](docs/TROUBLESHOOTING.md)); keeps `usb_storage` from holding the fake CD-ROM

In addition it loads kernel modules with `modprobe`, and `switch`/`setup` send `usb_modeswitch` commands to the adapter. No other system files are touched.

## FAQ

### How is this different from `usb_modeswitch`?

`usb_modeswitch` is the low-level, vendor-neutral tool that sends a mode switch command to a multi-mode USB device. This project uses it as a backend and adds everything a Realtek Wi-Fi adapter needs around it:

- **Scope** — `usb_modeswitch` handles any multi-mode USB device (modems, dongles, ...); this project focuses on Realtek USB Wi-Fi adapters.
- **Mode switch** — the core function of `usb_modeswitch`; this project calls it and falls back to `eject` when it is unavailable.
- **Device data** — `usb-modeswitch-data` from the distribution vs. a built-in standard message plus its own device table, so no data update is required.
- **Driver discovery** — none in `usb_modeswitch`; this project scans the kernel module alias tables (`rtw88`/`rtw89`/`rtl8xxxu`/out-of-tree).
- **Driver loading and binding** — none in `usb_modeswitch`; this project loads and binds the module, repairs wrong bindings and registers dynamic IDs.
- **Persistence** — `usb_modeswitch` relies on the udev dispatcher shipped with `usb-modeswitch-data`; this project installs its own udev rule.
- **Diagnostics** — `usb_modeswitch` offers none; this project provides `status`, `list`, `--dry-run`, `--verbose`, `clean` and `blacklist`.
- **Devices that change vendor ID** — `usb_modeswitch` needs a hand-written target configuration; this project follows the device across the switch.

### Do I need `usb_modeswitch` installed?

No, but it is recommended. When it is missing the tool offers to install it (unless `--no-deps` is given) and can fall back to a plain SCSI `eject`. When an unpacked distribution config file for the adapter exists (for example under `/etc/usb_modeswitch.d/`), it is used first; otherwise the built-in standard message is sent. The installed udev rule always uses the built-in or `--message` value.

### Can I switch the adapter back to CD-ROM mode?

The device-side switch is one-way per power cycle and the tool intentionally does not try to reverse it: the adapter boots into CD-ROM mode every time it is powered on, the firmware performs the switch when it receives the switch/eject command, and there is no reverse command.

In practice:

- To get the adapter back into CD-ROM mode, unplug and re-plug it (or power-cycle the port); it will enumerate as the fake CD-ROM again.
  If the udev rule is installed it will be switched again immediately, so run `sudo modeswitch clean` first if you want it to stay in CD-ROM mode.
- Everything the tool changes on the **system** is reversible at any time with `sudo modeswitch clean` and `sudo ./install.sh --uninstall`; it never unloads kernel modules or deletes driver files.
- To leave one specific adapter alone, use `--pid`, and to run a one-off switch without installing the udev rule, use `--no-persist`.

A failed switch is not rolled back either - the tool simply retries with the next method (distribution config, standard message, USB reset, SCSI `eject`) and reports what happened, so you can re-plug and try again.

## Troubleshooting

Start with:

```bash
modeswitch status
sudo modeswitch --verbose setup
dmesg | tail -50
```

Common problems are covered in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md), including:

- the adapter stays in CD-ROM mode,
- `No module claims USB ID 0bda:...`,
- a boot hang / very slow boot when the adapter is plugged in,
- the module loads but no wireless interface appears,
- a conflicting out-of-tree driver is bound,
- Secure Boot refusing unsigned out-of-tree modules.

Driver sources for each chip are listed in [docs/DRIVERS.md](docs/DRIVERS.md).

## Uninstalling

```bash
sudo modeswitch clean        # remove udev rule + blacklist + usb-storage quirk
sudo ./install.sh --uninstall      # remove the installed binary/man page
```

`modeswitch --uninstall` is accepted as an alias for `clean`.

`clean` never unloads kernel modules or deletes driver files; reboot (or `rmmod`) if you want a completely clean state.

## Project layout

```
modeswitch.sh                the tool (single self-contained script)
install.sh                   installs the script + man page
Makefile                     make check / fmt / install / uninstall / help
man/modeswitch.8             manual page
docs/DRIVERS.md              driver sources and in-kernel USB ID map
docs/TROUBLESHOOTING.md      problem solving guide
tests/smoke.sh               safe, read-only CLI test suite
tests/unit.sh                unit tests for the helper functions
.github/workflows/ci.yml     ShellCheck + shfmt + tests + install test
.github/dependabot.yml       dependency updates
LICENSE                      MIT license
```

## Contributing

Please run `make check` (shellcheck + shfmt 3.14+ + tests) before submitting a change.

## License

[MIT](LICENSE) © 2026 秦凡东 (shell_way@foxmail.com)

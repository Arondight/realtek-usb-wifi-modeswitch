# Driver sources

After the adapter is switched out of CD-ROM mode it appears under a new product ID, and a kernel driver for that ID has to bind to it.
This page lists where to get drivers.

## In-kernel drivers

Check what your kernel already supports before installing anything:

```bash
# Which module claims your adapter's Wi-Fi product ID?
modprobe -n -c | grep -i 'v<vendor>.*p<product>d'
```

### USB ID map (mainline drivers)

All IDs below belong to vendor `0bda` (Realtek).
The ZeroCD adapters switch from `0bda:1a2b` or `0bda:a192` to one of these IDs; some OEM variants come back under the reseller's vendor ID instead (for example D-Link `2001:331d`).

> **Note**
> The Wi-Fi-mode ID varies by chip and firmware revision.
> Do not look up the driver from this list manually: `modeswitch` resolves the driver from the ID that actually appears.
> The list is a debugging reference.

- `rtw88_8723du` — `d723`
- `rtw88_8821cu` — `2006`, `8731`, `8811`, `b820`, `b82b`, `c80c`, `c811`, `c820`, `c821`, `c82a`, `c82b`
- `rtw88_8822bu` — `2102`, `b812`, `b81a`, `b82c`
- `rtw88_8822cu` — `c812`, `c82c`, `c82e`, `d820`, `d82b`
- `rtw88_8821au` — `a811`, `0811`, `0820`, `0821`, `0823`, `8822`
- `rtw88_8812au` — `8812`, `881a`, `881b`, `881c`
- `rtw88_8814au` — `8813`
- `rtw89_8851bu` — `b831`, `b851`
- `rtw89_8852au` — `8832`, `885a`, `885c`
- `rtw89_8852bu` — `a85b`, `b832`, `b83a`, `b852`, `b85a`
- `rtw89_8852cu` — `c832`, `c85a`, `c85d`
- `rtw89_8922au` — `8912`
- `rtl8xxxu` — `2005`, `b711`, `b720`, `f179`, `f192`, `318b`, and many older RTL8188/8192 IDs

### rtw88 USB (Linux 6.2+)

- **Linux 6.2** — `rtw88_8723du`, `rtw88_8821cu`, `rtw88_8822bu`, `rtw88_8822cu`: RTL8723DU, RTL8811CU/8821CU, RTL8822BU, RTL8822CU
- **Linux 6.13** — `rtw88_8812au`, `rtw88_8821au`: RTL8812AU, RTL8811AU/8821AU
- **Linux 6.15** — `rtw88_8814au`: RTL8814AU

### rtw89 USB (Linux 6.17+)

- **Linux 6.17** — `rtw89_8851bu`, `rtw89_8852bu`: RTL8851BU, RTL8852BU
- **Linux 6.19** — `rtw89_8851bu` (`b831`), `rtw89_8852au`, `rtw89_8852cu`: RTL8851BU, RTL8852AU, RTL8852CU
- **Linux 7.2** — `rtw89_8922au`: RTL8922AU

On kernels older than 6.19 the RTL8852AU/CU adapters and on kernels older than 7.2 the RTL8922AU adapters need the out-of-tree `morrownr/rtw89` driver.
Distributions that ship kernel 7.2 or newer (for example Debian 14) have in-kernel drivers for every chip listed above.

A newer kernel usually means better support.
This is the simplest fix for these adapters: update the kernel and let `modeswitch` pick the module.

### rtl8xxxu

`rtl8xxxu` is an older in-kernel driver covering several RTL8188/8192 chips.
RTL8188GU (`b711`, `2005`) has been supported for a long time; RTL8192FU (`f192`, `318b`) support was added in Linux 6.5.
RTL8723BU (`b720`) and RTL8188FU (`f179`) are covered as well.
It is selected automatically when it is the only module claiming the ID.
The out-of-tree `8192fu` driver also claims `f192`; `modeswitch` prefers the vendor `8192fu` module for that ID when both are installed.

### Nothing in the kernel?

Some chips (for example RTL8192FU before Linux 6.5, RTL8852AU/CU before Linux 6.19, or RTL8922AU before Linux 7.2) need an out-of-tree driver.
Continue below.

## Out-of-tree drivers

The best maintained index of Realtek USB drivers is:

- **morrownr/USB-WiFi** — <https://github.com/morrownr/USB-WiFi>  
  A compatibility list plus links to maintained drivers for almost every Realtek USB chip.

Common starting points:

- **RTL8811CU / RTL8821CU** — `brektrou/rtl8821CU`, `morrownr/8821cu-20210916`
- **RTL8812BU / RTL8822BU** — `morrownr/88x2bu-20210702`
- **RTL8811AU / RTL8821AU** — `morrownr/8821au-20210708`
- **RTL8812AU** — `morrownr/8812au-20210820`, `aircrack-ng/rtl8812au`
- **RTL8814AU** — `aircrack-ng/rtl8814au`
- **RTL8188EU** — `lwfinger/rtl8188eu`
- **RTL8188GU / RTL8710BU** — `McMCCRU/rtl8188gu`
- **RTL8723BU** — `lwfinger/rtl8723bu`
- **RTL8192FU** — `BrightX/rtl8192fu` (GPL-2.0)
- **RTL8851BU / RTL8852AU / RTL8852BU / RTL8852CU / RTL8922AU** — `morrownr/rtw89` (also `morrownr/rtl8852bu-20250826` for older kernels)

Most of these repositories use DKMS, which rebuilds the module automatically after every kernel update:

```bash
sudo apt-get install dkms build-essential git   # Debian/Ubuntu
git clone https://github.com/<owner>/<driver>.git
cd <driver>
sudo ./dkms-install.sh        # or: sudo make dkms_install
```

After installing a driver, run:

```bash
sudo modeswitch setup
```

The tool finds the newly installed module through the module alias table and loads it.

## Secure Boot

Unsigned out-of-tree modules are rejected by a kernel with Secure Boot enabled.
Either enroll a Machine Owner Key (MOK) and sign the module with `kmodsign`/`sign-file`, or disable Secure Boot.
In-kernel `rtw88` modules are signed by your distribution and do not have this problem.

## Conflicting modules

Several out-of-tree Realtek drivers use broad USB aliases and can grab a device that belongs to another one.
If `status` shows a device bound to the wrong driver, or a problematic module gets loaded automatically, block it:

```bash
sudo modeswitch blacklist 8821cu
sudo rmmod 8821cu     # or reboot
```

`clean` removes the blacklist file again when you no longer need it.

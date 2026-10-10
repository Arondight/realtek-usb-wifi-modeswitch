# Troubleshooting

Start by collecting the current state:

```bash
modeswitch status
lsusb -d 0bda:
dmesg | tail -50
```

## The adapter still shows as a CD-ROM drive

- Check the device is really a Realtek adapter: `lsusb -d 0bda:`.
- Run the switch manually with debug output:

  ```bash
  sudo modeswitch --verbose switch
  ```

- Some firmware revisions need a USB reset.
  The tool retries once with `usb_modeswitch -R`; you can also try unplugging and re-plugging.
- Try the eject fallback manually:

  ```bash
  sudo eject /dev/sr0          # find the device with: lsblk
  ```

- If the adapter is not detected at all, try another USB port (USB 3.0 vs 2.0 can matter) and avoid unpowered hubs.

## `No kernel module ... claims USB ID 0bda:xxxx`

The mode switch worked, but the kernel has no driver for the Wi-Fi-mode ID.

- Check `uname -r`.
  In-kernel USB support: `rtw88` (6.2+; RTL8821AU/8812AU since 6.13, RTL8814AU since 6.15), `rtw89` (6.17+ for RTL8851BU/RTL8852BU, 6.19+ for RTL8852AU/CU, 7.2+ for RTL8922AU) and `rtl8xxxu` (RTL8192FU since 6.5).
  Updating the kernel is often enough.
  The RTL8192FU ID `f192` is also claimed by the out-of-tree `8192fu` module.
- Otherwise install an out-of-tree driver — see [DRIVERS.md](DRIVERS.md).
- If you already installed a driver, make sure it is not blacklisted:

  ```bash
  modprobe -n -v <module>
  grep -r blacklist /etc/modprobe.d/
  ```

After installing the driver, run `sudo modeswitch setup` again.

## The module loads but no wireless interface appears

- Wait a few seconds and re-check: `ip link`, `modeswitch status`.
- The module may refuse this ID.
  Load the tool with `--verbose` and look for "adding dynamic ID" or binding errors.
- A conflicting driver may have bound first.
  Check `status` for `interface ... -> driver ...` and blacklist the wrong module:

  ```bash
  sudo modeswitch blacklist <wrong-module>
  sudo rmmod <wrong-module>     # or reboot
  sudo modeswitch setup
  ```

- Check `rfkill`; some laptops soft-block new wireless devices:

  ```bash
  rfkill list
  sudo rfkill unblock wifi
  ```

- `dmesg | tail -50` often shows the real reason (firmware load failure, unsupported chip revision, ...).

## Very slow boot or boot loop when the adapter is plugged in

The kernel's `usb_storage` driver can keep the fake CD-ROM busy and make `usb_modeswitch` fail.
Tell `usb_storage` to ignore the two Realtek ZeroCD IDs:

```bash
printf 'options usb_storage quirks=0bda:1a2b:i,0bda:a192:i\n' \
  | sudo tee /etc/modprobe.d/realtek-usb-wifi-modeswitch-usb-storage.conf
sudo update-initramfs -u -k all    # Debian/Ubuntu; regenerate the initramfs on other distros
```

This is the workaround recommended by the `morrownr/rtw89` project.
It is harmless for other USB storage devices.
`modeswitch clean` removes this file together with the rest of the configuration.

## The adapter re-appears with a different vendor ID

Some ZeroCD devices come back under the reseller's vendor ID after switching (for example D-Link `2001:331d`).
`modeswitch` follows the device across the switch and resolves the driver from the ID that actually appears, so this needs no extra configuration.
`status` lists Realtek devices by default; use `lsusb` to see the new ID.

## The interface exists but NetworkManager does not use it

```bash
nmcli device status
nmcli device wifi list
nmcli device wifi connect "<SSID>" password "<password>"
```

If NetworkManager marks the interface as unmanaged, check `/etc/NetworkManager/conf.d/` for a stale `unmanaged-devices` entry.

## Secure Boot

Unsigned out-of-tree modules fail with an error such as `module verification failed: signature and/or required key missing`.
See the Secure Boot section in [DRIVERS.md](DRIVERS.md).

## Automatic switching does not happen

- The udev rule is only installed by `setup` and only if `usb_modeswitch` is present:

  ```bash
  modeswitch status        # "udev rule: ..."
  cat /etc/udev/rules.d/99-realtek-usb-wifi-modeswitch.rules
  ```

- Install/reinstall it with `sudo modeswitch setup`.
- On systems where udev rules are not run during early boot, the device may already have switched by the time the rule would run — in that case it is already in Wi-Fi mode and nothing is needed.

## Multiple adapters

By default every Realtek device in CD-ROM mode is handled.
Target one adapter only with its product ID:

```bash
sudo modeswitch switch --pid a192
```

## Collecting a support report

```bash
{
  modeswitch status
  lsusb -d 0bda:
  uname -a
  cat /etc/os-release
  dmesg | tail -100
} > modeswitch-report.txt
```

Attach the file to the issue (review it first for anything private).

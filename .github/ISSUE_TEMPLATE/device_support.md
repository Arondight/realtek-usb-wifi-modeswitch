---
name: New device support
about: Report an adapter that is not handled correctly
labels: device-support
assignees: ""
---

## Adapter

- CD-ROM-mode ID (`bad` state): `0bda:____`
- Wi-Fi-mode ID after switching (`good` state): `0bda:____`
- Chip printed on the device / box:
- `lsusb` product string:

## Did it work without a device-list entry?

- [ ] Yes, the standard switch message worked
- [ ] No, I had to use a custom message (paste it below)
- [ ] No, I had to use `eject /dev/sr0`

Custom switch message (if any):

```
paste hex message here
```

## Output

<details>
<summary><code>modeswitch status</code></summary>

```
paste output here
```

</details>

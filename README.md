# Void Linux Dialog Installer

A full shell + `dialog` installer for Void Linux live systems.

### Features

- Keymap selection (common choices + custom entry)
- Networking check and hostname setup
- Locale and timezone hierarchical selection
- Disk setup:
  - Automatic GPT + Btrfs layout with Timeshift-friendly subvolumes
  - Manual partition/mount flow
- Base install + fstab generation
- Bootloader setup (`grub` for EFI or BIOS)
- Root password + regular user creation
- Optional XLibre repository setup
- Optional desktop install (`mate`, `xfce`, `lxqt`, `cinnamon`) and auto-install `octoxbps` when desktop is selected

### Requirements

- Run from Void Linux live environment as `root`
- `dialog`, `xbps-install`, `parted`, `mkfs.*`, `grub-install`, `chroot`

### Usage

```bash
chmod +x installer.sh
./installer.sh
```

The script logs to `/tmp/void-installer.log`.

### Notes

- This installer is destructive when using automatic partitioning.
- Void uses runit, not systemd; the script configures services accordingly.

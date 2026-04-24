# dex-manager

A small bash wrapper around [scrcpy](https://github.com/Genymobile/scrcpy) that makes running Samsung DeX as a window on Fedora Linux painless. It handles the virtual display setup, wireless ADB with dynamic ports, the One UI 8.5 developer settings, and keeps your preferred scrcpy flags in a config file.

All the heavy lifting is done by scrcpy itself. This is just a menu-driven wrapper that remembers your setup so you don't have to.

## What it does

- Creates a virtual display on the phone at your configured resolution and DPI, then launches scrcpy against it
- Cleans up the virtual display when scrcpy exits, so you never end up with a phantom overlay on the phone screen
- Scans the local network for ADB-capable devices so you don't have to hunt for the wireless debugging port each time
- Applies the three Samsung desktop-mode developer settings with a single menu option, no reboot required
- Keeps your flags, resolution, DPI, codec, bitrate, and wireless address in a plain shell config you can edit or version control

## Requirements

- Fedora (tested on 43, should work on 40+)
- `scrcpy` and `android-tools` (the script offers to install them via dnf on first run)
- `nmap` if you want the network scan feature (also offered on first run)
- A Samsung phone on One UI 8 or later with USB debugging enabled

## Install

```bash
git clone https://github.com/fqazzazee/dex-manager-linux.git
cd dex-manager
chmod +x dex-manager.sh
./dex-manager.sh
```

On first run the script offers to install itself to `~/.local/bin/dex-manager` and create a GNOME Activities launcher. After that you can just run `dex-manager` from anywhere, or search for "DeX Manager" in your app launcher.

## Phone setup

1. Enable developer options: Settings, About phone, Software information, tap Build number seven times
2. Enable USB debugging in Developer options
3. On One UI 8.5, temporarily disable Auto Blocker (Settings, Security and privacy, More security settings, Auto Blocker) while you authorize the laptop's RSA key, then turn it back on
4. Plug the phone in and accept the authorization prompt
5. Run `dex-manager` and pick option 5 (Apply phone developer settings) to enable desktop mode on the virtual display

## Usage

Just run `dex-manager` and pick from the menu:

```
1) Launch DeX session
2) Preview / edit launch command
3) Wireless ADB (scan / connect / manual)
4) Configure settings
5) Apply phone developer settings
6) Remove virtual display
7) Show status
```

For scripting or keyboard shortcuts, the main actions also work as direct arguments:

```bash
dex-manager launch
dex-manager wireless
dex-manager preview
dex-manager status
```

## Config

Everything lives in `~/.config/dex-manager/config`. It's a plain shell file, so you can edit it directly or use option 4 in the menu. Leaving codec, bitrate, or other fields empty tells scrcpy to use its own defaults, which often produces better quality than manual overrides.

## Wireless debugging notes

One UI 8.5 uses Android's newer wireless debugging mode under Developer options, and the port changes every time you toggle it. The script handles this by offering three connection paths: a saved address, manual entry of a current IP and port, or an nmap scan of your subnet that handshakes with any ADB-responsive host to find the phone.

## Why this exists

Read the full write-up at [blog.safeqbit.com](https://blog.safeqbit.com/samsung-dex-on-fedora-the-scrcpy-way/) for the backstory and the flag-tuning rabbit hole.

## Credits

scrcpy by [Genymobile](https://github.com/Genymobile/scrcpy) does all the real work. If you find this useful, star their repo too.

## License

MIT

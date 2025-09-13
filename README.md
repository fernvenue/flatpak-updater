# Flatpak Updater

Daily automatic updates for flatpak packages.

## Features

- [x] Automatic Flatpak package updates;
- [x] Systemd service and timer for scheduled updates;
- [x] Optional Telegram notifications with update reports;
- [x] Configurable logging levels;
- [x] Custom Telegram API endpoint support;
- [x] Progress tracking for long-running updates.

## Requirements

- `flatpak`
- `curl`
- `systemd` (for scheduled updates)

## Usage

First, download the script to `~/.local/bin`:

```bash
curl -o ~/.local/bin/flatpak-updater.sh https://raw.githubusercontent.com/fernvenue/flatpak-updater/master/flatpak-updater.sh
```

Add execute permissions:

```bash
chmod +x ~/.local/bin/flatpak-updater.sh
```

Test the script:

```bash
~/.local/bin/flatpak-updater.sh --help
```

Add systemd service and timer:

```bash
curl -o ~/.config/systemd/user/flatpak-updater.service https://raw.githubusercontent.com/fernvenue/flatpak-updater/master/flatpak-updater.service
curl -o ~/.config/systemd/user/flatpak-updater.timer https://raw.githubusercontent.com/fernvenue/flatpak-updater/master/flatpak-updater.timer
```

Enable and start the timer:

```bash
systemctl --user daemon-reload
systemctl --user enable flatpak-updater.timer --now
systemctl --user status flatpak-updater.timer
```

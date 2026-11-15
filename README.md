# Plex Auto Updater

Bash-based Plex Media Server update manager that checks the official PlexPass release API, detects available updates, checks for active streams, and automatically installs updates when Plex is idle.

Includes Telegram notifications, update cooldowns, error handling, and logging.

## Features

- **PlexPass Update Detection** — Checks the official Plex download API for the latest PlexPass release.
- **Version Comparison** — Compares installed and available versions using Debian package version comparison.
- **Active Stream Detection** — Checks Plex sessions before updating to avoid interrupting active video playback.
- **Automatic Installation** — Downloads and installs the official Plex Debian package using APT.
- **Telegram Notifications** — Sends notifications for available updates, delayed installations, errors, and successful updates.
- **Notification Cooldown** — Prevents repeated Telegram notifications while waiting for active streams to finish.
- **Update Cooldown** — Prevents unnecessary update checks immediately after a successful installation.
- **Error Handling** — Detects failures and attempts to restart Plex if an installation fails.
- **Concurrent Execution Protection** — Uses `flock` to prevent overlapping update processes.
- **Debug Logging** — Optional debug output for troubleshooting.

## Requirements

- Ubuntu / Debian Linux
- Plex Media Server (PlexPass)
- Bash
- curl
- jq
- dpkg / dpkg-deb
- apt-get
- systemd
- flock
- Telegram bot (optional, for notifications)

## Configuration

Telegram credentials are loaded from:

`/etc/watchdog/secrets.env`

Example:

```bash
TELEGRAM_TOKEN="your_bot_token"
CHAT_ID="your_chat_id"
```

Restrict access to the credentials file:

```bash
sudo chmod 600 /etc/watchdog/secrets.env
```

The Plex authentication token is extracted automatically from the Plex Media Server `Preferences.xml` file.

### Update Settings

The following settings can be adjusted in the script:

```bash
COOLDOWN_HOURS=6
```

Controls the cooldown after a successful update.

```bash
DEBUG="${DEBUG:-0}"
```

Enables optional debug logging. Disabled by default.

## Installation

Clone the repository:

```bash
git clone <repository-url>
cd plex-autoupdate
```

Make the script executable:

```bash
chmod +x plex_autoupdate.sh
```

Ensure the script has permission to access the Plex configuration, install Debian packages, and manage systemd services.

The script must run as root.

## Usage

Run manually:

```bash
sudo ./plex_autoupdate.sh
```

Enable debug logging:

```bash
sudo env DEBUG=1 ./plex_autoupdate.sh
```

Normal execution keeps routine version checks out of the log. Debug mode includes additional diagnostic information.

## Logging

Log file:

`/var/log/plex_update.log`

Cooldown files:

- `/var/log/plex_update.cooldown` — Successful update cooldown.
- `/var/log/plex_update.wait-notice` — Waiting notification cooldown.

Execution lock:

`/run/lock/plex-update.lock`

Logs include update detection, download and installation activity, errors, and successful updates.

## Execution Schedule

The updater supports both cron and systemd timers. Choose one scheduling method; do not enable both simultaneously.

### Option 1: Cron

Run the updater hourly using cron:

```cron
0 * * * * /path/to/plex_autoupdate.sh
```

Replace `/path/to/plex_autoupdate.sh` with the actual script location.

### Option 2: Systemd Timer

Example systemd unit files are included in the repository under the `systemd/` directory:

- `plex_autoupdate.service` — Executes the update script as root.
- `plex_autoupdate.timer` — Schedules the updater.

**1. Configure the service**

Edit `systemd/plex_autoupdate.service` and replace the placeholder in `ExecStart` with the full path to the updater script.

```ini
ExecStart=/path/to/plex_autoupdate.sh
```

**2. Install the unit files**

```bash
sudo cp systemd/plex_autoupdate.service /etc/systemd/system/
sudo cp systemd/plex_autoupdate.timer /etc/systemd/system/
```

**3. Enable and start the timer**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now plex_autoupdate.timer
```

The included timer configuration:

- Runs the updater 5 minutes after system boot.
- Runs again every hour after the previous service activation.

**4. Verify operation**

Check timer status:

```bash
systemctl status plex_autoupdate.timer
```

View the next scheduled execution:

```bash
systemctl list-timers plex_autoupdate.timer
```

View updater logs:

```bash
journalctl -u plex_autoupdate.service
```

Run manually through systemd:

```bash
sudo systemctl start plex_autoupdate.service
```

The updater runs as root because package installation and service management require elevated privileges. Plex Media Server itself continues running under its dedicated `plex` user.

Both scheduling methods use the same script, logging, locking, and cooldown mechanisms.

## Safety Behavior

- Never downgrades an existing Plex installation.
- Aborts if the Plex release API cannot be reached.
- Aborts if the installed or available version cannot be determined.
- Aborts if Plex sessions cannot be checked.
- Skips installation while active video streams are detected.
- Verifies the downloaded package version and architecture.
- Verifies the installed version after updating.
- Attempts to restart Plex if an installation fails.
- Sends Telegram notifications for errors and successful updates.

Plex Media Server runs under its dedicated `plex` system user. The updater runs as root only when required to install packages and manage the service.

## License

MIT

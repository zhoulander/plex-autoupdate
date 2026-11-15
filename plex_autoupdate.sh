#!/bin/bash

set -Eeuo pipefail
umask 077

# ==========================================
# CONFIGURATION
# ==========================================

LOG="/var/log/plex_update.log"
COOLDOWN_FILE="/var/log/plex_update.cooldown"
WAIT_NOTICE_FILE="/var/log/plex_update.wait-notice"

COOLDOWN_HOURS=6
SECRETS="/etc/watchdog/secrets.env"

PLEX_PREFS="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
PLEX_URL="http://127.0.0.1:32400"
PLEX_API="https://plex.tv/api/downloads/5.json"

SERVICE="plexmediaserver"

TMP_DIR=""
SERVICE_NEEDS_START=0

DEBUG="${DEBUG:-0}"

# ==========================================
# LOGGING
# ==========================================

log() {
    echo "$(date '+%F %T'): $*" >> "$LOG"
}

# ==========================================
# TELEGRAM
# ==========================================

send_telegram() {
    local payload

    payload=$(jq -nc \
        --arg chat_id "$CHAT_ID" \
        --arg text "$1" \
        '{chat_id: $chat_id, text: $text}') || return 0

    curl -fsS --connect-timeout 5 --max-time 15 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        --data "$payload" >/dev/null 2>&1 \
        || log "WARNING: Telegram notification failed."
}

# ==========================================
# ERROR HANDLING / CLEANUP
# ==========================================

debug() {
    [[ "$DEBUG" == "1" ]] && log "DEBUG: $*"
    return 0
}

die() {
    log "ERROR: $1"
    send_telegram "⚠️ Plex Update Error: $1"
    exit 1
}

on_error() {
    local rc=$1
    local line=$2
    local command=$3

    trap - ERR

    log "UNEXPECTED ERROR (exit $rc) at line $line: $command"

    send_telegram "⚠️ Plex Update Error:
Exit code: $rc
Line: $line
Command: $command"

    exit "$rc"
}

cleanup() {
    if (( SERVICE_NEEDS_START )); then
        log "Attempting to restart Plex during cleanup."

        if systemctl start "$SERVICE"; then
            log "Plex service restarted during cleanup."
        else
            log "CRITICAL: Could not restart Plex!"
            send_telegram "🚨 CRITICAL: Plex could not be restarted!"
        fi
    fi

    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
}

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ==========================================
# PRE-FLIGHT CHECKS
# ==========================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root."
    exit 1
fi

for CMD in curl jq dpkg dpkg-query dpkg-deb apt-get flock; do
    command -v "$CMD" >/dev/null 2>&1 \
        || die "Missing required command: $CMD"
done

[[ -r "$SECRETS" ]] || die "Cannot read secrets file."

source "$SECRETS"

[[ -n "${TELEGRAM_TOKEN:-}" && -n "${CHAT_ID:-}" ]] \
    || die "Missing Telegram credentials."

# ==========================================
# PREVENT OVERLAPPING EXECUTIONS
# ==========================================

exec 9>/run/lock/plex-update.lock

if ! flock -n 9; then
    log "Another Plex update process is running. Exiting."
    exit 0
fi

# ==========================================
# SUCCESSFUL UPDATE COOLDOWN
# ==========================================

if [[ -f "$COOLDOWN_FILE" ]]; then
    LAST=$(stat -c %Y "$COOLDOWN_FILE")
    NOW=$(date +%s)

    if (( NOW - LAST < COOLDOWN_HOURS * 3600 )); then
        exit 0
    fi
fi

# ==========================================
# GET PLEX TOKEN
# ==========================================

[[ -r "$PLEX_PREFS" ]] || die "Plex Preferences.xml not found."

PLEX_TOKEN=$(grep -oP 'PlexOnlineToken="\K[^"]+' "$PLEX_PREFS" || true)

[[ -n "$PLEX_TOKEN" ]] || die "Could not extract Plex token."

# ==========================================
# FETCH PLEXPASS RELEASE INFORMATION
# ==========================================

TMP_DIR=$(mktemp -d /tmp/plex-update.XXXXXX)

if ! curl -fsS --connect-timeout 15 --max-time 60 \
    --get \
    --data-urlencode "channel=plexpass" \
    --data-urlencode "X-Plex-Token=$PLEX_TOKEN" \
    "$PLEX_API" \
    -o "$TMP_DIR/releases.json"; then

    die "Could not contact Plex download API."
fi

RELEASE=$(jq -cer \
    '[.computer.Linux.releases[]? | select(.build == "linux-x86_64")][0] // empty' \
    "$TMP_DIR/releases.json") \
    || die "Could not find Linux x86_64 PlexPass release."

LAT=$(jq -er '.version' <<< "$RELEASE")
URL=$(jq -er '.url' <<< "$RELEASE")

[[ -n "$LAT" && -n "$URL" ]] \
    || die "Incomplete Plex release information."

# ==========================================
# GET INSTALLED VERSION
# ==========================================

INST=$(dpkg-query -W -f='${Version}' plexmediaserver 2>/dev/null || true)

[[ -n "$INST" ]] || die "Could not determine installed Plex version."

debug "Installed: $INST | Latest: $LAT"

# ==========================================
# VERSION COMPARISON
# ==========================================

if dpkg --compare-versions "$INST" ge "$LAT"; then
    exit 0
fi

log "UPDATE DETECTED: $INST -> $LAT"

# ==========================================
# CHECK ACTIVE PLEX SESSIONS
# ==========================================

if ! curl -fsS --connect-timeout 5 --max-time 15 \
    "$PLEX_URL/status/sessions?X-Plex-Token=$PLEX_TOKEN" \
    -o "$TMP_DIR/sessions.json"; then

    die "Could not check Plex active sessions. Update aborted for safety."
fi

ACTIVE=$(jq -er \
    '[.MediaContainer.Metadata[]? |
    select(.type == "movie" or .type == "episode" or .type == "clip" or .type == "live")] | length' \
    "$TMP_DIR/sessions.json") \
    || die "Could not parse Plex sessions."

if (( ACTIVE > 0 )); then

    log "Update postponed: $ACTIVE active video stream(s)."

    # Separate notification cooldown to prevent Telegram spam.
    SEND_NOTICE=1

    if [[ -f "$WAIT_NOTICE_FILE" ]]; then
        LAST_NOTICE=$(stat -c %Y "$WAIT_NOTICE_FILE")
        NOW=$(date +%s)

        if (( NOW - LAST_NOTICE < COOLDOWN_HOURS * 3600 )); then
            SEND_NOTICE=0
        fi
    fi

    if (( SEND_NOTICE )); then
        send_telegram "⏳ Plex update waiting. $ACTIVE active stream(s). Target: $LAT"
        touch "$WAIT_NOTICE_FILE"
    fi

    exit 0
fi

log "No active video streams. Proceeding with update."

# ==========================================
# DOWNLOAD PACKAGE
# ==========================================

send_telegram "⬇️ Downloading Plex update: $LAT"

DEB="$TMP_DIR/plex_update.deb"

if ! curl -fLsS \
    --retry 2 \
    --retry-delay 3 \
    --connect-timeout 15 \
    --max-time 900 \
    "$URL" \
    -o "$DEB"; then

    die "Plex package download failed."
fi

[[ -s "$DEB" ]] || die "Downloaded package is empty."

# ==========================================
# VERIFY DOWNLOADED PACKAGE
# ==========================================

DEB_VERSION=$(dpkg-deb -f "$DEB" Version) \
    || die "Downloaded file is not a valid Debian package."

DEB_ARCH=$(dpkg-deb -f "$DEB" Architecture) \
    || die "Could not determine package architecture."

HOST_ARCH=$(dpkg --print-architecture)

dpkg --compare-versions "$DEB_VERSION" eq "$LAT" \
    || die "Downloaded version $DEB_VERSION does not match API version $LAT."

[[ "$DEB_ARCH" == "$HOST_ARCH" ]] \
    || die "Architecture mismatch: $DEB_ARCH vs $HOST_ARCH."

log "Package verified: $DEB_VERSION ($DEB_ARCH)"

# ==========================================
# INSTALL UPDATE
# ==========================================

send_telegram "🔧 Installing Plex $LAT..."

# Ensure cleanup attempts to restart Plex even if installation fails.
SERVICE_NEEDS_START=1

systemctl stop "$SERVICE" \
    || die "Could not stop Plex service."

if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEB" >> "$LOG" 2>&1; then
    die "Plex package installation failed."
fi

# ==========================================
# RESTART PLEX
# ==========================================

systemctl start "$SERVICE" \
    || die "Plex service failed to start."

systemctl is-active --quiet "$SERVICE" \
    || die "Plex service is not active after update."

SERVICE_NEEDS_START=0

# ==========================================
# VERIFY INSTALLED VERSION
# ==========================================

NEW_INST=$(dpkg-query -W -f='${Version}' plexmediaserver 2>/dev/null || true)

[[ -n "$NEW_INST" ]] \
    || die "Could not verify installed Plex version."

dpkg --compare-versions "$NEW_INST" eq "$LAT" \
    || die "Version verification failed. Expected $LAT, got $NEW_INST."

# ==========================================
# SUCCESS
# ==========================================

touch "$COOLDOWN_FILE"

# Clear waiting notification cooldown.
rm -f "$WAIT_NOTICE_FILE"

log "SUCCESS: Plex updated from $INST to $NEW_INST."

send_telegram "✅ Plex successfully updated!
Previous: $INST
Current: $NEW_INST"

exit 0

cat > /root/nfc-setup.sh <<'SETUP'
#!/bin/sh
set -eu

BIN_SOURCE="/tmp/xinfc-src/xinfc-gui-openwrt-main/bin/xinfc-wsc-aarch64"
BIN="/usr/sbin/xinfc-wsc"
DIR="/etc/xinfc"
BACKUP_SOURCE="/tmp/xinfc-src/nfc_ndef_backup.bin"
BACKUP="$DIR/nfc_ndef_backup.bin"

echo "=== NFC SETUP ==="

# Dependencies
echo "[1/7] Installing dependencies..."
apk add libstdcpp i2c-tools

# Binary
echo "[2/7] Installing xinfc-wsc..."
if [ ! -x "$BIN" ]; then
    [ -f "$BIN_SOURCE" ] || {
        echo "ERROR: xinfc-wsc binary not found"
        exit 1
    }
    cp "$BIN_SOURCE" "$BIN"
    chmod 755 "$BIN"
fi

# Persistent directory and original backup
echo "[3/7] Preparing backup..."
mkdir -p "$DIR"

if [ ! -s "$BACKUP" ]; then
    [ -s "$BACKUP_SOURCE" ] || {
        echo "ERROR: original NFC backup not found"
        exit 1
    }
    cp "$BACKUP_SOURCE" "$BACKUP"
    chmod 600 "$BACKUP"
fi

echo "Original backup:"
ls -lh "$BACKUP"
sha256sum "$BACKUP"

# Check NFC hardware
echo "[4/7] Checking NFC chip..."
i2cdetect -y 0 | grep -q '57' || {
    echo "ERROR: NFC chip 0x57 not detected"
    exit 1
}

# Synchronization script
echo "[5/7] Creating synchronization script..."

cat > /usr/bin/nfc-sync.sh <<'SYNC'
#!/bin/sh

BIN="/usr/sbin/xinfc-wsc"
DIR="/etc/xinfc"
STATE="$DIR/current.sha256"
LOCK="/var/lock/nfc-sync.lock"

mkdir -p "$DIR" /var/lock

if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi

trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# Select first active AP, preferring radio0.
SELECTED=""

for section in $(uci -q show wireless |
    sed -n 's/^wireless\.\([^=]*\)=wifi-iface$/\1/p'); do

    mode="$(uci -q get "wireless.$section.mode" || true)"
    device="$(uci -q get "wireless.$section.device" || true)"
    disabled="$(uci -q get "wireless.$section.disabled" || true)"

    [ "$mode" = "ap" ] || continue
    [ "$disabled" = "1" ] && continue

    if [ "$device" = "radio0" ]; then
        SELECTED="$section"
        break
    fi

    [ -n "$SELECTED" ] || SELECTED="$section"
done

[ -n "$SELECTED" ] || {
    logger -t nfc-sync "No active Wi-Fi AP found"
    exit 1
}

SSID="$(uci -q get "wireless.$SELECTED.ssid" || true)"
KEY="$(uci -q get "wireless.$SELECTED.key" || true)"
ENCRYPTION="$(uci -q get "wireless.$SELECTED.encryption" || true)"

[ -n "$SSID" ] || {
    logger -t nfc-sync "SSID is empty"
    exit 1
}

[ "${#SSID}" -ge 2 ] && [ "${#SSID}" -le 28 ] || {
    logger -t nfc-sync "SSID length is unsupported by xinfc-wsc"
    exit 1
}

[ -n "$KEY" ] || {
    logger -t nfc-sync "Wi-Fi key is missing"
    exit 1
}

[ "${#KEY}" -ge 8 ] && [ "${#KEY}" -le 63 ] || {
    logger -t nfc-sync "Wi-Fi key length is unsupported by xinfc-wsc"
    exit 1
}

[ -n "$ENCRYPTION" ] || {
    logger -t nfc-sync "Wi-Fi encryption is missing"
    exit 1
}

HASH="$(printf '%s\0%s\0%s' "$SSID" "$KEY" "$ENCRYPTION" |
    sha256sum | awk '{print $1}')"

OLD_HASH="$(cat "$STATE" 2>/dev/null || true)"

if [ "$HASH" = "$OLD_HASH" ]; then
    exit 0
fi

[ -s "$DIR/nfc_ndef_backup.bin" ] || {
    logger -t nfc-sync "Original NFC backup missing; refusing to write"
    exit 1
}

logger -t nfc-sync "Updating NFC Wi-Fi profile from $SELECTED"

cd "$DIR" || exit 1

if "$BIN" 0 0x57 "$SSID" "$KEY" "$ENCRYPTION"; then
    printf '%s\n' "$HASH" > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
    logger -t nfc-sync "NFC update successful"
else
    logger -t nfc-sync "NFC update failed"
    exit 1
fi
SYNC

chmod 700 /usr/bin/nfc-sync.sh

# procd service
echo "[6/7] Creating procd service..."

cat > /etc/init.d/nfc-sync <<'SERVICE'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99

start_service() {
    /usr/bin/nfc-sync.sh
}

reload_service() {
    /usr/bin/nfc-sync.sh
}

service_triggers() {
    procd_open_trigger
    procd_add_config_trigger "config.change" "wireless" /etc/init.d/nfc-sync reload
    procd_close_trigger
}
SERVICE

chmod 755 /etc/init.d/nfc-sync

# Cron fallback
echo "[7/7] Configuring automatic checks..."

CRON="/etc/crontabs/root"
touch "$CRON"

if ! grep -Fq '/usr/bin/nfc-sync.sh' "$CRON"; then
    echo '* * * * * /usr/bin/nfc-sync.sh >/dev/null 2>&1' >> "$CRON"
fi

/etc/init.d/cron enable
/etc/init.d/cron restart

/etc/init.d/nfc-sync enable
/etc/init.d/nfc-sync start

echo
echo "=== NFC SETUP COMPLETE ==="
echo "Backup: $BACKUP"
echo "Sync: /usr/bin/nfc-sync.sh"
echo "Service: /etc/init.d/nfc-sync"
echo "Cron: every minute"
SETUP

chmod 700 /root/nfc-setup.sh

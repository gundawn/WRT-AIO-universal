
#!/bin/sh
set -eu

# ============================================================
# Xiaomi AX3000T RD03 — NFC Wi-Fi WSC installer
# OpenWrt 25.12.x / MediaTek Filogic
# ============================================================

BIN="/usr/sbin/xinfc-wsc"
DIR="/etc/xinfc"
SYNC="/usr/bin/nfc-sync.sh"
SERVICE="/etc/init.d/nfc-sync"
CRON="/etc/crontabs/root"

ARCHIVE="/tmp/xinfc-gui-openwrt.tar.gz"
WORK="/tmp/xinfc-install"
SOURCE_URL="https://ghproxy.net/https://github.com/HuntezWOTB/xinfc-gui-openwrt/archive/refs/heads/main.tar.gz"

BIN_SHA256="17aa90aba1c85b3f5763f64cc61753262b7080c4f27182f80ee2c7bc3259d924"

echo "================================================"
echo " Xiaomi AX3000T — NFC Wi-Fi setup"
echo "================================================"

# ------------------------------------------------------------
# 1. Dependencies
# ------------------------------------------------------------

echo "[1/7] Installing dependencies..."

apk add libstdcpp i2c-tools

# ------------------------------------------------------------
# 2. Download and install xinfc-wsc
# ------------------------------------------------------------

echo "[2/7] Installing xinfc-wsc..."

if [ ! -x "$BIN" ]; then
    rm -rf "$WORK"
    mkdir -p "$WORK"

    wget -O "$ARCHIVE" "$SOURCE_URL"

    tar -xzf "$ARCHIVE" -C "$WORK"

    FOUND_BIN="$WORK/xinfc-gui-openwrt-main/bin/xinfc-wsc-aarch64"

    [ -s "$FOUND_BIN" ] || {
        echo "ERROR: xinfc-wsc binary not found"
        exit 1
    }

    ACTUAL_HASH="$(sha256sum "$FOUND_BIN" | awk '{print $1}')"

    [ "$ACTUAL_HASH" = "$BIN_SHA256" ] || {
        echo "ERROR: Binary SHA256 verification failed"
        exit 1
    }

    cp "$FOUND_BIN" "$BIN"
    chmod 755 "$BIN"
fi

"$BIN" 2>&1 | head -5 || true

# ------------------------------------------------------------
# 3. NFC chip detection and backup preservation
# ------------------------------------------------------------

echo "[3/7] Checking NFC chip..."

mkdir -p "$DIR"

i2cdetect -y 0 | grep -Eq '(^|[[:space:]])57([[:space:]]|$)' || {
    echo "ERROR: NFC chip 0x57 not detected on I2C bus 0"
    exit 1
}

# Preserve an existing original backup if available.
if [ ! -s "$DIR/nfc_ndef_backup.bin" ] &&
   [ -s /tmp/xinfc-src/nfc_ndef_backup.bin ]; then
    cp /tmp/xinfc-src/nfc_ndef_backup.bin "$DIR/nfc_ndef_backup.bin"
    chmod 600 "$DIR/nfc_ndef_backup.bin"
fi

# ------------------------------------------------------------
# 4. Create synchronization script
# ------------------------------------------------------------

echo "[4/7] Creating NFC synchronization script..."

cat > "$SYNC" <<'SYNC'
#!/bin/sh

BIN="/usr/sbin/xinfc-wsc"
DIR="/etc/xinfc"
STATE="$DIR/current.sha256"
BACKUP="$DIR/nfc_ndef_backup.bin"
LOCK="/var/lock/nfc-sync.lock"

mkdir -p "$DIR" /var/lock

if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi

trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

SELECTED=""

for section in $(uci -q show wireless |
    sed -n 's/^wireless\.\([^=]*\)=wifi-iface$/\1/p'); do

    MODE="$(uci -q get "wireless.$section.mode" || true)"
    DEVICE="$(uci -q get "wireless.$section.device" || true)"
    DISABLED="$(uci -q get "wireless.$section.disabled" || true)"

    [ "$MODE" = "ap" ] || continue
    [ "$DISABLED" = "1" ] && continue

    if [ "$DEVICE" = "radio0" ]; then
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

[ -n "$KEY" ] || {
    logger -t nfc-sync "Wi-Fi key is missing"
    exit 1
}

[ "${#SSID}" -le 32 ] || {
    logger -t nfc-sync "SSID exceeds 32 characters"
    exit 1
}

[ "${#KEY}" -ge 8 ] && [ "${#KEY}" -le 63 ] || {
    logger -t nfc-sync "Wi-Fi key length is unsupported"
    exit 1
}

[ "$ENCRYPTION" = "psk2" ] || {
    logger -t nfc-sync "Unsupported encryption: $ENCRYPTION"
    exit 1
}

HASH="$(printf '%s\0%s\0%s' "$SSID" "$KEY" "$ENCRYPTION" |
    sha256sum | awk '{print $1}')"

OLD_HASH="$(cat "$STATE" 2>/dev/null || true)"

if [ "$HASH" = "$OLD_HASH" ]; then
    exit 0
fi

logger -t nfc-sync "Updating NFC Wi-Fi profile from $SELECTED"

cd "$DIR" || exit 1

if "$BIN" 0 0x57 "$SSID" "$KEY" "$ENCRYPTION"; then

    [ -s "$BACKUP" ] || {
        logger -t nfc-sync "WARNING: original NFC backup was not created"
        exit 1
    }

    printf '%s\n' "$HASH" > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"

    logger -t nfc-sync "NFC update successful"

else
    logger -t nfc-sync "NFC update failed"
    exit 1
fi
SYNC

chmod 700 "$SYNC"

# ------------------------------------------------------------
# 5. Create procd service
# ------------------------------------------------------------

echo "[5/7] Creating procd service..."

cat > "$SERVICE" <<'SERVICE'
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

chmod 755 "$SERVICE"

# ------------------------------------------------------------
# 6. Configure cron and autostart
# ------------------------------------------------------------

echo "[6/7] Configuring automatic synchronization..."

touch "$CRON"

if ! grep -Fq '/usr/bin/nfc-sync.sh' "$CRON"; then
    echo '* * * * * /usr/bin/nfc-sync.sh >/dev/null 2>&1' >> "$CRON"
fi

[ -x /etc/init.d/cron ] || {
    echo "ERROR: cron service is unavailable"
    exit 1
}

/etc/init.d/cron enable
/etc/init.d/cron restart

/etc/init.d/nfc-sync enable

# ------------------------------------------------------------
# 7. First synchronization
# ------------------------------------------------------------

echo "[7/7] Performing initial NFC synchronization..."

/etc/init.d/nfc-sync start

# ------------------------------------------------------------
# Complete
# ------------------------------------------------------------

rm -rf "$WORK"
rm -f "$ARCHIVE"

echo
echo "================================================"
echo " NFC SETUP COMPLETE"
echo "================================================"
echo "Binary:  $BIN"
echo "Sync:    $SYNC"
echo "Service: $SERVICE"
echo "Backup:  $DIR/nfc_ndef_backup.bin"
echo "Cron:    every minute"
echo
echo "NFC Wi-Fi synchronization is enabled."
echo "================================================"

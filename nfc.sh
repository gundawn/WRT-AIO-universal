
#!/bin/sh
set -eu

# ============================================================
# Xiaomi AX3000T RD03 — NFC installer and synchronization
# ============================================================

BIN="/usr/sbin/xinfc-wsc"
DIR="/etc/xinfc"
SYNC="/usr/bin/nfc-sync.sh"
SERVICE="/etc/init.d/nfc-sync"
CRON="/etc/crontabs/root"

ARCHIVE="/tmp/xinfc-gui-openwrt.tar.gz"
WORK="/tmp/xinfc-install"

URL="https://ghproxy.net/https://github.com/HuntezWOTB/xinfc-gui-openwrt/archive/refs/heads/main.tar.gz"
EXPECTED_SHA256="17aa90aba1c85b3f5763f64cc61753262b7080c4f27182f80ee2c7bc3259d924"

log() {
    echo "[NFC] $*"
}

die() {
    log "ОШИБКА: $*"
    exit 1
}

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

command -v apk >/dev/null 2>&1 || die "Не найден apk."
command -v sha256sum >/dev/null 2>&1 || die "Не найден sha256sum."
command -v uci >/dev/null 2>&1 || die "Не найден uci."

log "Установка зависимостей..."
apk add libstdcpp i2c-tools

command -v i2cdetect >/dev/null 2>&1 || die "Не установлен i2c-tools."

# ------------------------------------------------------------
# Download and verify utility
# ------------------------------------------------------------

rm -rf "$WORK"
mkdir -p "$WORK"

log "Загрузка исходников xinfc..."

wget -O "$ARCHIVE" "$URL" \
    || die "Не удалось скачать архив."

# BusyBox tar does not support --strip-components.
tar -xzf "$ARCHIVE" -C "$WORK" \
    || die "Не удалось распаковать архив."

# Locate binary regardless of archive root directory.
SOURCE_BIN="$(find "$WORK" -type f -name 'xinfc-wsc-aarch64' | head -n 1)"

[ -n "$SOURCE_BIN" ] && [ -f "$SOURCE_BIN" ] \
    || die "В архиве отсутствует xinfc-wsc-aarch64."

DOWNLOADED_SHA256="$(sha256sum "$SOURCE_BIN" | awk '{print $1}')"

[ "$DOWNLOADED_SHA256" = "$EXPECTED_SHA256" ] \
    || die "SHA256 бинарника не совпадает с ожидаемым. Установка остановлена."

mkdir -p "$DIR"

# ------------------------------------------------------------
# Preserve original NFC backup
# ------------------------------------------------------------

BACKUP="$DIR/nfc_ndef_backup.bin"

if [ ! -s "$BACKUP" ]; then

    BACKUP_SOURCE="$(find "$WORK" -type f -name 'nfc_ndef_backup.bin' | head -n 1)"

    if [ -n "$BACKUP_SOURCE" ] && [ -s "$BACKUP_SOURCE" ]; then
        cp "$BACKUP_SOURCE" "$BACKUP"
    elif [ -s /tmp/xinfc-src/nfc_ndef_backup.bin ]; then
        cp /tmp/xinfc-src/nfc_ndef_backup.bin "$BACKUP"
    else
        die "Не найдена исходная nfc_ndef_backup.bin. Запись NFC запрещена."
    fi

    chmod 600 "$BACKUP"
    log "Исходная резервная копия NFC установлена."

else
    log "Существующая резервная копия NFC сохранена без изменений."
fi

[ -s "$BACKUP" ] || die "Резервная копия NFC отсутствует или пуста."

# ------------------------------------------------------------
# Install verified binary
# ------------------------------------------------------------

cp "$SOURCE_BIN" "$BIN"
chmod 755 "$BIN"

INSTALLED_SHA256="$(sha256sum "$BIN" | awk '{print $1}')"

[ "$INSTALLED_SHA256" = "$EXPECTED_SHA256" ] \
    || die "Контрольная сумма установленного бинарника не совпадает."

log "xinfc-wsc установлен и проверен."

# ------------------------------------------------------------
# Check NFC chip
# ------------------------------------------------------------

log "Проверка I2C-шины 0, адреса 0x57..."

I2C_SCAN="$(i2cdetect -y 0 2>/dev/null || true)"

printf '%s\n' "$I2C_SCAN"

# i2cdetect bus 0:
# address 0x57 is located in row 50:, column 7 (field 9).
printf '%s\n' "$I2C_SCAN" |
    awk '$1=="50:" && $9=="57" {found=1} END {exit !found}' \
    || die "NFC-чип по адресу 0x57 на I2C-шине 0 не обнаружен."

log "NFC-чип обнаружен."

# ------------------------------------------------------------
# Create synchronization script
# ------------------------------------------------------------

cat > "$SYNC" <<'SYNC_EOF'
#!/bin/sh
set -eu

BIN="/usr/sbin/xinfc-wsc"
DIR="/etc/xinfc"
BACKUP="$DIR/nfc_ndef_backup.bin"
STATE="$DIR/current.sha256"
LOCK="/var/lock/nfc-sync.lock"

log() {
    logger -t nfc-sync "$*"
}

fail() {
    log "ОШИБКА: $*"
    exit 1
}

# ------------------------------------------------------------
# Prevent parallel execution
# ------------------------------------------------------------

mkdir -p /var/lock

if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi

trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM

# ------------------------------------------------------------
# Verify required files
# ------------------------------------------------------------

[ -x "$BIN" ] || fail "Не найден исполняемый xinfc-wsc."
[ -s "$BACKUP" ] || fail "Нет исходной резервной копии NFC."

# ------------------------------------------------------------
# Find first enabled AP section for a radio
# ------------------------------------------------------------

find_ap() {
    wanted_radio="$1"

    for section in $(uci -q show wireless |
        sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do

        device="$(uci -q get "wireless.$section.device" 2>/dev/null || true)"
        mode="$(uci -q get "wireless.$section.mode" 2>/dev/null || true)"
        disabled="$(uci -q get "wireless.$section.disabled" 2>/dev/null || true)"

        [ "$device" = "$wanted_radio" ] || continue
        [ "$mode" = "ap" ] || continue
        [ "$disabled" = "1" ] && continue

        printf '%s' "$section"
        return 0
    done

    return 1
}

# ------------------------------------------------------------
# Read radio0 configuration
# ------------------------------------------------------------

SEC0="$(find_ap radio0)" || fail "Не найден активный AP на radio0."

SSID0="$(uci -q get "wireless.$SEC0.ssid" 2>/dev/null || true)"
KEY0="$(uci -q get "wireless.$SEC0.key" 2>/dev/null || true)"
ENC0="$(uci -q get "wireless.$SEC0.encryption" 2>/dev/null || true)"

[ -n "$SSID0" ] || fail "У radio0 пустой SSID."

SSID_BYTES="$(printf '%s' "$SSID0" | wc -c | tr -d ' ')"

[ "$SSID_BYTES" -le 32 ] || fail "SSID radio0 превышает 32 байта."

# ------------------------------------------------------------
# Determine target encryption from password
#
# Non-empty password -> psk2
# Empty password    -> none
# ------------------------------------------------------------

if [ -n "$KEY0" ]; then

    KEY_BYTES="$(printf '%s' "$KEY0" | wc -c | tr -d ' ')"

    if [ "$KEY_BYTES" -ge 8 ] && [ "$KEY_BYTES" -le 63 ]; then

        TARGET_ENC="psk2"

    elif [ "$KEY_BYTES" -eq 64 ] &&
        printf '%s' "$KEY0" | grep -Eq '^[0-9A-Fa-f]{64}$'; then

        TARGET_ENC="psk2"

    else

        fail "Пароль radio0 не подходит для WPA2. Настройки не изменены."

    fi

else

    TARGET_ENC="none"

fi

# ------------------------------------------------------------
# Check radio1 matching conditions
#
# radio1 is modified only if SSID and password are identical
# to radio0.
# ------------------------------------------------------------

MATCH_RADIO1=0
SEC1="$(find_ap radio1 2>/dev/null || true)"

if [ -n "$SEC1" ]; then

    SSID1="$(uci -q get "wireless.$SEC1.ssid" 2>/dev/null || true)"
    KEY1="$(uci -q get "wireless.$SEC1.key" 2>/dev/null || true)"

    if [ "$SSID1" = "$SSID0" ] && [ "$KEY1" = "$KEY0" ]; then
        MATCH_RADIO1=1
    fi

fi

# ------------------------------------------------------------
# Normalize only encryption settings
# ------------------------------------------------------------

CHANGED=0

# radio0:
# Password present -> psk2
# Password absent -> none

if [ "$ENC0" != "$TARGET_ENC" ]; then

    uci -q set "wireless.$SEC0.encryption=$TARGET_ENC"

    CHANGED=1

    log "radio0: encryption будет изменён на $TARGET_ENC."

fi

# radio1:
# Only normalize when SSID and password match radio0.

if [ "$MATCH_RADIO1" -eq 1 ]; then

    ENC1="$(uci -q get "wireless.$SEC1.encryption" 2>/dev/null || true)"

    if [ "$ENC1" != "$TARGET_ENC" ]; then

        uci -q set "wireless.$SEC1.encryption=$TARGET_ENC"

        CHANGED=1

        log "radio1: SSID и пароль совпадают с radio0; encryption будет изменён на $TARGET_ENC."

    fi

else

    if [ -n "$SEC1" ]; then
        log "radio1: SSID или пароль отличаются; настройки radio1 не изменяются."
    fi

fi

# ------------------------------------------------------------
# Commit only when necessary
# ------------------------------------------------------------

if [ "$CHANGED" -eq 1 ]; then

    uci -q commit wireless \
        || fail "Не удалось сохранить настройки wireless."

    log "Изменения wireless сохранены. Перезагрузка Wi-Fi."

    wifi reload \
        || fail "Не удалось перезагрузить Wi-Fi."

    # NFC sync will run again after Wi-Fi reload,
    # on the next cron invocation.
    exit 0

fi

# ------------------------------------------------------------
# Calculate NFC profile hash
# ------------------------------------------------------------

PROFILE_HASH="$(
    printf '%s\n%s\n%s\n' "$SSID0" "$KEY0" "$TARGET_ENC" |
        sha256sum | awk '{print $1}'
)"

OLD_HASH="$(cat "$STATE" 2>/dev/null || true)"

if [ "$PROFILE_HASH" = "$OLD_HASH" ]; then
    exit 0
fi

# ------------------------------------------------------------
# Write NFC profile
# ------------------------------------------------------------

log "Обновление NFC-профиля."

cd "$DIR"

if "$BIN" 0 0x57 "$SSID0" "$KEY0" "$TARGET_ENC"; then

    printf '%s\n' "$PROFILE_HASH" > "$STATE"
    chmod 600 "$STATE"

    log "NFC-профиль успешно обновлён."

else

    fail "xinfc-wsc завершился с ошибкой. Хеш не обновлён."

fi

SYNC_EOF

chmod 755 "$SYNC"

# ------------------------------------------------------------
# Create init service
# ------------------------------------------------------------

cat > "$SERVICE" <<'SERVICE_EOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    /usr/bin/nfc-sync.sh
}

service_triggers() {
    procd_add_reload_trigger "wireless"
}

reload_service() {
    /usr/bin/nfc-sync.sh
}
SERVICE_EOF

chmod 755 "$SERVICE"

# ------------------------------------------------------------
# Cron: synchronize every minute
# ------------------------------------------------------------

touch "$CRON"

CRON_LINE="* * * * * /usr/bin/nfc-sync.sh >/dev/null 2>&1"

if ! grep -Fqx "$CRON_LINE" "$CRON"; then
    echo "$CRON_LINE" >> "$CRON"
fi

# ------------------------------------------------------------
# Enable services and perform initial sync
# ------------------------------------------------------------

/etc/init.d/cron enable
/etc/init.d/cron restart

/etc/init.d/nfc-sync enable
/etc/init.d/nfc-sync start

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

rm -rf "$WORK"
rm -f "$ARCHIVE"

log "Установка NFC завершена."

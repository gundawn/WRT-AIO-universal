
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
echo " Xiaomi AX3000T — Активация NFC"
echo "================================================"

# ------------------------------------------------------------
# 1. Dependencies
# ------------------------------------------------------------

echo "[1/7] Установка зависимостей"

apk add libstdcpp i2c-tools

# ------------------------------------------------------------
# 2. Download and install xinfc-wsc
# ------------------------------------------------------------

echo "[2/7] Установка драйвера"

if [ ! -x "$BIN" ]; then
    rm -rf "$WORK"
    mkdir -p "$WORK"

    wget -O "$ARCHIVE" "$SOURCE_URL"

    tar -xzf "$ARCHIVE" -C "$WORK"

    FOUND_BIN="$WORK/xinfc-gui-openwrt-main/bin/xinfc-wsc-aarch64"

    [ -s "$FOUND_BIN" ] || {
        echo "ОШИБКА! Файл не найден"
        exit 1
    }

    ACTUAL_HASH="$(sha256sum "$FOUND_BIN" | awk '{print $1}')"

    [ "$ACTUAL_HASH" = "$BIN_SHA256" ] || {
        echo "ОШИБКА! Контрольные суммы файла не совпадают"
        exit 1
    }

    cp "$FOUND_BIN" "$BIN"
    chmod 755 "$BIN"
fi

"$BIN" 2>&1 | head -5 || true

# ------------------------------------------------------------
# 3. NFC chip detection and backup preservation
# ------------------------------------------------------------

echo "[3/7] Проверка чипа"

mkdir -p "$DIR"

i2cdetect -y 0 | grep -Eq '(^|[[:space:]])57([[:space:]]|$)' || {
    echo "ОШИБКА! NFC-чип 0x57 не обнаружен на шине l2s"
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

echo "[4/7] Создание скрипта синхронизации"

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
    logger -t nfc-sync "Wi-Fi не обнаружен"
    exit 1
}

SSID="$(uci -q get "wireless.$SELECTED.ssid" || true)"
KEY="$(uci -q get "wireless.$SELECTED.key" || true)"
ENCRYPTION="$(uci -q get "wireless.$SELECTED.encryption" || true)"

[ -n "$SSID" ] || {
    logger -t nfc-sync "Имя Wi-Fi сети не обнаружено"
    exit 1
}

[ -n "$KEY" ] || {
    logger -t nfc-sync "Пароль Wi-Fi сети не обнаружен"
    exit 1
}

[ "${#SSID}" -le 32 ] || {
    logger -t nfc-sync "Имя Wi-Fi сети превышает 32 символов"
    exit 1
}

[ "${#KEY}" -ge 8 ] && [ "${#KEY}" -le 63 ] || {
    logger -t nfc-sync "Текущая длина пароля Wi-Fi не поддерживается"
    exit 1
}

[ "$ENCRYPTION" = "psk2" ] || {
    logger -t nfc-sync "Не поддерживаемый формат защиты: $ENCRYPTION"
    exit 1
}

HASH="$(printf '%s\0%s\0%s' "$SSID" "$KEY" "$ENCRYPTION" |
    sha256sum | awk '{print $1}')"

OLD_HASH="$(cat "$STATE" 2>/dev/null || true)"

if [ "$HASH" = "$OLD_HASH" ]; then
    exit 0
fi

logger -t nfc-sync "Обновление профиля NFC Wi-Fi из $SELECTED"

cd "$DIR" || exit 1

if "$BIN" 0 0x57 "$SSID" "$KEY" "$ENCRYPTION"; then

    [ -s "$BACKUP" ] || {
        logger -t nfc-sync "WARNING: original NFC backup was not created"
        exit 1
    }

    printf '%s\n' "$HASH" > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"

    logger -t nfc-sync "Данные записаны в чип"

else
    logger -t nfc-sync "Ошибка при сохранении данных в чип"
    exit 1
fi
SYNC

chmod 700 "$SYNC"

# ------------------------------------------------------------
# 5. Create procd service
# ------------------------------------------------------------

echo "[5/7] Создание задачи в планировщик"

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

echo "[6/7] Создание синхронизации"

touch "$CRON"

if ! grep -Fq '/usr/bin/nfc-sync.sh' "$CRON"; then
    echo '* * * * * /usr/bin/nfc-sync.sh >/dev/null 2>&1' >> "$CRON"
fi

[ -x /etc/init.d/cron ] || {
    echo "ОШИБКА! Планировщик не доступен"
    exit 1
}

/etc/init.d/cron enable
/etc/init.d/cron restart

/etc/init.d/nfc-sync enable

# ------------------------------------------------------------
# 7. First synchronization
# ------------------------------------------------------------

echo "[7/7] Синхронизация текущей сети в чип NFC"

/etc/init.d/nfc-sync start

# ------------------------------------------------------------
# Complete
# ------------------------------------------------------------

rm -rf "$WORK"
rm -f "$ARCHIVE"

echo
echo "================================================"
echo " УСТАНОВКА ЗАВЕРШЕНА!"
echo "================================================"
echo "Данные:  $BIN"
echo "Синхронизация:    $SYNC"
echo "Служба: $SERVICE"
echo "Бэкап:  $DIR/nfc_ndef_backup.bin"
echo "Запись в планировщик:    каждую минуту"
echo
echo "Синхронизация сети с чипом NFC применена"
echo "================================================"


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

# ------------------------------------------------------------
# 3. NFC chip detection and backup preservation
# ------------------------------------------------------------

echo "[3/7] Проверка чипа"

mkdir -p "$DIR"

i2cdetect -y 0 | grep -Eq '(^|[[:space:]])57([[:space:]]|$)' || {
    echo "ОШИБКА! NFC-чип 0x57 не обнаружен"
    exit 1
}

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

# ------------------------------------------------------------
# Find active AP sections for radio0 and radio1
# ------------------------------------------------------------

RADIO0=""
RADIO1=""

for section in $(uci -q show wireless |
    sed -n 's/^wireless\.\([^=]*\)=wifi-iface$/\1/p'); do

    MODE="$(uci -q get "wireless.$section.mode" || true)"
    DEVICE="$(uci -q get "wireless.$section.device" || true)"
    DISABLED="$(uci -q get "wireless.$section.disabled" || true)"

    [ "$MODE" = "ap" ] || continue
    [ "$DISABLED" = "1" ] && continue

    case "$DEVICE" in
        radio0)
            [ -n "$RADIO0" ] || RADIO0="$section"
            ;;
        radio1)
            [ -n "$RADIO1" ] || RADIO1="$section"
            ;;
    esac
done

[ -n "$RADIO0" ] || {
    logger -t nfc-sync "Активная точка доступа radio0 не обнаружена"
    exit 1
}

SSID0="$(uci -q get "wireless.$RADIO0.ssid" || true)"
KEY0="$(uci -q get "wireless.$RADIO0.key" || true)"
ENC0="$(uci -q get "wireless.$RADIO0.encryption" || true)"

[ -n "$SSID0" ] || {
    logger -t nfc-sync "SSID radio0 не обнаружен"
    exit 1
}

[ "${#SSID0}" -le 32 ] || {
    logger -t nfc-sync "SSID превышает 32 символа"
    exit 1
}

# ------------------------------------------------------------
# Validate WPA2 key
# ------------------------------------------------------------

valid_wpa2_key() {
    [ "${#1}" -ge 8 ] && [ "${#1}" -le 63 ]
}

# ------------------------------------------------------------
# Process radio0
# ------------------------------------------------------------

case "$ENC0" in

    psk2)
        valid_wpa2_key "$KEY0" || {
            logger -t nfc-sync "Некорректный пароль WPA2 на radio0"
            exit 1
        }
        ;;

    none)
        KEY0=""
        ;;

    *)
        logger -t nfc-sync "radio0: режим $ENC0 не поддерживается"

        valid_wpa2_key "$KEY0" || {
            logger -t nfc-sync "radio0: существующий пароль не подходит для WPA2. Настройки не изменены"
            exit 1
        }

        uci set "wireless.$RADIO0.encryption=psk2"

        # ----------------------------------------------------
        # Process radio1 only if SSID and password match
        # ----------------------------------------------------

        if [ -n "$RADIO1" ]; then
            SSID1="$(uci -q get "wireless.$RADIO1.ssid" || true)"
            KEY1="$(uci -q get "wireless.$RADIO1.key" || true)"
            ENC1="$(uci -q get "wireless.$RADIO1.encryption" || true)"

            if [ "$SSID0" = "$SSID1" ] && [ "$KEY0" = "$KEY1" ]; then

                if [ "$ENC1" != "psk2" ]; then
                    uci set "wireless.$RADIO1.encryption=psk2"
                    logger -t nfc-sync "radio1: совпадающая сеть переведена на WPA2"
                fi

            else
                logger -t nfc-sync "radio1: SSID или пароль отличаются, настройки не изменены"
            fi
        fi

        uci commit wireless

        logger -t nfc-sync "radio0 переведён на WPA2. Применение настроек"

        wifi reload

        # Запись NFC будет выполнена следующим запуском.
        exit 0
        ;;

esac

# ------------------------------------------------------------
# Check NFC profile changes
# ------------------------------------------------------------

HASH="$(printf '%s\0%s\0%s' "$SSID0" "$KEY0" "$ENC0" |
    sha256sum | awk '{print $1}')"

OLD_HASH="$(cat "$STATE" 2>/dev/null || true)"

if [ "$HASH" = "$OLD_HASH" ]; then
    exit 0
fi

logger -t nfc-sync "Обновление NFC-профиля radio0 (режим: $ENC0)"

cd "$DIR" || exit 1

# ------------------------------------------------------------
# Write NFC profile
# ------------------------------------------------------------

if "$BIN" 0 0x57 "$SSID0" "$KEY0" "$ENC0"; then

    [ -s "$BACKUP" ] || {
        logger -t nfc-sync "WARNING: оригинальная резервная копия NFC отсутствует"
        exit 1
    }

    printf '%s\n' "$HASH" > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"

    logger -t nfc-sync "NFC-профиль успешно записан"

else
    logger -t nfc-sync "Ошибка записи NFC"
    exit 1
fi
SYNC

chmod 700 "$SYNC"

# ------------------------------------------------------------
# 5. Create procd service
# ------------------------------------------------------------

echo "[5/7] Создание службы"

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

echo "[6/7] Настройка планировщика"

touch "$CRON"

if ! grep -Fq '/usr/bin/nfc-sync.sh' "$CRON"; then
    echo '* * * * * /usr/bin/nfc-sync.sh >/dev/null 2>&1' >> "$CRON"
fi

[ -x /etc/init.d/cron ] || {
    echo "ОШИБКА! Планировщик недоступен"
    exit 1
}

/etc/init.d/cron enable
/etc/init.d/cron restart

/etc/init.d/nfc-sync enable

# ------------------------------------------------------------
# 7. First synchronization
# ------------------------------------------------------------

echo "[7/7] Синхронизация Wi-Fi с NFC"

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
echo "Бинарник:        $BIN"
echo "Синхронизация:   $SYNC"
echo "Служба:          $SERVICE"
echo "Резервная копия: $BACKUP"
echo "Cron:            каждую минуту"
echo
echo "================================================"

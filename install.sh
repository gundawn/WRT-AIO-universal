#!/bin/sh
set -u

NETSHIFT_INSTALL_URL="https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh"

SINGBOX_RELEASE_TAG="v1.14.0-extended-2.7.1"
SINGBOX_RELEASE_API="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/${SINGBOX_RELEASE_TAG}"

RELEASE_ARCH=""
PKG_MANAGER=""
PACKAGE_EXT=""
PKG_ARCH=""

MIN_FLASH_MB=50
FLASH_OK=0

TMP_DIR="/tmp/wrt-aio"
SINGBOX_FILE=""

CRON_FILE="/etc/crontabs/root"
CRON_REBOOT_LINE="0 5 * * * /sbin/reboot"
CRON_AUTO_UPDATE_LINE="* */5 * * * apk update && apk upgrade"

PACKAGES_UPDATE_STATUS="ОТМЕНА"
PACKAGES_STATUS="ОТМЕНА"
BASE_RU_STATUS="ОТМЕНА"
TIMEZONE_STATUS="ОТМЕНА"
NETWORK_ACCELERATION_STATUS="ОТМЕНА"
SINGBOX_STATUS="ОТМЕНА"
NETSHIFT_STATUS="ОТМЕНА"
CRON_STATUS="ОТМЕНА"
AUTO_UPDATE_CRON_STATUS="ОТМЕНА"


cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM


ok() {
    printf '[ OK ] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1"
}

skip() {
    printf '[ПРОПУСК] %s\n' "$1"
}


if [ "$(id -u)" != "0" ]; then
    echo "Скрипт необходимо запускать от root."
    exit 1
fi


if [ ! -f /etc/openwrt_release ]; then
    echo "Это не OpenWrt."
    exit 1
fi

. /etc/openwrt_release


detect_package_manager() {
    if command -v apk >/dev/null 2>&1; then
        case "$(command -v apk)" in
            /opt/bin/*)
                ;;
            *)
                PKG_MANAGER="apk"
                PACKAGE_EXT="apk"
                return 0
                ;;
        esac
    fi

    if command -v opkg >/dev/null 2>&1; then
        case "$(command -v opkg)" in
            /opt/bin/*)
                ;;
            *)
                PKG_MANAGER="opkg"
                PACKAGE_EXT="ipk"
                return 0
                ;;
        esac
    fi

    return 1
}


if ! detect_package_manager; then
    echo "Не найден системный apk или opkg."
    exit 1
fi


detect_arch() {
    case "$(uname -m)" in
        aarch64)
            PKG_ARCH="aarch64"
            RELEASE_ARCH="aarch64"
            ;;
        armv7l|armv7*)
            PKG_ARCH="armv7"
            RELEASE_ARCH="armv7"
            ;;
        x86_64)
            PKG_ARCH="x86_64"
            RELEASE_ARCH="amd64"
            ;;
        *)
            PKG_ARCH="$(uname -m)"
            RELEASE_ARCH="$(uname -m)"
            ;;
    esac
}

detect_arch

mkdir -p "$TMP_DIR"


pkg_update() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk update
    else
        opkg update
    fi
}


pkg_upgrade() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk upgrade
    else
        opkg upgrade
    fi
}


pkg_install_name() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add "$@"
    else
        opkg install "$@"
    fi
}


pkg_remove() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk del "$@"
    else
        opkg remove "$@"
    fi
}


pkg_installed() {
    pkg="$1"

    if [ "$PKG_MANAGER" = "apk" ]; then
        apk list --installed 2>/dev/null | grep -q "^${pkg}-"
    else
        opkg list-installed 2>/dev/null | grep -q "^${pkg} "
    fi
}


echo ""
echo "Обновление списков пакетов..."

if pkg_update; then
    PACKAGES_UPDATE_STATUS="OK"
    ok "Списки пакетов обновлены."
else
    PACKAGES_UPDATE_STATUS="ОШИБКА"
    fail "Не удалось обновить списки пакетов."
fi


echo ""
echo "Обновление установленных пакетов..."

if pkg_upgrade; then
    PACKAGES_STATUS="OK"
    ok "Пакеты обновлены."
else
    PACKAGES_STATUS="ОШИБКА"
    fail "Не удалось обновить пакеты."
fi


echo ""
echo "Установка русской локализации LuCI..."

if pkg_install_name luci-i18n-base-ru; then
    BASE_RU_STATUS="OK"
    ok "Русская локализация LuCI установлена."
else
    BASE_RU_STATUS="ОШИБКА"
    fail "Не удалось установить luci-i18n-base-ru."
fi


echo ""
echo "Настройка часового пояса..."

if command -v uci >/dev/null 2>&1; then
    uci set system.@system[0].zonename='Asia/Yekaterinburg'
    uci set system.@system[0].timezone='+05'
    uci commit system

    if [ -x /etc/init.d/sysntpd ]; then
        /etc/init.d/sysntpd enable >/dev/null 2>&1 || true
        /etc/init.d/sysntpd restart >/dev/null 2>&1 || \
            /etc/init.d/sysntpd start >/dev/null 2>&1 || true
    fi

    CURRENT_ZONE="$(uci get system.@system[0].zonename 2>/dev/null || true)"
    CURRENT_TZ="$(uci get system.@system[0].timezone 2>/dev/null || true)"

    if [ "$CURRENT_ZONE" = "Asia/Yekaterinburg" ] &&
       [ "$CURRENT_TZ" = "+05" ]; then
        TIMEZONE_STATUS="OK"
        ok "Часовой пояс: Asia/Yekaterinburg (+05)."
    else
        TIMEZONE_STATUS="ОШИБКА"
        fail "Не удалось подтвердить часовой пояс."
    fi
else
    TIMEZONE_STATUS="ОШИБКА"
    fail "Не найден uci."
fi


echo ""
echo "Настройка сетевого ускорения..."

CURRENT_FLOW="$(uci get firewall.@defaults[0].flow_offloading 2>/dev/null || true)"
CURRENT_HW="$(uci get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || true)"
CURRENT_STEERING="$(uci get network.globals.packet_steering 2>/dev/null || true)"
CURRENT_FLOWS="$(uci get network.globals.steering_flows 2>/dev/null || true)"

if [ "$CURRENT_HW" = "1" ] &&
   [ "$CURRENT_FLOW" = "0" ] &&
   [ "$CURRENT_STEERING" = "2" ] &&
   [ "$CURRENT_FLOWS" = "128" ]; then

    NETWORK_ACCELERATION_STATUS="OK"
    ok "Аппаратное ускорение уже настроено."

elif [ "$CURRENT_HW" = "0" ] &&
     [ "$CURRENT_FLOW" = "1" ] &&
     [ "$CURRENT_STEERING" = "2" ] &&
     [ "$CURRENT_FLOWS" = "128" ]; then

    NETWORK_ACCELERATION_STATUS="OK"
    ok "Программное ускорение уже настроено."

else
    printf '%s\n' "1) Программное Flow Offloading"
    printf '%s\n' "2) Аппаратное Flow Offloading"
    printf 'Ваш выбор [1-2]: '

    read -r OFFLOAD_CHOICE

    case "$OFFLOAD_CHOICE" in
        1)
            uci set firewall.@defaults[0].flow_offloading='1'
            uci set firewall.@defaults[0].flow_offloading_hw='0'
            uci set network.globals.packet_steering='2'
            uci set network.globals.steering_flows='128'

            uci commit firewall
            uci commit network

            if [ "$(uci get firewall.@defaults[0].flow_offloading 2>/dev/null)" = "1" ] &&
               [ "$(uci get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)" = "0" ] &&
               [ "$(uci get network.globals.packet_steering 2>/dev/null)" = "2" ] &&
               [ "$(uci get network.globals.steering_flows 2>/dev/null)" = "128" ]; then
                NETWORK_ACCELERATION_STATUS="OK"
                ok "Программное ускорение включено."
            else
                NETWORK_ACCELERATION_STATUS="ОШИБКА"
                fail "Не удалось подтвердить настройки программного ускорения."
            fi
            ;;

        2)
            uci set firewall.@defaults[0].flow_offloading='0'
            uci set firewall.@defaults[0].flow_offloading_hw='1'
            uci set network.globals.packet_steering='2'
            uci set network.globals.steering_flows='128'

            uci commit firewall
            uci commit network

            if [ "$(uci get firewall.@defaults[0].flow_offloading 2>/dev/null)" = "0" ] &&
               [ "$(uci get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)" = "1" ] &&
               [ "$(uci get network.globals.packet_steering 2>/dev/null)" = "2" ] &&
               [ "$(uci get network.globals.steering_flows 2>/dev/null)" = "128" ]; then
                NETWORK_ACCELERATION_STATUS="OK"
                ok "Аппаратное ускорение включено."
            else
                NETWORK_ACCELERATION_STATUS="ОШИБКА"
                fail "Не удалось подтвердить настройки аппаратного ускорения."
            fi
            ;;

        *)
            NETWORK_ACCELERATION_STATUS="ОШИБКА"
            fail "Неверный выбор. Допустимы только 1 или 2."
            ;;
    esac
fi


echo ""
echo "Проверка flash..."

FLASH_TOTAL_KB="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $2}')"

if [ -n "$FLASH_TOTAL_KB" ]; then
    FLASH_TOTAL_MB=$((FLASH_TOTAL_KB / 1024))

    echo "Общий размер /overlay: ${FLASH_TOTAL_MB} MB"
    echo "Минимальный порог: ${MIN_FLASH_MB} MB"

    if [ "$FLASH_TOTAL_MB" -ge "$MIN_FLASH_MB" ]; then
        FLASH_OK=1
        ok "Размер flash подходит."
    else
        FLASH_OK=0
        skip "Размер flash меньше ${MIN_FLASH_MB} MB."
    fi
else
    FLASH_OK=0
    skip "Не удалось определить размер flash."
fi


echo ""
echo "Установка sing-box-extended ${SINGBOX_RELEASE_TAG}..."

if [ "$FLASH_OK" -eq 0 ]; then
    SINGBOX_STATUS="ПРОПУСК"
    skip "sing-box-extended пропущен из-за размера flash."
else
    SINGBOX_JSON="$TMP_DIR/singbox.json"

    if wget -qO "$SINGBOX_JSON" "$SINGBOX_RELEASE_API"; then

        if [ "$PKG_MANAGER" = "apk" ]; then
            SINGBOX_FILE="$(
                grep -o '"browser_download_url": "[^"]*\.apk"' "$SINGBOX_JSON" |
                grep -E "$RELEASE_ARCH|aarch64|arm64" |
                head -n 1 |
                sed 's/.*"browser_download_url": "//; s/"$//'
            )"
        else
            SINGBOX_FILE="$(
                grep -o '"browser_download_url": "[^"]*\.ipk"' "$SINGBOX_JSON" |
                grep -E "$RELEASE_ARCH|aarch64|arm64" |
                head -n 1 |
                sed 's/.*"browser_download_url": "//; s/"$//'
            )"
        fi

        if [ -n "$SINGBOX_FILE" ]; then
            SINGBOX_LOCAL="$TMP_DIR/$(basename "$SINGBOX_FILE")"

            if wget -qO "$SINGBOX_LOCAL" "$SINGBOX_FILE"; then

                if pkg_installed sing-box-extended; then
                    msg "Удаление старого sing-box-extended..."
                    pkg_remove sing-box-extended >/dev/null 2>&1 || true
                fi

                if [ "$PKG_MANAGER" = "apk" ]; then
                    if apk add --allow-untrusted "$SINGBOX_LOCAL"; then
                        SINGBOX_STATUS="OK"
                        ok "sing-box-extended ${SINGBOX_RELEASE_TAG} установлен."
                    else
                        SINGBOX_STATUS="ОШИБКА"
                        fail "Не удалось установить sing-box-extended."
                    fi
                else
                    if opkg install --force-downgrade --force-reinstall "$SINGBOX_LOCAL"; then
                        SINGBOX_STATUS="OK"
                        ok "sing-box-extended ${SINGBOX_RELEASE_TAG} установлен."
                    else
                        SINGBOX_STATUS="ОШИБКА"
                        fail "Не удалось установить sing-box-extended."
                    fi
                fi
            else
                SINGBOX_STATUS="ОШИБКА"
                fail "Не удалось скачать sing-box-extended."
            fi
        else
            SINGBOX_STATUS="ОШИБКА"
            fail "Не найден подходящий пакет sing-box."
        fi
    else
        SINGBOX_STATUS="ОШИБКА"
        fail "Не удалось получить информацию о релизе sing-box."
    fi
fi


echo ""
echo "Установка NetShift..."

if [ "$FLASH_OK" -eq 0 ]; then
    NETSHIFT_STATUS="ПРОПУСК"
    skip "NetShift пропущен из-за размера flash."
else
    NETSHIFT_INSTALLER="$TMP_DIR/netshift-install.sh"

    if wget -qO "$NETSHIFT_INSTALLER" "$NETSHIFT_INSTALL_URL"; then
        chmod +x "$NETSHIFT_INSTALLER"

        if printf '%s\n' "2" "y" | sh "$NETSHIFT_INSTALLER"; then
            NETSHIFT_STATUS="OK"
            ok "NetShift установлен."
        else
            NETSHIFT_STATUS="ОШИБКА"
            fail "Установщик NetShift завершился с ошибкой."
        fi
    else
        NETSHIFT_STATUS="ОШИБКА"
        fail "Не удалось скачать установщик NetShift."
    fi
fi


echo ""
echo "Настройка cron..."

touch "$CRON_FILE"

sed -i '\|0 5 \* \* \* /sbin/reboot|d' "$CRON_FILE"
sed -i '\|\* \*/5 \* \* \* apk update && apk upgrade|d' "$CRON_FILE"

printf '%s\n' "$CRON_REBOOT_LINE" >> "$CRON_FILE"
printf '%s\n' "$CRON_AUTO_UPDATE_LINE" >> "$CRON_FILE"

if grep -Fqx "$CRON_REBOOT_LINE" "$CRON_FILE" &&
   grep -Fqx "$CRON_AUTO_UPDATE_LINE" "$CRON_FILE"; then

    CRON_STATUS="OK"
    AUTO_UPDATE_CRON_STATUS="OK"

    ok "Перезагрузка: $CRON_REBOOT_LINE"
    ok "Автообновление: $CRON_AUTO_UPDATE_LINE"
else
    CRON_STATUS="ОШИБКА"
    AUTO_UPDATE_CRON_STATUS="ОШИБКА"

    fail "Не удалось проверить cron."
fi

if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron enable >/dev/null 2>&1 || true
    /etc/init.d/cron restart >/dev/null 2>&1 || \
        /etc/init.d/cron start >/dev/null 2>&1 || true
fi


echo ""
echo "УСТАНОВКА ЗАВЕРШЕНА!"

printf '%-30s %s\n' "Обновление списков:" "$PACKAGES_UPDATE_STATUS"
printf '%-30s %s\n' "Обновление пакетов:" "$PACKAGES_STATUS"
printf '%-30s %s\n' "Русская локализация:" "$BASE_RU_STATUS"
printf '%-30s %s\n' "Часовой пояс:" "$TIMEZONE_STATUS"
printf '%-30s %s\n' "Сетевое ускорение:" "$NETWORK_ACCELERATION_STATUS"
printf '%-30s %s\n' "sing-box-extended:" "$SINGBOX_STATUS"
printf '%-30s %s\n' "NetShift:" "$NETSHIFT_STATUS"
printf '%-30s %s\n' "Cron перезагрузка:" "$CRON_STATUS"
printf '%-30s %s\n' "Cron автообновление:" "$AUTO_UPDATE_CRON_STATUS"

echo ""
echo "Готово."
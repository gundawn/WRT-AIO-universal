#!/bin/sh

set -u

NETSHIFT_INSTALL_URL="https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh"

TMP_DIR="/tmp/wrt-aio"

CRON_FILE="/etc/crontabs/root"
CRON_REBOOT_LINE="0 5 * * * /sbin/reboot"
CRON_AUTO_UPDATE_LINE="0 */5 * * * apk update && apk upgrade"

PACKAGES_UPDATE_STATUS="ОТМЕНА"
PACKAGES_STATUS="ОТМЕНА"
BASE_RU_STATUS="ОТМЕНА"
TIMEZONE_STATUS="ОТМЕНА"
NETWORK_ACCELERATION_STATUS="ОТМЕНА"
LOCAL_APK_STATUS="ОТМЕНА"
NETSHIFT_STATUS="ОТМЕНА"
CRON_STATUS="ОТМЕНА"
AUTO_UPDATE_CRON_STATUS="ОТМЕНА"

RED='\033[31m'
GREEN='\033[32m'
RESET='\033[0m'

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

log() {
    printf '[*] %s\n' "$1"
}

ok() {
    printf "${GREEN}[+] %s${RESET}\n" "$1"
}

warn() {
    printf "${RED}[!] %s${RESET}\n" "$1"
}

err() {
    printf "${RED}[-] %s${RESET}\n" "$1" >&2
}

status() {
    value="$1"

    case "$value" in
        OK)
            printf "${GREEN}%s${RESET}" "$value"
            ;;
        *)
            printf "${RED}%s${RESET}" "$value"
            ;;
    esac
}

if [ "$(id -u)" -ne 0 ]; then
    err "Скрипт должен быть запущен от root"
    exit 1
fi

mkdir -p "$TMP_DIR" || {
    err "Не удалось создать $TMP_DIR!"
    exit 1
}

if ! command -v apk >/dev/null 2>&1 ||
    command -v apk 2>/dev/null | grep -q '^/opt/bin/'; then
    err "Не удалось определить системный пакетный менеджер apk."
    exit 1
fi

log "Обнаружен менеджер пакетов: apk"

pkg_installed() {
    package="$1"
    apk info -e "$package" >/dev/null 2>&1
}

pkg_install() {
    package="$1"
    apk add "$package"
}

pkg_update_lists() {
    if apk update >"$TMP_DIR/pkg-update.log" 2>&1; then
        return 0
    else
        cat "$TMP_DIR/pkg-update.log"
        return 1
    fi
}

pkg_upgrade_all() {
    if apk upgrade --available >"$TMP_DIR/pkg-upgrade.log" 2>&1; then
        return 0
    else
        cat "$TMP_DIR/pkg-upgrade.log"
        return 1
    fi
}

fetch_file() {
    url="$1"
    output="$2"

    rm -f "$output"

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url" 2>/dev/null &&
            [ -s "$output" ] &&
            return 0

        rm -f "$output"

        wget -q --no-check-certificate -O "$output" "$url" 2>/dev/null &&
            [ -s "$output" ] &&
            return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$output" "$url" 2>/dev/null &&
            [ -s "$output" ] &&
            return 0

        rm -f "$output"

        curl -kfsSL -o "$output" "$url" 2>/dev/null &&
            [ -s "$output" ] &&
            return 0
    fi

    rm -f "$output"
    return 1
}

run_netshift_installer() {
    installer="$TMP_DIR/netshift-installer.sh"

    if ! fetch_file "$NETSHIFT_INSTALL_URL" "$installer"; then
        return 1
    fi

    chmod 700 "$installer" || return 1

    sh "$installer"
}

configure_timezone() {
    log "Настройка часового пояса и времени"

    CURRENT_ZONENAME="$(
        uci -q get system.@system[0].zonename 2>/dev/null || true
    )"

    CURRENT_TIMEZONE="$(
        uci -q get system.@system[0].timezone 2>/dev/null || true
    )"

    if [ "$CURRENT_ZONENAME" = "Asia/Yekaterinburg" ] &&
        [ "$CURRENT_TIMEZONE" = "+05" ]; then

        ok "Часовой пояс уже настроен"
    else
        if uci set system.@system[0].zonename='Asia/Yekaterinburg' &&
            uci set system.@system[0].timezone='+05' &&
            uci commit system; then

            ok "Часовой пояс GMT+5 установлен"
        else
            warn "Не удалось установить часовой пояс"
        fi
    fi

    VERIFY_ZONENAME="$(
        uci -q get system.@system[0].zonename 2>/dev/null || true
    )"

    VERIFY_TIMEZONE="$(
        uci -q get system.@system[0].timezone 2>/dev/null || true
    )"

    if [ "$VERIFY_ZONENAME" = "Asia/Yekaterinburg" ] &&
        [ "$VERIFY_TIMEZONE" = "+05" ]; then

        TIMEZONE_STATUS="OK"
    else
        warn "Не удалось проверить часовой пояс"
    fi

    if [ -x /etc/init.d/sysntpd ]; then
        /etc/init.d/sysntpd enable >/dev/null 2>&1 || true
        /etc/init.d/sysntpd restart >/dev/null 2>&1 || true
    fi
}

configure_network_acceleration() {
    log "Определение платформы для сетевого ускорения"

    DEVICE_COMPATIBLE="$(
        tr '\000' '\n' < /proc/device-tree/compatible 2>/dev/null |
            tr '[:upper:]' '[:lower:]' |
            tr '\n' ' ' ||
            true
    )"

    PLATFORM=""
    OFFLOAD_MODE="software"

    case "$DEVICE_COMPATIBLE" in
        *qcom*|*qualcomm*|*ipq*)
            PLATFORM="qcom"
            OFFLOAD_MODE="software"
            ;;
        *mediatek*|*filogic*|*mt*)
            PLATFORM="mediatek/filogic"
            OFFLOAD_MODE="hardware"
            ;;
        *)
            PLATFORM="unknown"
            OFFLOAD_MODE="software"
            ;;
    esac

    if [ "$PLATFORM" = "unknown" ]; then
        warn "Не удалось определить процессор, используется программное ускорение"
    else
        log "Обнаружен процессор: $PLATFORM"
    fi

    STEERING_OK=0
    FLOWS_OK=0
    OFFLOAD_OK=0

    if [ "$OFFLOAD_MODE" = "software" ]; then
        log "Включается программное ускорение"

        if uci set firewall.@defaults[0].flow_offloading='1' &&
            uci set firewall.@defaults[0].flow_offloading_hw='0'; then
            ok "Программное ускорение применено"
        else
            warn "Не удалось настроить программное ускорение"
        fi
    else
        log "Включается аппаратное ускорение"

        if uci set firewall.@defaults[0].flow_offloading='0' &&
            uci set firewall.@defaults[0].flow_offloading_hw='1'; then
            ok "Аппаратное ускорение применено"
        else
            warn "Не удалось настроить аппаратное ускорение"
        fi
    fi

    if uci set network.globals.packet_steering='2'; then
        STEERING_OK=1
        ok "Распределение нагрузки на ядра включено"
    else
        warn "Не удалось включить распределение нагрузки на ядра"
    fi

    if uci set network.globals.steering_flows='128'; then
        FLOWS_OK=1
        ok "Распределение пакетов: 128"
    else
        warn "Не удалось установить распределение пакетов: 128"
    fi

    if uci commit firewall; then
        :
    else
        warn "Не удалось сохранить настройки ускорения"
    fi

    if uci commit network; then
        :
    else
        STEERING_OK=0
        FLOWS_OK=0
        warn "Не удалось сохранить настройки распределения нагрузки на ядра"
    fi

    if [ -x /etc/init.d/firewall ]; then
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
    fi

    if [ -x /etc/init.d/packet_steering ]; then
        /etc/init.d/packet_steering reload >/dev/null 2>&1 || true
    fi

    FLOW_OFFLOADING="$(
        uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null || true
    )"

    FLOW_OFFLOADING_HW="$(
        uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || true
    )"

    PACKET_STEERING="$(
        uci -q get network.globals.packet_steering 2>/dev/null || true
    )"

    STEERING_FLOWS="$(
        uci -q get network.globals.steering_flows 2>/dev/null || true
    )"

    if [ "$OFFLOAD_MODE" = "software" ] &&
        [ "$FLOW_OFFLOADING" = "1" ] &&
        [ "$FLOW_OFFLOADING_HW" = "0" ]; then
        OFFLOAD_OK=1

    elif [ "$OFFLOAD_MODE" = "hardware" ] &&
        [ "$FLOW_OFFLOADING" = "0" ] &&
        [ "$FLOW_OFFLOADING_HW" = "1" ]; then
        OFFLOAD_OK=1
    fi

    if [ "$PACKET_STEERING" = "2" ]; then
        STEERING_OK=1
    else
        STEERING_OK=0
    fi

    if [ "$STEERING_FLOWS" = "128" ]; then
        FLOWS_OK=1
    else
        FLOWS_OK=0
    fi

    if [ "$OFFLOAD_OK" -eq 1 ] &&
        [ "$STEERING_OK" -eq 1 ] &&
        [ "$FLOWS_OK" -eq 1 ]; then

        NETWORK_ACCELERATION_STATUS="OK"
        ok "Сетевое ускорение настроено"
    else
        NETWORK_ACCELERATION_STATUS="FAIL"
        warn "Проверка сетевого ускорения не пройдена"
    fi
}

configure_local_apk() {
    log "Настройка установки локальных пакетов"

    APK_CONFIG="/etc/apk/config"

    if mkdir -p /etc/apk; then
        if grep -Fqx "allow-untrusted" "$APK_CONFIG" 2>/dev/null; then
            LOCAL_APK_STATUS="OK"
            ok "Установка локальных apk уже разрешена"
        else
            if printf '%s\n' "allow-untrusted" >> "$APK_CONFIG"; then
                LOCAL_APK_STATUS="OK"
                ok "Установка локальных apk разрешена"
            else
                LOCAL_APK_STATUS="FAIL"
                warn "Не удалось разрешить установку локальных apk"
            fi
        fi
    else
        LOCAL_APK_STATUS="FAIL"
        warn "Не удалось создать /etc/apk"
    fi
}

configure_cron() {
    log "Настройка задач планировщика"

    if ! touch "$CRON_FILE" 2>/dev/null; then
        CRON_STATUS="FAIL"
        AUTO_UPDATE_CRON_STATUS="FAIL"
        warn "Не удалось открыть $CRON_FILE"
        return
    fi

    CRON_STATUS="OK"
    AUTO_UPDATE_CRON_STATUS="OK"

    if grep -Fqx "$CRON_REBOOT_LINE" "$CRON_FILE" 2>/dev/null; then
        ok "Ежедневная перезагрузка в 05:00 уже настроена"
    else
        if printf '%s\n' "$CRON_REBOOT_LINE" >> "$CRON_FILE"; then
            ok "Добавлена ежедневная перезагрузка в 05:00"
        else
            CRON_STATUS="FAIL"
            warn "Не удалось добавить задачу перезагрузки"
        fi
    fi

    if grep -Fqx "$CRON_AUTO_UPDATE_LINE" "$CRON_FILE" 2>/dev/null; then
        ok "Автоматическое обновление уже настроено"
    else
        if printf '%s\n' "$CRON_AUTO_UPDATE_LINE" >> "$CRON_FILE"; then
            ok "Добавлено автоматическое обновление ПО"
        else
            AUTO_UPDATE_CRON_STATUS="FAIL"
            warn "Не удалось добавить автоматическое обновление пакетов"
        fi
    fi

    if ! /etc/init.d/cron enable >/dev/null 2>&1 ||
        ! /etc/init.d/cron restart >/dev/null 2>&1; then

        CRON_STATUS="FAIL"
        AUTO_UPDATE_CRON_STATUS="FAIL"
        warn "Не удалось включить/перезапустить планировщик"
    else
        ok "Планировщик включён и перезапущен"
    fi
}

log "Обновление списка пакетов"

if pkg_update_lists; then
    PACKAGES_UPDATE_STATUS="OK"
    ok "Списки пакетов обновлены"
else
    warn "Не удалось обновить списки пакетов"
fi

log "Обновление пакетов"

if pkg_upgrade_all; then
    PACKAGES_STATUS="OK"
    ok "Пакеты обновлены"
else
    warn "Ошибка при обновлении пакетов"
fi

log "Проверка наличия русского языка в системе"

if ! pkg_installed "luci-i18n-base-ru"; then
    log "Установка русского языка"

    if pkg_install "luci-i18n-base-ru"; then
        BASE_RU_STATUS="OK"
        ok "Русская локализация установлена"
    else
        warn "Не удалось установить русскую локализацию"
    fi
else
    BASE_RU_STATUS="OK"
    ok "Русская локализация уже установлена"
fi

configure_timezone
configure_network_acceleration

log "Проверка наличия NetShift"

if pkg_installed "netshift"; then
    NETSHIFT_STATUS="OK"
    ok "NetShift уже установлен"
else
    log "Установка NetShift"
    log "Автоматический выбор: sing-box extended + русский язык"

    if run_netshift_installer; then
        NETSHIFT_STATUS="OK"
        ok "NetShift установлен"
    else
        NETSHIFT_STATUS="FAIL"
        warn "Не удалось установить NetShift"
    fi
fi

configure_local_apk
configure_cron

if [ "$NETSHIFT_STATUS" = "OK" ] &&
    ! pkg_installed "netshift"; then
    NETSHIFT_STATUS="FAIL"
fi

printf '\n'
printf '%s\n' 'УСТАНОВКА ЗАВЕРШЕНА!'

printf 'Поиск обновлений системы     : '
status "$PACKAGES_UPDATE_STATUS"
printf '\n'

printf 'Установка обновлений         : '
status "$PACKAGES_STATUS"
printf '\n'

printf 'Русская локализация          : '
status "$BASE_RU_STATUS"
printf '\n'

printf 'Часовой пояс и время         : '
status "$TIMEZONE_STATUS"
printf '\n'

printf 'Сетевое ускорение            : '
status "$NETWORK_ACCELERATION_STATUS"
printf '\n'

printf 'Установка локальных APK      : '
status "$LOCAL_APK_STATUS"
printf '\n'

printf 'NetShift                     : '
status "$NETSHIFT_STATUS"
printf '\n'

printf 'Перезагрузка в 05:00         : '
status "$CRON_STATUS"
printf '\n'

printf 'Автообновление пакетов       : '
status "$AUTO_UPDATE_CRON_STATUS"
printf '\n'

exit 0
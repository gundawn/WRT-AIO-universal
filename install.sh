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


setup_package_manager() {
    if ! command -v apk >/dev/null 2>&1; then
        err "Не найден пакетный менеджер apk."
        return 1
    fi

    log "Обнаружен менеджер пакетов: apk"
    return 0
}


update_packages() {
    log "Обновление списка пакетов"

    if apk update >"$TMP_DIR/pkg-update.log" 2>&1; then
        PACKAGES_UPDATE_STATUS="OK"
        ok "Списки пакетов обновлены"
    else
        warn "Не удалось обновить списки пакетов"
        cat "$TMP_DIR/pkg-update.log"
    fi


    log "Обновление пакетов"

    if apk upgrade --available >"$TMP_DIR/pkg-upgrade.log" 2>&1; then
        PACKAGES_STATUS="OK"
        ok "Пакеты обновлены"
    else
        warn "Ошибка при обновлении пакетов"
        cat "$TMP_DIR/pkg-upgrade.log"
    fi
}


setup_russian_language() {
    log "Проверка русской локализации"

    if apk info -e luci-i18n-base-ru >/dev/null 2>&1; then
        BASE_RU_STATUS="OK"
        ok "Русская локализация уже установлена"
        return 0
    fi

    log "Установка русской локализации"

    if apk add luci-i18n-base-ru; then
        BASE_RU_STATUS="OK"
        ok "Русская локализация установлена"
    else
        BASE_RU_STATUS="FAIL"
        warn "Не удалось установить русскую локализацию"
    fi
}


setup_timezone() {
    log "Настройка часового пояса и времени"

    if uci set system.@system[0].zonename='Asia/Yekaterinburg' &&
        uci set system.@system[0].timezone='+05' &&
        uci commit system; then

        VERIFY_ZONENAME="$(
            uci -q get system.@system[0].zonename 2>/dev/null || true
        )"

        VERIFY_TIMEZONE="$(
            uci -q get system.@system[0].timezone 2>/dev/null || true
        )"

        if [ "$VERIFY_ZONENAME" = "Asia/Yekaterinburg" ] &&
            [ "$VERIFY_TIMEZONE" = "+05" ]; then

            TIMEZONE_STATUS="OK"
            ok "Часовой пояс GMT+5 установлен"
        else
            TIMEZONE_STATUS="FAIL"
            warn "Не удалось проверить часовой пояс"
        fi
    else
        TIMEZONE_STATUS="FAIL"
        warn "Не удалось установить часовой пояс"
    fi
}


setup_network_acceleration() {
    log "Настройка сетевого ускорения"

    PLATFORM=""

    DEVICE_COMPATIBLE="$(
        tr '\000' '\n' < /proc/device-tree/compatible 2>/dev/null |
            tr '[:upper:]' '[:lower:]' |
            tr '\n' ' ' ||
            true
    )"

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

    if [ "$PLATFORM" = "qcom" ]; then
        log "Обнаружена платформа qcom"
        log "Включается программное ускорение"

    elif [ "$PLATFORM" = "mediatek/filogic" ]; then
        log "Обнаружена платформа mediatek/filogic"
        log "Включается аппаратное ускорение"

    else
        log "Платформа не определена"
        log "Включается программное ускорение"
    fi


    if [ "$OFFLOAD_MODE" = "software" ]; then

        if uci set firewall.@defaults[0].flow_offloading='1' &&
            uci set firewall.@defaults[0].flow_offloading_hw='0'; then

            ok "Программное ускорение применено"
        else
            NETWORK_ACCELERATION_STATUS="FAIL"
            warn "Не удалось настроить программное ускорение"
            return 1
        fi

    else

        if uci set firewall.@defaults[0].flow_offloading='0' &&
            uci set firewall.@defaults[0].flow_offloading_hw='1'; then

            ok "Аппаратное ускорение применено"
        else
            NETWORK_ACCELERATION_STATUS="FAIL"
            warn "Не удалось настроить аппаратное ускорение"
            return 1
        fi
    fi


    if uci set network.globals.packet_steering='2'; then
        ok "Распределение нагрузки на ядра включено"
    else
        NETWORK_ACCELERATION_STATUS="FAIL"
        warn "Не удалось включить распределение нагрузки на ядра"
        return 1
    fi


    if uci set network.globals.steering_flows='128'; then
        ok "Распределение пакетов: 128"
    else
        NETWORK_ACCELERATION_STATUS="FAIL"
        warn "Не удалось установить распределение пакетов: 128"
        return 1
    fi


    if ! uci commit firewall; then
        NETWORK_ACCELERATION_STATUS="FAIL"
        warn "Не удалось сохранить настройки firewall"
        return 1
    fi


    if ! uci commit network; then
        NETWORK_ACCELERATION_STATUS="FAIL"
        warn "Не удалось сохранить настройки network"
        return 1
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
    )


    if [ "$OFFLOAD_MODE" = "software" ] &&
        [ "$FLOW_OFFLOADING" = "1" ] &&
        [ "$FLOW_OFFLOADING_HW" = "0" ] &&
        [ "$PACKET_STEERING" = "2" ] &&
        [ "$STEERING_FLOWS" = "128" ]; then

        NETWORK_ACCELERATION_STATUS="OK"
        ok "Сетевое ускорение настроено"

    elif [ "$OFFLOAD_MODE" = "hardware" ] &&
        [ "$FLOW_OFFLOADING" = "0" ] &&
        [ "$FLOW_OFFLOADING_HW" = "1" ] &&
        [ "$PACKET_STEERING" = "2" ] &&
        [ "$STEERING_FLOWS" = "128" ]; then

        NETWORK_ACCELERATION_STATUS="OK"
        ok "Сетевое ускорение настроено"

    else
        NETWORK_ACCELERATION_STATUS="FAIL"
        warn "Проверка сетевого ускорения не пройдена"
        return 1
    fi
}


setup_local_apk() {
    log "Настройка установки локальных APK"

    APK_CONFIG="/etc/apk/config"

    if mkdir -p /etc/apk; then

        if grep -Fqx "allow-untrusted" "$APK_CONFIG" 2>/dev/null; then
            LOCAL_APK_STATUS="OK"
            ok "Установка локальных apk уже разрешена"
            return 0
        fi


        if printf '%s\n' "allow-untrusted" >> "$APK_CONFIG"; then
            LOCAL_APK_STATUS="OK"
            ok "Установка локальных apk разрешена"
        else
            LOCAL_APK_STATUS="FAIL"
            warn "Не удалось разрешить установку локальных apk"
        fi

    else
        LOCAL_APK_STATUS="FAIL"
        warn "Не удалось создать /etc/apk"
    fi
}


fetch_file() {
    url="$1"
    output="$2"

    rm -f "$output"


    if command -v wget >/dev/null 2>&1; then

        if wget -q -O "$output" "$url" 2>/dev/null &&
            [ -s "$output" ]; then

            return 0
        fi

        rm -f "$output"


        if wget -q --no-check-certificate -O "$output" "$url" 2>/dev/null &&
            [ -s "$output" ]; then

            return 0
        fi
    fi


    if command -v curl >/dev/null 2>&1; then

        if curl -fsSL -o "$output" "$url" 2>/dev/null &&
            [ -s "$output" ]; then

            return 0
        fi

        rm -f "$output"


        if curl -kfsSL -o "$output" "$url" 2>/dev/null &&
            [ -s "$output" ]; then

            return 0
        fi
    fi


    rm -f "$output"
    return 1
}


install_netshift() {
    log "Проверка наличия NetShift"

    if apk info -e netshift >/dev/null 2>&1; then
        NETSHIFT_STATUS="OK"
        ok "NetShift уже установлен"
        return 0
    fi


    log "Установка NetShift"

    installer="$TMP_DIR/netshift-installer.sh"


    if ! fetch_file "$NETSHIFT_INSTALL_URL" "$installer"; then
        NETSHIFT_STATUS="FAIL"
        warn "Не удалось скачать установщик NetShift"
        return 1
    fi


    if ! chmod 700 "$installer"; then
        NETSHIFT_STATUS="FAIL"
        warn "Не удалось подготовить установщик NetShift"
        return 1
    fi


    log "Запуск установщика NetShift"
    log "Дальнейший выбор выполняется вручную"


    if sh "$installer"; then
        NETSHIFT_STATUS="OK"
        ok "NetShift установлен"
    else
        NETSHIFT_STATUS="FAIL"
        warn "Не удалось установить NetShift"
    fi
}


setup_cron() {
    log "Настройка планировщика"

    CRON_REBOOT_OK=0
    CRON_UPDATE_OK=0


    if ! touch "$CRON_FILE" 2>/dev/null; then
        CRON_STATUS="FAIL"
        AUTO_UPDATE_CRON_STATUS="FAIL"

        warn "Не удалось открыть $CRON_FILE"
        return 1
    fi


    if grep -Fqx "$CRON_REBOOT_LINE" "$CRON_FILE" 2>/dev/null; then
        CRON_REBOOT_OK=1
        ok "Ежедневная перезагрузка в 05:00 уже настроена"
    else
        if printf '%s\n' "$CRON_REBOOT_LINE" >> "$CRON_FILE"; then
            CRON_REBOOT_OK=1
            ok "Добавлена ежедневная перезагрузка в 05:00"
        else
            warn "Не удалось добавить задачу перезагрузки"
        fi
    fi


    if grep -Fqx "$CRON_AUTO_UPDATE_LINE" "$CRON_FILE" 2>/dev/null; then
        CRON_UPDATE_OK=1
        ok "Автоматическое обновление уже настроено"
    else
        if printf '%s\n' "$CRON_AUTO_UPDATE_LINE" >> "$CRON_FILE"; then
            CRON_UPDATE_OK=1
            ok "Добавлено автоматическое обновление пакетов"
        else
            warn "Не удалось добавить автоматическое обновление пакетов"
        fi
    fi


    if ! /etc/init.d/cron enable >/dev/null 2>&1; then
        warn "Не удалось включить cron"
        CRON_REBOOT_OK=0
        CRON_UPDATE_OK=0
    fi


    if ! /etc/init.d/cron restart >/dev/null 2>&1; then
        warn "Не удалось перезапустить cron"
        CRON_REBOOT_OK=0
        CRON_UPDATE_OK=0
    fi


    if [ "$CRON_REBOOT_OK" -eq 1 ]; then
        CRON_STATUS="OK"
    else
        CRON_STATUS="FAIL"
    fi


    if [ "$CRON_UPDATE_OK" -eq 1 ]; then
        AUTO_UPDATE_CRON_STATUS="OK"
    else
        AUTO_UPDATE_CRON_STATUS="FAIL"
    fi
}


print_summary() {
    printf '\n'
    printf '%s\n' 'УСТАНОВКА ЗАВЕРШЕНА!'
    printf '\n'

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
}


main() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Скрипт должен быть запущен от root"
        exit 1
    fi


    mkdir -p "$TMP_DIR" || {
        err "Не удалось создать $TMP_DIR!"
        exit 1
    }


    if ! setup_package_manager; then
        exit 1
    fi


    update_packages

    setup_russian_language

    setup_timezone

    setup_network_acceleration

    install_netshift

    setup_local_apk

    setup_cron

    print_summary
}


main

exit 0
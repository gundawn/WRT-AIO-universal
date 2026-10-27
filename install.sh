#!/bin/sh

set -u

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

configure_russian_language() {
    log "Проверка и установка русской локализации"

    RU_PACKAGES="
luci-i18n-base-ru
luci-i18n-advanced-reboot-ru
luci-i18n-attendedsysupgrade-ru
luci-i18n-firewall-ru
luci-i18n-package-manager-ru
"

    RU_FAILED=0

    for package in $RU_PACKAGES; do
        if pkg_installed "$package"; then
            ok "$package уже установлен"
            continue
        fi

        log "Установка $package"

        if pkg_install "$package"; then
            if pkg_installed "$package"; then
                ok "$package установлен"
            else
                warn "Не удалось подтвердить установку $package"
                RU_FAILED=1
            fi
        else
            warn "Не удалось установить $package"
            RU_FAILED=1
        fi
    done

    if [ "$RU_FAILED" -eq 0 ]; then
        BASE_RU_STATUS="OK"
        ok "Все пакеты русской локализации установлены"
    else
        BASE_RU_STATUS="FAIL"
        warn "Не все пакеты русской локализации установлены"
    fi
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
        TIMEZONE_STATUS="FAIL"
        warn "Не удалось проверить часовой пояс"
    fi

    if [ -x /etc/init.d/sysntpd ]; then
        /etc/init.d/sysntpd enable >/dev/null 2>&1 || true
        /etc/init.d/sysntpd restart >/dev/null 2>&1 || true
    fi
}

configure_network_acceleration() {
    log "Настройка распределения сетевой нагрузки"

    STEERING_OK=0
    FLOWS_OK=0

    if uci set network.globals.packet_steering='2'; then
        ok "Распределение нагрузки на ядра включено"
    else
        warn "Не удалось включить распределение нагрузки на ядра"
    fi

    if uci set network.globals.steering_flows='128'; then
        ok "Распределение пакетов: 128"
    else
        warn "Не удалось установить распределение пакетов: 128"
    fi

    if uci commit network; then
        ok "Настройки распределения нагрузки сохранены"
    else
        warn "Не удалось сохранить настройки распределения нагрузки"
    fi

    if [ -x /etc/init.d/packet_steering ]; then
        if /etc/init.d/packet_steering reload >/dev/null 2>&1; then
            ok "Служба распределения нагрузки перезагружена"
        else
            warn "Не удалось перезагрузить службу распределения нагрузки"
        fi
    fi

    PACKET_STEERING="$(
        uci -q get network.globals.packet_steering 2>/dev/null || true
    )"

    STEERING_FLOWS="$(
        uci -q get network.globals.steering_flows 2>/dev/null || true
    )"

    if [ "$PACKET_STEERING" = "2" ]; then
        STEERING_OK=1
    fi

    if [ "$STEERING_FLOWS" = "128" ]; then
        FLOWS_OK=1
    fi

    if [ "$STEERING_OK" -eq 1 ] && [ "$FLOWS_OK" -eq 1 ]; then
        NETWORK_ACCELERATION_STATUS="OK"
        ok "Распределение сетевой нагрузки настроено"
    else
        NETWORK_ACCELERATION_STATUS="FAIL"
        warn "Проверка распределения сетевой нагрузки не пройдена"
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
    PACKAGES_UPDATE_STATUS="FAIL"
    warn "Не удалось обновить списки пакетов"
fi

log "Обновление пакетов"

if pkg_upgrade_all; then
    PACKAGES_STATUS="OK"
    ok "Пакеты обновлены"
else
    PACKAGES_STATUS="FAIL"
    warn "Ошибка при обновлении пакетов"
fi

configure_russian_language
configure_timezone
configure_network_acceleration
configure_local_apk
configure_cron

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

printf 'Распределение сетевой нагрузки: '
status "$NETWORK_ACCELERATION_STATUS"
printf '\n'

printf 'Установка локальных APK      : '
status "$LOCAL_APK_STATUS"
printf '\n'

printf 'Перезагрузка в 05:00         : '
status "$CRON_STATUS"
printf '\n'

printf 'Автообновление пакетов       : '
status "$AUTO_UPDATE_CRON_STATUS"
printf '\n'

exit 0
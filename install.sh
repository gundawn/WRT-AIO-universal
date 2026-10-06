#!/bin/sh

set -u

NETSHIFT_INSTALL_URL="https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh"

PKG_MANAGER=""

TMP_DIR="/tmp/wrt-aio"

CRON_FILE="/etc/crontabs/root"
CRON_REBOOT_LINE="0 5 * * * /sbin/reboot"
CRON_AUTO_UPDATE_LINE=""

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

if command -v apk >/dev/null 2>&1 &&
    ! command -v apk 2>/dev/null | grep -q '^/opt/bin/'; then

    PKG_MANAGER="apk"

elif command -v opkg >/dev/null 2>&1 &&
    ! command -v opkg 2>/dev/null | grep -q '^/opt/bin/'; then

    PKG_MANAGER="opkg"

else
    err "Не удалось определить пакетный менеджер apk/opkg."
    exit 1
fi

log "Обнаружен менеджер пакетов: $PKG_MANAGER"

case "$PKG_MANAGER" in
    apk)
        CRON_AUTO_UPDATE_LINE="0 */5 * * * apk update && apk upgrade"
        ;;
    opkg)
        CRON_AUTO_UPDATE_LINE="0 */5 * * * opkg update && opkg list-upgradable | awk '{print \$1}' | while read -r package; do [ -n \"\$package\" ] && opkg upgrade \"\$package\"; done"
        ;;
esac

pkg_installed() {
    package="$1"

    case "$PKG_MANAGER" in
        apk)
            apk info -e "$package" >/dev/null 2>&1
            ;;
        opkg)
            opkg status "$package" 2>/dev/null |
                grep -q '^Status:.*installed'
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_version() {
    package="$1"

    case "$PKG_MANAGER" in
        apk)
            apk info -a "$package" 2>/dev/null |
                head -n 1 |
                sed "s/^${package}-//; s/[[:space:]].*$//"
            ;;
        opkg)
            opkg status "$package" 2>/dev/null |
                sed -n 's/^Version:[[:space:]]*//p' |
                head -n 1
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_install() {
    package="$1"

    case "$PKG_MANAGER" in
        apk)
            apk add "$package"
            ;;
        opkg)
            opkg install "$package"
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_upgrade() {
    package="$1"

    case "$PKG_MANAGER" in
        apk)
            apk add --upgrade "$package"
            ;;
        opkg)
            opkg upgrade "$package"
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_update_lists() {
    case "$PKG_MANAGER" in
        apk)
            if apk update >"$TMP_DIR/pkg-update.log" 2>&1; then
                return 0
            else
                cat "$TMP_DIR/pkg-update.log"
                return 1
            fi
            ;;
        opkg)
            if opkg update >"$TMP_DIR/pkg-update.log" 2>&1; then
                return 0
            else
                cat "$TMP_DIR/pkg-update.log"
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

version_is_newer() {
    installed="$1"
    candidate="$2"

    [ -n "$installed" ] || return 0
    [ -n "$candidate" ] || return 1

    case "$PKG_MANAGER" in
        apk)
            [ "$(apk version -t "$installed" "$candidate" 2>/dev/null)" = "<" ]
            ;;
        opkg)
            opkg compare-versions "$candidate" ">" "$installed" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

package_needs_update() {
    package="$1"

    if ! pkg_installed "$package"; then
        return 0
    fi

    installed="$(pkg_version "$package")"
    candidate=""

    case "$PKG_MANAGER" in
        apk)
            candidate="$(
                apk policy "$package" 2>/dev/null |
                    sed -n 's/^[[:space:]]*\([0-9][^[:space:]:]*\):.*/\1/p' |
                    head -n 1
            )"
            ;;
        opkg)
            candidate="$(
                opkg list-upgradable 2>/dev/null |
                    awk -v package="$package" '$1 == package {print $3; exit}'
            )"
            ;;
    esac

    [ -n "$candidate" ] || return 1

    version_is_newer "$installed" "$candidate"
}

pkg_upgrade_all() {
    case "$PKG_MANAGER" in
        apk)
            if apk upgrade --available >"$TMP_DIR/pkg-upgrade.log" 2>&1; then
                return 0
            else
                cat "$TMP_DIR/pkg-upgrade.log"
                return 1
            fi
            ;;
        opkg)
            UPGRADE_LIST="$(
                opkg list-upgradable 2>/dev/null |
                    awk '{print $1}'
            )"

            if [ -n "$UPGRADE_LIST" ]; then
                for package in $UPGRADE_LIST; do
                    opkg upgrade "$package" || return 1
                done
            fi
            ;;
        *)
            return 1
            ;;
    esac
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
    fi

elif package_needs_update "luci-i18n-base-ru"; then
    log "Обновление русского языка"

    if pkg_upgrade "luci-i18n-base-ru"; then
        BASE_RU_STATUS="OK"
    fi
else
    BASE_RU_STATUS="OK"
fi

if [ "$BASE_RU_STATUS" = "OK" ]; then
    ok "Русская локализация установлена/актуальна"
else
    warn "Не удалось установить/обновить русскую локализацию"
fi

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

TIME_SYNC_OK=0

if [ -x /etc/init.d/sysntpd ]; then
    if /etc/init.d/sysntpd enable >/dev/null 2>&1 &&
        /etc/init.d/sysntpd restart >/dev/null 2>&1; then
        TIME_SYNC_OK=1
    fi
fi

if [ "$VERIFY_ZONENAME" = "Asia/Yekaterinburg" ] &&
    [ "$VERIFY_TIMEZONE" = "+05" ] &&
    [ "$TIME_SYNC_OK" -eq 1 ]; then

    TIMEZONE_STATUS="OK"
    ok "Часовой пояс проверен, синхронизация запущена"
else
    warn "Не удалось проверить часовой пояс"
fi

log "Определение платформы для сетевого ускорения"

DEVICE_COMPATIBLE="$(
    tr '\000' '\n' < /proc/device-tree/compatible 2>/dev/null |
        tr '[:upper:]' '[:lower:]' |
        tr '\n' ' ' ||
        true
)"

PLATFORM=""
OFFLOAD_MODE=""

case "$DEVICE_COMPATIBLE" in
    *qcom*|*qualcomm*|*ipq*)
        PLATFORM="qcom"
        OFFLOAD_MODE="software"
        ;;
    *mediatek*|*filogic*|*mt*)
        PLATFORM="mediatek/filogic"
        OFFLOAD_MODE="hardware"
        ;;
esac

if [ -z "$PLATFORM" ]; then
    warn "Не удалось определить процессор"
    NETWORK_ACCELERATION_STATUS="FAIL"
else
    log "Обнаружена процессора: $PLATFORM"

    if [ "$OFFLOAD_MODE" = "software" ]; then
        log "Для платформы qcom включается программное ускорение"

        if uci set firewall.@defaults[0].flow_offloading='1' &&
            uci set firewall.@defaults[0].flow_offloading_hw='0'; then

            ok "Программное ускорение применено"
        else
            warn "Не удалось настроить Программное ускорение"
        fi

    elif [ "$OFFLOAD_MODE" = "hardware" ]; then
        log "Для платформы mediatek filogic включается Аппаратное ускорение"

        if uci set firewall.@defaults[0].flow_offloading='0' &&
            uci set firewall.@defaults[0].flow_offloading_hw='1'; then

            ok "Аппаратное ускорение применено"
        else
            warn "Не удалось настроить Аппаратное ускорение"
        fi
    fi

    STEERING_OK=0
    FLOWS_OK=0
    OFFLOAD_OK=0

    if uci set network.globals.packet_steering='2'; then
        STEERING_OK=1
        ok "Распределение нагрузки на ядра включёно"
    else
        warn "Не удалось включить Распределение нагрузки на ядра"
    fi

    if uci set network.globals.steering_flows='128'; then
        FLOWS_OK=1
        ok "Распределение пакетов: 128"
    else
        warn "Не удалось установить Распределение пакетов: 128"
    fi

    if ! uci commit firewall; then
        OFFLOAD_OK=0
        warn "Не удалось сохранить настройки ускорения"
    fi

    if ! uci commit network; then
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

    else
        OFFLOAD_OK=0
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
fi

log "Проверка наличия NetShift"

NETSHIFT_PACKAGES="
netshift
luci-app-netshift
luci-i18n-netshift-ru
"

NETSHIFT_NEEDS_UPDATE=0

for package in $NETSHIFT_PACKAGES; do
    if ! pkg_installed "$package"; then
        NETSHIFT_NEEDS_UPDATE=1
        break
    fi

    if package_needs_update "$package"; then
        NETSHIFT_NEEDS_UPDATE=1
        break
    fi
done

if [ "$NETSHIFT_NEEDS_UPDATE" -eq 0 ]; then
    NETSHIFT_STATUS="OK"
    ok "NetShift уже установлен и актуален"
else
    log "Установка/обновление NetShift"
    log "Автоматический выбор: sing-box extended + русский язык"

    if run_netshift_installer; then
        NETSHIFT_STATUS="OK"
        ok "NetShift установлен/обновлён"
    else
        NETSHIFT_STATUS="FAIL"
        warn "Не удалось установить/обновить NetShift"
    fi
fi

log "Проверка установки локальных APK"

if [ "$PKG_MANAGER" = "apk" ]; then
    APK_CONFIG="/etc/apk/config"

    if mkdir -p /etc/apk; then
        if grep -Fqx "allow-untrusted" "$APK_CONFIG" 2>/dev/null; then
            LOCAL_APK_STATUS="OK"
            ok "Установка локальных apk уже включена"
        else
            if printf '%s\n' "allow-untrusted" >> "$APK_CONFIG"; then
                LOCAL_APK_STATUS="OK"
                ok "Установка локальных apk включена"
            else
                LOCAL_APK_STATUS="FAIL"
                warn "Не удалось включить установку локальных apk"
            fi
        fi
    else
        LOCAL_APK_STATUS="FAIL"
        warn "Не удалось создать /etc/apk"
    fi
else
    LOCAL_APK_STATUS="OK"
    ok "Для opkg установка локальных APK не требуется"
fi

log "Проверка задачи планировщика на перезагрузку"

if touch "$CRON_FILE" 2>/dev/null; then

    if grep -Fqx "$CRON_REBOOT_LINE" "$CRON_FILE" 2>/dev/null; then
        CRON_STATUS="OK"
        ok "Ежедневная перезагрузка в 05:00 уже настроена"
    else
        if printf '%s\n' "$CRON_REBOOT_LINE" >> "$CRON_FILE"; then
            CRON_STATUS="OK"
            ok "Добавлена ежедневная перезагрузка в 05:00"
        else
            CRON_STATUS="FAIL"
            warn "Не удалось добавить задачу перезагрузки"
        fi
    fi

    if ! /etc/init.d/cron enable >/dev/null 2>&1 ||
        ! /etc/init.d/cron restart >/dev/null 2>&1; then

        CRON_STATUS="FAIL"
        warn "Не удалось включить/перезапустить планировщик"
    fi

else
    CRON_STATUS="FAIL"
    warn "Не удалось открыть $CRON_FILE"
fi

log "Проверка автоматического обновления пакетов"

if touch "$CRON_FILE" 2>/dev/null; then

    if grep -Fqx "$CRON_AUTO_UPDATE_LINE" "$CRON_FILE" 2>/dev/null; then
        AUTO_UPDATE_CRON_STATUS="OK"
        ok "Автоматическое обновление уже настроено"
    else
        if printf '%s\n' "$CRON_AUTO_UPDATE_LINE" >> "$CRON_FILE"; then
            AUTO_UPDATE_CRON_STATUS="OK"
            ok "Добавлено автоматическое обновление ПО"
        else
            AUTO_UPDATE_CRON_STATUS="FAIL"
            warn "Не удалось добавить автоматическое обновление пакетов"
        fi
    fi

    if ! /etc/init.d/cron enable >/dev/null 2>&1 ||
        ! /etc/init.d/cron restart >/dev/null 2>&1; then

        AUTO_UPDATE_CRON_STATUS="FAIL"
        warn "Не удалось перезапустить планировщик"
    fi

else
    AUTO_UPDATE_CRON_STATUS="FAIL"
    warn "Не удалось открыть $CRON_FILE"
fi

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
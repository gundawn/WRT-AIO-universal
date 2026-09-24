#!/bin/sh

set -u

AURORA_INSTALL_URL="https://openwrt.eamonxg.fun/install.sh"
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

PACKAGES_UPDATE_STATUS=PACKAGES_STATUS=BASE_RU_STATUS=AURORA_STATUS=""
SINGBOX_STATUS=NETSHIFT_STATUS=""
CRON_STATUS=AUTO_UPDATE_CRON_STATUS=""
TIMEZONE_STATUS=NETWORK_ACCELERATION_STATUS=""

PACKAGES_UPDATE_STATUS=PACKAGES_STATUS=BASE_RU_STATUS=AURORA_STATUS=\
SINGBOX_STATUS=NETSHIFT_STATUS=CRON_STATUS=AUTO_UPDATE_CRON_STATUS=\
TIMEZONE_STATUS=NETWORK_ACCELERATION_STATUS="ОТМЕНА"

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

if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
fi

log "Обнаружена версия OpenWRT: ${DISTRIB_RELEASE:-unknown}"
log "Обнаружена архитектура: ${DISTRIB_ARCH:-unknown}"

if command -v apk >/dev/null 2>&1 &&
    ! command -v apk 2>/dev/null | grep -q '^/opt/bin/'; then

    PKG_MANAGER="apk"
    PKG_ARCH="$(apk --print-arch 2>/dev/null || true)"
    PACKAGE_EXT="apk"

elif command -v opkg >/dev/null 2>&1 &&
    ! command -v opkg 2>/dev/null | grep -q '^/opt/bin/'; then

    PKG_MANAGER="opkg"
    PKG_ARCH="$(
        opkg print-architecture 2>/dev/null |
            awk '$1 == "arch" {arch=$2} END {print arch}' ||
            true
    )"
    PACKAGE_EXT="ipk"

else
    err "Не удалось определить пакетный менеджер apk/opkg."
    exit 1
fi

RELEASE_ARCH="${DISTRIB_ARCH:-$PKG_ARCH}"

log "Обнаружен менеджер пакетов: $PKG_MANAGER"

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

apk_install_local() {
    package_file="$1"

    [ -f "$package_file" ] || return 1
    [ -s "$package_file" ] || return 1

    apk add --allow-untrusted "$package_file"
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

run_remote_installer() {
    url="$1"
    installer="$TMP_DIR/installer.sh"

    if ! fetch_file "$url" "$installer"; then
        return 1
    fi

    chmod 700 "$installer" || return 1

    sh "$installer"
}

run_netshift_installer() {
    installer="$TMP_DIR/netshift-installer.sh"

    if ! fetch_file "$NETSHIFT_INSTALL_URL" "$installer"; then
        return 1
    fi

    chmod 700 "$installer" || return 1

    printf '%s\n' "2" "y" | sh "$installer"
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

TIMEZONE_OK=0

CURRENT_ZONENAME="$(
    uci -q get system.@system[0].zonename 2>/dev/null || true
)"

CURRENT_TIMEZONE="$(
    uci -q get system.@system[0].timezone 2>/dev/null || true
)"

if [ "$CURRENT_ZONENAME" = "Asia/Yekaterinburg" ] &&
    [ "$CURRENT_TIMEZONE" = "+05" ]; then

    log "Часовой пояс уже настроен"

else
    uci set system.@system[0].zonename='Asia/Yekaterinburg' &&
    uci set system.@system[0].timezone='+05' &&
    uci commit system
fi

VERIFY_ZONENAME="$(
    uci -q get system.@system[0].zonename 2>/dev/null || true
)"

VERIFY_TIMEZONE="$(
    uci -q get system.@system[0].timezone 2>/dev/null || true
)"

if [ "$VERIFY_ZONENAME" = "Asia/Yekaterinburg" ] &&
    [ "$VERIFY_TIMEZONE" = "+05" ]; then

    if [ -x /usr/sbin/ntpd ]; then
        if /usr/sbin/ntpd -q \
            -p 194.190.168.1 \
            -p 216.239.35.0 \
            -p 216.239.35.4 \
            -p 162.159.200.1 \
            -p 162.159.200.123 \
            >/dev/null 2>&1; then

            TIMEZONE_OK=1
        fi

    elif [ -x /etc/init.d/sysntpd ]; then
        if /etc/init.d/sysntpd restart >/dev/null 2>&1; then
            TIMEZONE_OK=1
        fi
    fi
fi

if [ "$TIMEZONE_OK" -eq 1 ]; then
    TIMEZONE_STATUS="OK"
    ok "Часовой пояс Asia/Yekaterinburg установлен, время синхронизировано"
else
    warn "Не удалось полностью настроить часовой пояс/синхронизацию времени"
fi

log "Проверка наличия Aurora в системе"

AURORA_PACKAGES="
luci-theme-aurora
luci-app-aurora-config
luci-i18n-aurora-config-ru
"

AURORA_NEEDS_UPDATE=0

for package in $AURORA_PACKAGES; do
    if ! pkg_installed "$package"; then
        AURORA_NEEDS_UPDATE=1
        break
    fi

    if package_needs_update "$package"; then
        AURORA_NEEDS_UPDATE=1
        break
    fi
done

if [ "$AURORA_NEEDS_UPDATE" -eq 0 ]; then
    AURORA_STATUS="OK"
    ok "Aurora установлена и актуальна"
else
    log "Установка/обновление Aurora"
    log "Установщик Aurora остаётся интерактивным"

    if run_remote_installer "$AURORA_INSTALL_URL"; then
        AURORA_STATUS="OK"
        ok "Aurora установлена/обновлена"
    else
        warn "Не удалось установить/обновить Aurora"
    fi
fi

log "Настройка сетевого ускорения"

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

if [ "$FLOW_OFFLOADING" = "1" ] &&
    [ "$FLOW_OFFLOADING_HW" = "0" ] &&
    [ "$PACKET_STEERING" = "2" ] &&
    [ "$STEERING_FLOWS" = "128" ]; then

    NETWORK_ACCELERATION_STATUS="OK"
    ok "Software Offloading уже настроен"

elif [ "$FLOW_OFFLOADING" = "0" ] &&
    [ "$FLOW_OFFLOADING_HW" = "1" ] &&
    [ "$PACKET_STEERING" = "2" ] &&
    [ "$STEERING_FLOWS" = "128" ]; then

    NETWORK_ACCELERATION_STATUS="OK"
    ok "Hardware Offloading уже настроен"

else
    printf '\n'
    printf '%s\n' "Выберите сетевое ускорение:"
    printf '%s\n' "1) Software Flow Offloading"
    printf '%s\n' "2) Hardware Flow Offloading"
    printf '%s\n' "3) Пропустить"

    OFFLOAD_CHOICE=""

    while :; do
        printf 'Ваш выбор [1-3]: '
        read -r OFFLOAD_CHOICE

        case "$OFFLOAD_CHOICE" in
            1|2|3)
                break
                ;;
            *)
                printf '%s\n' "Введите 1, 2 или 3."
                ;;
        esac
    done

    case "$OFFLOAD_CHOICE" in
        1)
            log "Включение Software Flow Offloading"

            if uci set firewall.@defaults[0].flow_offloading='1' &&
                uci set firewall.@defaults[0].flow_offloading_hw='0' &&
                uci set network.globals.packet_steering='2' &&
                uci set network.globals.steering_flows='128' &&
                uci commit firewall &&
                uci commit network; then

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

                if [ "$FLOW_OFFLOADING" = "1" ] &&
                    [ "$FLOW_OFFLOADING_HW" = "0" ] &&
                    [ "$PACKET_STEERING" = "2" ] &&
                    [ "$STEERING_FLOWS" = "128" ]; then

                    NETWORK_ACCELERATION_STATUS="OK"
                    ok "Software Offloading и Packet Steering настроены"
                else
                    warn "Проверка сетевого ускорения не пройдена"
                fi
            else
                warn "Не удалось настроить сетевое ускорение"
            fi
            ;;

        2)
            log "Включение Hardware Flow Offloading"

            if uci set firewall.@defaults[0].flow_offloading='0' &&
                uci set firewall.@defaults[0].flow_offloading_hw='1' &&
                uci set network.globals.packet_steering='2' &&
                uci set network.globals.steering_flows='128' &&
                uci commit firewall &&
                uci commit network; then

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

                if [ "$FLOW_OFFLOADING" = "0" ] &&
                    [ "$FLOW_OFFLOADING_HW" = "1" ] &&
                    [ "$PACKET_STEERING" = "2" ] &&
                    [ "$STEERING_FLOWS" = "128" ]; then

                    NETWORK_ACCELERATION_STATUS="OK"
                    ok "Hardware Offloading и Packet Steering настроены"
                else
                    warn "Проверка сетевого ускорения не пройдена"
                fi
            else
                warn "Не удалось настроить сетевое ускорение"
            fi
            ;;

        3)
            NETWORK_ACCELERATION_STATUS="ПРОПУСК"
            warn "Сетевое ускорение пропущено"
            ;;
    esac
fi

log "Проверка памяти роутера"

OVERLAY_TOTAL_KB="$(
    df -k /overlay 2>/dev/null |
        awk 'NR == 2 {print $2}'
)"

if [ -z "$OVERLAY_TOTAL_KB" ]; then
    OVERLAY_TOTAL_KB="$(
        df -k / 2>/dev/null |
            awk 'NR == 2 {print $2}'
    )"
fi

if [ -n "$OVERLAY_TOTAL_KB" ] &&
    [ "$OVERLAY_TOTAL_KB" -gt 0 ] 2>/dev/null; then

    FLASH_TOTAL_MB=$((OVERLAY_TOTAL_KB / 1024))

    log "Общая ёмкость памяти: ${FLASH_TOTAL_MB} MB"

    if [ "$FLASH_TOTAL_MB" -ge "$MIN_FLASH_MB" ]; then
        FLASH_OK=1
        ok "Flash-память подходит для установки NetShift"
    else
        FLASH_OK=0
        warn "Flash-память меньше минимального порога ${MIN_FLASH_MB} MB!"
        warn "Установка sing-box-extended и NetShift будут пропущены."
    fi
else
    FLASH_OK=0
    warn "Не удалось определить общую ёмкость памяти."
    warn "Установка sing-box-extended и NetShift будут пропущены."
fi

if [ "$FLASH_OK" -eq 1 ]; then

    log "Проверка наличия sing-box-extended"

    if pkg_installed "sing-box-extended"; then

        SINGBOX_STATUS="OK"
        ok "sing-box-extended уже установлен"

    else
        log "sing-box-extended отсутствует. Установка фиксированной версии 2.7.1"

        SINGBOX_JSON="$TMP_DIR/singbox.json"

        if ! fetch_file "$SINGBOX_RELEASE_API" "$SINGBOX_JSON"; then
            warn "Не удалось получить релиз sing-box-extended 2.7.1"
            SINGBOX_STATUS="FAIL"
        else
            SINGBOX_URL="$(
                grep -o '"browser_download_url":[[:space:]]*"[^"]*"' "$SINGBOX_JSON" |
                    sed 's/^.*"browser_download_url":[[:space:]]*"//; s/"$//' |
                    grep -E "_openwrt_${RELEASE_ARCH}\.${PACKAGE_EXT}$" |
                    head -n 1
            )"

            if [ -z "$SINGBOX_URL" ]; then
                warn "Не найден пакет sing-box-extended 2.7.1 для ${RELEASE_ARCH}.${PACKAGE_EXT}"
                SINGBOX_STATUS="FAIL"
            else
                SINGBOX_FILE="$TMP_DIR/$(basename "$SINGBOX_URL")"

                log "Найден пакет: $(basename "$SINGBOX_URL")"

                if fetch_file "$SINGBOX_URL" "$SINGBOX_FILE"; then

                    case "$PKG_MANAGER" in
                        apk)
                            if apk_install_local "$SINGBOX_FILE"; then
                                SINGBOX_STATUS="OK"
                                ok "sing-box-extended 2.7.1 установлен"
                            else
                                SINGBOX_STATUS="FAIL"
                                warn "Не удалось установить sing-box-extended 2.7.1"
                            fi
                            ;;
                        opkg)
                            if opkg install "$SINGBOX_FILE"; then
                                SINGBOX_STATUS="OK"
                                ok "sing-box-extended 2.7.1 установлен"
                            else
                                SINGBOX_STATUS="FAIL"
                                warn "Не удалось установить sing-box-extended 2.7.1"
                            fi
                            ;;
                    esac

                else
                    SINGBOX_STATUS="FAIL"
                    warn "Не удалось скачать sing-box-extended 2.7.1"
                fi
            fi
        fi
    fi

else
    SINGBOX_STATUS="ПРОПУСК"
fi

if [ "$FLASH_OK" -eq 1 ]; then

    if [ "$SINGBOX_STATUS" = "OK" ] &&
        pkg_installed "sing-box-extended"; then

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
            log "Автоматический выбор: sing-box-extended + русский язык"

            if run_netshift_installer; then
                NETSHIFT_STATUS="OK"
                ok "NetShift установлен/обновлён"
            else
                NETSHIFT_STATUS="FAIL"
                warn "Не удалось установить/обновить NetShift"
            fi
        fi

    elif [ "$SINGBOX_STATUS" = "ПРОПУСК" ]; then

        NETSHIFT_STATUS="ПРОПУСК"
        warn "NetShift пропущен: sing-box-extended не обрабатывался."

    else

        NETSHIFT_STATUS="ПРОПУСК"
        warn "NetShift пропущен: sing-box-extended не установлен."

    fi

else
    NETSHIFT_STATUS="ПРОПУСК"
fi

log "Проверка задачи планировщика на перезагрузку"

if touch "$CRON_FILE" 2>/dev/null; then

    if grep -Fqx "$CRON_REBOOT_LINE" "$CRON_FILE" 2>/dev/null; then
        ok "Ежедневная перезагрузка в 05:00 уже настроена"
        CRON_STATUS="OK"
    else
        if printf '%s\n' "$CRON_REBOOT_LINE" >> "$CRON_FILE"; then
            ok "Добавлена ежедневная перезагрузка в 05:00"
            CRON_STATUS="OK"
        else
            warn "Не удалось добавить задачу перезагрузки"
        fi
    fi

    if ! /etc/init.d/cron enable >/dev/null 2>&1 ||
        ! /etc/init.d/cron restart >/dev/null 2>&1; then

        CRON_STATUS="FAIL"
        warn "Не удалось включить/перезапустить планировщик"
    fi

else
    warn "Не удалось открыть $CRON_FILE"
fi

log "Проверка автоматического обновления пакетов"

if [ "$PKG_MANAGER" = "apk" ]; then

    if touch "$CRON_FILE" 2>/dev/null; then

        if grep -Fqx "$CRON_AUTO_UPDATE_LINE" "$CRON_FILE" 2>/dev/null; then
            AUTO_UPDATE_CRON_STATUS="OK"
            ok "Автоматическое обновление каждые 5 часов уже настроено"
        else
            if printf '%s\n' "$CRON_AUTO_UPDATE_LINE" >> "$CRON_FILE"; then
                AUTO_UPDATE_CRON_STATUS="OK"
                ok "Добавлено автоматическое обновление пакетов каждые 5 часов"
            else
                warn "Не удалось добавить автоматическое обновление пакетов"
            fi
        fi

        if ! /etc/init.d/cron enable >/dev/null 2>&1 ||
            ! /etc/init.d/cron restart >/dev/null 2>&1; then

            AUTO_UPDATE_CRON_STATUS="FAIL"
            warn "Не удалось перезапустить планировщик"
        fi

    else
        warn "Не удалось открыть $CRON_FILE"
    fi

else
    AUTO_UPDATE_CRON_STATUS="ПРОПУСК"
    warn "Автообновление через apk пропущено: используется $PKG_MANAGER"
fi

if [ "$SINGBOX_STATUS" = "OK" ] &&
    ! pkg_installed "sing-box-extended"; then
    SINGBOX_STATUS="FAIL"
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

printf 'Тема Aurora                  : '
status "$AURORA_STATUS"
printf '\n'

printf 'Сетевое ускорение            : '
status "$NETWORK_ACCELERATION_STATUS"
printf '\n'

printf 'Sing-box-extended 2.7.1      : '
status "$SINGBOX_STATUS"
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
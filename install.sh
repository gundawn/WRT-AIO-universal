#!/bin/sh

set -u

MIN_FLASH_MB=50

AURORA_INSTALL_URL="https://openwrt.eamonxg.fun/install.sh"
NETSHIFT_INSTALL_URL="https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh"
SINGBOX_RELEASE_API="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest"

CRON_FILE="/etc/crontabs/root"
CRON_LINE="0 5 * * * /sbin/reboot"

TMP_DIR="/tmp/wrt-aio"

PACKAGES_UPDATE_STATUS="ОТМЕНА"
PACKAGES_STATUS="ОТМЕНА"
BASE_RU_STATUS="ОТМЕНА"
AURORA_STATUS="ОТМЕНА"
SINGBOX_STATUS="ОТМЕНА"
NETSHIFT_STATUS="ОТМЕНА"
CRON_STATUS="ОТМЕНА"

FLASH_OK=0

PKG_MANAGER=""
PKG_ARCH=""
RELEASE_ARCH=""
PACKAGE_EXT=""

SINGBOX_FILE=""
SINGBOX_RELEASE_VERSION=""
INSTALLED_SINGBOX_VERSION=""
INSTALLED_SINGBOX_RELEASE_VERSION=""

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

log() {
    printf '[*] %s\n' "$1"
}

ok() {
    printf '[+] %s\n' "$1"
}

warn() {
    printf '[!] %s\n' "$1"
}

err() {
    printf '[-] %s\n' "$1" >&2
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

pkg_remove() {
    package="$1"

    case "$PKG_MANAGER" in
        apk)
            apk del "$package"
            ;;
        opkg)
            opkg remove "$package"
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_update_lists() {
    case "$PKG_MANAGER" in
        apk)
            apk update
            ;;
        opkg)
            opkg update
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
            apk upgrade --available
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

singbox_version_is_newer() {
    installed="$1"
    candidate="$2"

    [ -n "$installed" ] || return 0
    [ -n "$candidate" ] || return 1

    installed_parts="$(
        printf '%s\n' "$installed" |
            sed 's/-extended-/./; s/\./ /g'
    )"

    candidate_parts="$(
        printf '%s\n' "$candidate" |
            sed 's/-extended-/./; s/\./ /g'
    )"

    [ "$(printf '%s\n' "$installed_parts" | awk '{print NF}')" -eq 6 ] ||
        return 1

    [ "$(printf '%s\n' "$candidate_parts" | awk '{print NF}')" -eq 6 ] ||
        return 1

    awk '
        NR == 1 {
            for (i = 1; i <= 6; i++)
                installed[i] = $i
            next
        }

        NR == 2 {
            for (i = 1; i <= 6; i++)
                candidate[i] = $i
        }

        END {
            for (i = 1; i <= 6; i++) {
                if ((candidate[i] + 0) > (installed[i] + 0))
                    exit 0

                if ((candidate[i] + 0) < (installed[i] + 0))
                    exit 1
            }

            exit 1
        }
    ' <<EOF
$installed_parts
$candidate_parts
EOF
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

    if run_remote_installer "$AURORA_INSTALL_URL"; then
        AURORA_STATUS="OK"
        ok "Aurora установлена/обновлена."
    else
        warn "Не удалось установить/обновить Aurora."
    fi
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

    SINGBOX_JSON="$TMP_DIR/singbox.json"

    if ! fetch_file "$SINGBOX_RELEASE_API" "$SINGBOX_JSON"; then
        warn "Не удалось получить информацию о последнем релизе sing-box-extended"
    else
        SINGBOX_URL="$(
            grep -o '"browser_download_url":[[:space:]]*"[^"]*"' "$SINGBOX_JSON" |
                sed 's/^.*"browser_download_url":[[:space:]]*"//; s/"$//' |
                grep -E "_openwrt_${RELEASE_ARCH}\.${PACKAGE_EXT}$" |
                head -n 1
        )"

        if [ -z "$SINGBOX_URL" ]; then
            warn "Не найден пакет sing-box-extended для ${RELEASE_ARCH}.${PACKAGE_EXT}."
        else
            SINGBOX_FILE="$TMP_DIR/$(basename "$SINGBOX_URL")"

            if ! fetch_file "$SINGBOX_URL" "$SINGBOX_FILE"; then
                warn "Не удалось скачать sing-box-extended"
            else
                SINGBOX_RELEASE_VERSION="$(
                    basename "$SINGBOX_URL" |
                        sed 's/^sing-box-extended_//; s/_openwrt_.*$//'
                )"

                log "Последняя версия sing-box-extended: $SINGBOX_RELEASE_VERSION"

                if pkg_installed "sing-box-extended"; then

                    INSTALLED_SINGBOX_VERSION="$(pkg_version "sing-box-extended")"

                    INSTALLED_SINGBOX_RELEASE_VERSION="$(
                        printf '%s\n' "$INSTALLED_SINGBOX_VERSION" |
                            sed 's/-r[0-9][0-9]*$//; s/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1-extended-\2.\3.\4/'
                    )"

                    log "Установлена версия sing-box-extended: $INSTALLED_SINGBOX_RELEASE_VERSION"

                    if singbox_version_is_newer \
                        "$INSTALLED_SINGBOX_RELEASE_VERSION" \
                        "$SINGBOX_RELEASE_VERSION"; then

                        log "Доступно обновление sing-box-extended"

                        case "$PKG_MANAGER" in
                            apk)
                                if apk del sing-box-extended &&
                                    apk add --allow-untrusted "$SINGBOX_FILE"; then
                                    SINGBOX_STATUS="OK"
                                    ok "sing-box-extended обновлён"
                                else
                                    warn "Не удалось обновить sing-box-extended"
                                fi
                                ;;
                            opkg)
                                if opkg remove sing-box-extended 2>/dev/null &&
                                    opkg install "$SINGBOX_FILE"; then
                                    SINGBOX_STATUS="OK"
                                    ok "sing-box-extended обновлён"
                                else
                                    warn "Не удалось обновить sing-box-extended"
                                fi
                                ;;
                        esac
                    else
                        SINGBOX_STATUS="OK"
                        ok "sing-box-extended актуален"
                    fi

                else
                    log "sing-box-extended не установлен. Установка"

                    case "$PKG_MANAGER" in
                        apk)
                            if apk add --allow-untrusted "$SINGBOX_FILE"; then
                                SINGBOX_STATUS="OK"
                                ok "sing-box-extended установлен"
                            else
                                warn "Не удалось установить sing-box-extended"
                            fi
                            ;;
                        opkg)
                            if opkg install "$SINGBOX_FILE"; then
                                SINGBOX_STATUS="OK"
                                ok "sing-box-extended установлен"
                            else
                                warn "Не удалось установить sing-box-extended"
                            fi
                            ;;
                    esac
                fi
            fi
        fi
    fi

else
    SINGBOX_STATUS="SKIPPED"
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

            if run_remote_installer "$NETSHIFT_INSTALL_URL"; then
                NETSHIFT_STATUS="OK"
                ok "NetShift установлен/обновлён"
            else
                warn "Не удалось установить/обновить NetShift"
            fi
        fi

    elif [ "$SINGBOX_STATUS" = "SKIPPED" ]; then

        NETSHIFT_STATUS="SKIPPED"
        warn "NetShift пропущен: sing-box-extended не обрабатывался."

    else

        NETSHIFT_STATUS="SKIPPED"
        warn "NetShift пропущен: sing-box-extended не установлен."

    fi

else
    NETSHIFT_STATUS="SKIPPED"
fi

log "Проверка задачи планировщика на перезагрузку"

if touch "$CRON_FILE" 2>/dev/null; then

    if grep -Fqx "$CRON_LINE" "$CRON_FILE" 2>/dev/null; then
        ok "Ежедневная перезагрузка в 05:00 уже настроена"
    else
        if printf '%s\n' "$CRON_LINE" >> "$CRON_FILE"; then
            ok "Добавлена ежедневная перезагрузка в 05:00"
        else
            warn "Не удалось добавить задачу в планировщик!"
        fi
    fi

    if /etc/init.d/cron enable >/dev/null 2>&1 &&
        /etc/init.d/cron restart >/dev/null 2>&1; then

        CRON_STATUS="OK"
        ok "Планировщик перезапущен для принятия изменений"
    else
        warn "Не удалось включить/перезапустить планировщик!"
    fi

else
    warn "Не удалось открыть $CRON_FILE."
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
printf '%s\n' '============================================================'
printf '%s\n' ' УСТАНОВКА ЗАВЕРШЕНА!'
printf '%s\n' '============================================================'

printf 'Поиск обновлений системы     : %s\n' "$PACKAGES_UPDATE_STATUS"
printf 'Установка обновлений         : %s\n' "$PACKAGES_STATUS"
printf 'Русская локализация          : %s\n' "$BASE_RU_STATUS"
printf 'Тема Aurora                  : %s\n' "$AURORA_STATUS"
printf 'Sing-box-extended            : %s\n' "$SINGBOX_STATUS"
printf 'NetShift                     : %s\n' "$NETSHIFT_STATUS"
printf 'Задача в планировщике        : %s\n' "$CRON_STATUS"

if [ "$FLASH_OK" -eq 0 ]; then
    printf '\n'
    warn "sing-box-extended и NetShift пропущены из-за недостатка памяти!"
    warn "Минимальная общая ёмкость: ${MIN_FLASH_MB} MB."
fi

printf '%s\n' '============================================================'

exit 0
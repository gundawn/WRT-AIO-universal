#!/bin/sh

set -u

AURORA_INSTALL_URL="https://openwrt.eamonxg.fun/install.sh"
NETSHIFT_INSTALL_URL="https://raw.githubusercontent.com/yandexru45/netshift/refs/heads/main/install.sh"
SINGBOX_API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest"

MIN_FLASH_MB=50
TMP_DIR="/tmp/wrt-aio"

PACKAGES_UPDATE_STATUS="SKIPPED"
PACKAGES_STATUS="SKIPPED"
BASE_RU_STATUS="SKIPPED"
AURORA_STATUS="SKIPPED"
SINGBOX_STATUS="SKIPPED"
NETSHIFT_STATUS="SKIPPED"
CRON_STATUS="SKIPPED"

PKG_MANAGER=""
PKG_ARCH=""
RELEASE_ARCH=""
FLASH_OK=0

SINGBOX_FILE=""
SINGBOX_ASSET=""
SINGBOX_CANDIDATE_VERSION=""

log() {
    printf '[INFO] %s\n' "$*"
}

ok() {
    printf '[ OK ] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

fail() {
    printf '[FAIL] %s\n' "$*" >&2
}

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
            apk info -e "$package" 2>/dev/null |
                head -n 1 |
                sed "s/^${package}-//"
            ;;
        opkg)
            opkg status "$package" 2>/dev/null |
                sed -n 's/^Version:[[:space:]]*//p' |
                head -n 1
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

pkg_refresh() {
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

pkg_upgrade_all() {
    case "$PKG_MANAGER" in
        apk)
            apk upgrade
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
    output="$TMP_DIR/installer.sh"

    rm -f "$output"

    if ! fetch_file "$url" "$output"; then
        return 1
    fi

    chmod 700 "$output" || return 1

    sh "$output"
}

root_check() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Скрипт должен быть запущен от root."
        exit 1
    fi
}

cleanup() {
    rm -rf "$TMP_DIR"
}

root_check

mkdir -p "$TMP_DIR" || {
    fail "Не удалось создать $TMP_DIR."
    exit 1
}

trap cleanup EXIT

if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
else
    fail "Это не похоже на OpenWrt: /etc/openwrt_release отсутствует."
    exit 1
fi

log "OpenWrt: ${DISTRIB_DESCRIPTION:-unknown}"
log "Target: ${DISTRIB_TARGET:-unknown}"
log "Architecture: ${DISTRIB_ARCH:-unknown}"

if command -v apk >/dev/null 2>&1 &&
    [ -z "${OPKG_INSTALLED_ROOT:-}" ]; then
    PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
else
    fail "Не найден поддерживаемый пакетный менеджер: apk или opkg."
    exit 1
fi

log "Пакетный менеджер: $PKG_MANAGER"

case "$PKG_MANAGER" in
    apk)
        PKG_ARCH="$(apk --print-arch 2>/dev/null || true)"
        ;;
    opkg)
        PKG_ARCH="$(
            opkg print-architecture 2>/dev/null |
                awk '$1 == "arch" {print $2}' |
                tail -n 1
        )"
        ;;
esac

[ -n "$PKG_ARCH" ] || PKG_ARCH="${DISTRIB_ARCH:-unknown}"
RELEASE_ARCH="${DISTRIB_ARCH:-$PKG_ARCH}"

case "$PKG_MANAGER" in
    apk)
        PACKAGE_EXT="apk"
        ;;
    opkg)
        PACKAGE_EXT="ipk"
        ;;
    *)
        PACKAGE_EXT=""
        ;;
esac

log "Package arch: $PKG_ARCH"
log "Release arch: $RELEASE_ARCH"

#
# Package lists
#

log "Обновление списков пакетов..."

if pkg_refresh; then
    PACKAGES_UPDATE_STATUS="OK"
    ok "Списки пакетов обновлены."
else
    PACKAGES_UPDATE_STATUS="FAILED"
    warn "Не удалось обновить списки пакетов."
fi

#
# Package upgrade
#

log "Проверка обновлений пакетов..."

if pkg_upgrade_all; then
    PACKAGES_STATUS="OK"
    ok "Обновление пакетов завершено."
else
    PACKAGES_STATUS="FAILED"
    warn "Обновление пакетов завершилось с ошибкой."
fi

#
# Russian LuCI
#

log "Проверка luci-i18n-base-ru..."

if package_needs_update "luci-i18n-base-ru"; then
    if pkg_installed "luci-i18n-base-ru"; then
        log "Доступно обновление luci-i18n-base-ru."
    else
        log "Установка luci-i18n-base-ru..."
    fi

    if pkg_install "luci-i18n-base-ru"; then
        BASE_RU_STATUS="OK"
        ok "luci-i18n-base-ru установлен/обновлён."
    else
        BASE_RU_STATUS="FAILED"
        warn "Не удалось установить/обновить luci-i18n-base-ru."
    fi
elif pkg_installed "luci-i18n-base-ru"; then
    BASE_RU_STATUS="OK"
    ok "luci-i18n-base-ru уже актуален."
else
    BASE_RU_STATUS="FAILED"
    warn "Не удалось определить состояние luci-i18n-base-ru."
fi

#
# Aurora
#

log "Проверка Aurora..."

AURORA_PACKAGES_OK=1
AURORA_UPDATE_NEEDED=0

for package in \
    luci-theme-aurora \
    luci-app-aurora-config \
    luci-i18n-aurora-config-ru
do
    if ! pkg_installed "$package"; then
        AURORA_PACKAGES_OK=0
        AURORA_UPDATE_NEEDED=1
        log "Не установлен пакет Aurora: $package"
    elif package_needs_update "$package"; then
        AURORA_UPDATE_NEEDED=1
        log "Доступно обновление Aurora: $package"
    fi
done

if [ "$AURORA_PACKAGES_OK" -eq 1 ] &&
    [ "$AURORA_UPDATE_NEEDED" -eq 0 ]; then

    AURORA_STATUS="OK"
    ok "Aurora уже установлена и актуальна."

else
    log "Установка/обновление Aurora..."

    if run_remote_installer "$AURORA_INSTALL_URL"; then
        if pkg_installed "luci-theme-aurora" &&
            pkg_installed "luci-app-aurora-config" &&
            pkg_installed "luci-i18n-aurora-config-ru"; then

            AURORA_STATUS="OK"
            ok "Aurora установлена/обновлена."
        else
            AURORA_STATUS="FAILED"
            warn "Aurora installer завершился, но не все пакеты установлены."
        fi
    else
        AURORA_STATUS="FAILED"
        warn "Не удалось выполнить Aurora installer."
    fi
fi

#
# Flash capacity
#

log "Проверка общей ёмкости flash..."

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

    log "Общая ёмкость файловой системы: ${FLASH_TOTAL_MB} MB"

    if [ "$FLASH_TOTAL_MB" -ge "$MIN_FLASH_MB" ]; then
        FLASH_OK=1
        ok "Flash подходит для sing-box-extended и NetShift."
    else
        FLASH_OK=0
        warn "Flash меньше минимального порога ${MIN_FLASH_MB} MB."
        warn "sing-box-extended и NetShift будут пропущены."
    fi
else
    FLASH_OK=0
    warn "Не удалось определить общую ёмкость flash."
    warn "sing-box-extended и NetShift будут пропущены."
fi

#
# sing-box-extended
#

if [ "$FLASH_OK" -eq 1 ]; then

    log "Проверка sing-box-extended..."

    SINGBOX_JSON="$TMP_DIR/singbox-release.json"

    if ! fetch_file "$SINGBOX_API_URL" "$SINGBOX_JSON"; then
        SINGBOX_STATUS="FAILED"
        warn "Не удалось получить информацию о последнем релизе sing-box-extended."
    else
        SINGBOX_ASSET="$(
            grep -o '"browser_download_url":[[:space:]]*"[^"]*"' "$SINGBOX_JSON" |
                sed 's/^.*"browser_download_url":[[:space:]]*"//; s/"$//' |
                grep -E "_openwrt_${RELEASE_ARCH}\.${PACKAGE_EXT}$" |
                head -n 1
        )"

        if [ -z "$SINGBOX_ASSET" ]; then
            SINGBOX_STATUS="FAILED"
            warn "Не найден пакет sing-box-extended для архитектуры ${RELEASE_ARCH}."
        else
            SINGBOX_FILE="$TMP_DIR/$(basename "$SINGBOX_ASSET")"

            log "Найден пакет: $(basename "$SINGBOX_ASSET")"

            if ! fetch_file "$SINGBOX_ASSET" "$SINGBOX_FILE"; then
                SINGBOX_STATUS="FAILED"
                warn "Не удалось скачать sing-box-extended."
            else
                SINGBOX_CANDIDATE_VERSION=""

                case "$PKG_MANAGER" in
                    apk)
                        SINGBOX_CANDIDATE_VERSION="$(
                            tar -xzOf "$SINGBOX_FILE" .PKGINFO 2>/dev/null |
                                sed -n 's/^pkgver[[:space:]]*=[[:space:]]*//p' |
                                head -n 1
                        )
                        ;;
                    opkg)
                        CONTROL_ARCHIVE="$TMP_DIR/control.tar.gz"

                        if ar p "$SINGBOX_FILE" control.tar.gz > "$CONTROL_ARCHIVE" 2>/dev/null; then
                            SINGBOX_CANDIDATE_VERSION="$(
                                tar -xzOf "$CONTROL_ARCHIVE" ./control 2>/dev/null |
                                    sed -n 's/^Version:[[:space:]]*//p' |
                                    head -n 1
                            )
                        fi
                        ;;
                esac

                if [ -z "$SINGBOX_CANDIDATE_VERSION" ]; then
                    SINGBOX_STATUS="FAILED"
                    warn "Не удалось определить версию скачанного sing-box-extended."

                elif pkg_installed "sing-box-extended"; then

                    INSTALLED_SINGBOX_VERSION="$(pkg_version "sing-box-extended")"

                    log "Установленная версия: $INSTALLED_SINGBOX_VERSION"
                    log "Доступная версия: $SINGBOX_CANDIDATE_VERSION"

                    if singbox_version_is_newer \
                        "$INSTALLED_SINGBOX_VERSION" \
                        "$SINGBOX_CANDIDATE_VERSION"; then

                        log "Доступно обновление sing-box-extended."

                        case "$PKG_MANAGER" in
                            apk)
                                if apk add --allow-untrusted "$SINGBOX_FILE"; then
                                    SINGBOX_STATUS="OK"
                                    ok "sing-box-extended обновлён."
                                else
                                    SINGBOX_STATUS="FAILED"
                                    warn "Не удалось обновить sing-box-extended."
                                fi
                                ;;
                            opkg)
                                if opkg install "$SINGBOX_FILE"; then
                                    SINGBOX_STATUS="OK"
                                    ok "sing-box-extended обновлён."
                                else
                                    SINGBOX_STATUS="FAILED"
                                    warn "Не удалось обновить sing-box-extended."
                                fi
                                ;;
                        esac
                    else
                        SINGBOX_STATUS="OK"
                        ok "sing-box-extended уже актуален."
                    fi

                else
                    log "Установка sing-box-extended..."

                    case "$PKG_MANAGER" in
                        apk)
                            if apk add --allow-untrusted "$SINGBOX_FILE"; then
                                SINGBOX_STATUS="OK"
                                ok "sing-box-extended установлен."
                            else
                                SINGBOX_STATUS="FAILED"
                                warn "Не удалось установить sing-box-extended."
                            fi
                            ;;
                        opkg)
                            if opkg install "$SINGBOX_FILE"; then
                                SINGBOX_STATUS="OK"
                                ok "sing-box-extended установлен."
                            else
                                SINGBOX_STATUS="FAILED"
                                warn "Не удалось установить sing-box-extended."
                            fi
                            ;;
                    esac
                fi
            fi
        fi
    fi

else
    SINGBOX_STATUS="SKIPPED"
    warn "sing-box-extended пропущен из-за недостаточной ёмкости flash."
fi

#
# Проверка отдельного пакета sing-box
#

if [ "$PKG_MANAGER" = "apk" ]; then
    if apk info -e sing-box >/dev/null 2>&1; then
        warn "Отдельный пакет sing-box установлен."
        warn "Он может конфликтовать с sing-box-extended."
    fi
else
    if pkg_installed "sing-box"; then
        warn "Обычный пакет sing-box также установлен."
        warn "Он может конфликтовать с sing-box-extended."
    fi
fi

#
# NetShift
#

if [ "$FLASH_OK" -eq 1 ]; then

    log "Проверка NetShift..."

    if ! pkg_installed "sing-box-extended"; then
        NETSHIFT_STATUS="FAILED"
        warn "NetShift пропущен: sing-box-extended не установлен."
    else
        NETSHIFT_PACKAGES_OK=1
        NETSHIFT_UPDATE_NEEDED=0

        for package in \
            netshift \
            luci-app-netshift \
            luci-i18n-netshift-ru
        do
            if ! pkg_installed "$package"; then
                NETSHIFT_PACKAGES_OK=0
                NETSHIFT_UPDATE_NEEDED=1
                log "Не установлен пакет NetShift: $package"
            elif package_needs_update "$package"; then
                NETSHIFT_UPDATE_NEEDED=1
                log "Доступно обновление NetShift: $package"
            fi
        done

        if [ "$NETSHIFT_PACKAGES_OK" -eq 1 ] &&
            [ "$NETSHIFT_UPDATE_NEEDED" -eq 0 ]; then

            NETSHIFT_STATUS="OK"
            ok "NetShift уже установлен и актуален."

        else
            log "Установка/обновление NetShift..."

            if run_remote_installer "$NETSHIFT_INSTALL_URL"; then
                if pkg_installed "netshift" &&
                    pkg_installed "luci-app-netshift" &&
                    pkg_installed "luci-i18n-netshift-ru"; then

                    NETSHIFT_STATUS="OK"
                    ok "NetShift установлен/обновлён."
                else
                    NETSHIFT_STATUS="FAILED"
                    warn "NetShift installer завершился, но не все пакеты установлены."
                fi
            else
                NETSHIFT_STATUS="FAILED"
                warn "Не удалось выполнить NetShift installer."
            fi
        fi
    fi

else
    NETSHIFT_STATUS="SKIPPED"
    warn "NetShift пропущен из-за недостаточной ёмкости flash."
fi

#
# Daily reboot cron
#

log "Проверка cron..."

CRON_FILE="/etc/crontabs/root"
CRON_LINE="0 5 * * * /sbin/reboot"

touch "$CRON_FILE" 2>/dev/null || true

if grep -Fqx "$CRON_LINE" "$CRON_FILE" 2>/dev/null; then
    ok "Ежедневный reboot в 05:00 уже настроен."
else
    if printf '%s\n' "$CRON_LINE" >> "$CRON_FILE"; then
        ok "Добавлен ежедневный reboot в 05:00."
    else
        CRON_STATUS="FAILED"
        warn "Не удалось изменить $CRON_FILE."
    fi
fi

if [ "$CRON_STATUS" != "FAILED" ]; then
    if /etc/init.d/cron enable >/dev/null 2>&1 &&
        /etc/init.d/cron restart >/dev/null 2>&1; then
        CRON_STATUS="OK"
        ok "Cron включён и перезапущен."
    else
        CRON_STATUS="FAILED"
        warn "Не удалось включить/перезапустить cron."
    fi
fi

#
# Final verification
#

log "Финальная проверка..."

if pkg_installed "luci-i18n-base-ru"; then
    ok "luci-i18n-base-ru: установлен."
else
    warn "luci-i18n-base-ru: отсутствует."
fi

if pkg_installed "luci-theme-aurora" &&
    pkg_installed "luci-app-aurora-config" &&
    pkg_installed "luci-i18n-aurora-config-ru"; then
    ok "Aurora: установлена."
else
    warn "Aurora: не все компоненты установлены."
fi

if pkg_installed "sing-box-extended"; then
    ok "sing-box-extended: установлен."
elif [ "$SINGBOX_STATUS" = "SKIPPED" ]; then
    warn "sing-box-extended: пропущен."
else
    warn "sing-box-extended: отсутствует."
fi

if pkg_installed "netshift" &&
    pkg_installed "luci-app-netshift" &&
    pkg_installed "luci-i18n-netshift-ru"; then
    ok "NetShift: установлен."
elif [ "$NETSHIFT_STATUS" = "SKIPPED" ]; then
    warn "NetShift: пропущен."
else
    warn "NetShift: не все компоненты установлены."
fi

if grep -Fqx "$CRON_LINE" "$CRON_FILE" 2>/dev/null; then
    ok "Cron: reboot в 05:00 настроен."
else
    warn "Cron: reboot в 05:00 не найден."
fi

#
# Summary
#

printf '\n'
printf '%s\n' "========================================"
printf '%s\n' "           WRT-AIO SUMMARY"
printf '%s\n' "========================================"
printf 'Package lists:     %s\n' "$PACKAGES_UPDATE_STATUS"
printf 'Packages:          %s\n' "$PACKAGES_STATUS"
printf 'Russian LuCI:      %s\n' "$BASE_RU_STATUS"
printf 'Aurora:            %s\n' "$AURORA_STATUS"
printf 'sing-box-extended: %s\n' "$SINGBOX_STATUS"
printf 'NetShift:          %s\n' "$NETSHIFT_STATUS"
printf 'Cron 05:00 reboot: %s\n' "$CRON_STATUS"

if [ "$FLASH_OK" -eq 1 ]; then
    printf 'Flash >= %s MB:    YES\n' "$MIN_FLASH_MB"
else
    printf 'Flash >= %s MB:    NO\n' "$MIN_FLASH_MB"
    printf '%s\n' "sing-box/NetShift: SKIPPED"
fi

printf '%s\n' "========================================"
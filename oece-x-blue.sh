#!/usr/bin/env bash
#=======================================================================
#  oece-x-blue.sh — VPS 藍隊加固面板
#
#  開機第一小時的藍隊工作：評分 · 加固 · 蜜罐 · 監控 · 應急響應
#  每一步可回滾，任何動 SSH 的操作都掛自動還原定時器。
#
#  Project : https://github.com/web3-ai-game/oece-x-blue-sh
#  Channel : YouTube @oece-x · https://oece-x.com
#  License : MIT
#
#  本工具為防禦性運維工具，不含任何繞過網路封鎖之功能。
#  蜜罐採集的資料僅存本地，不外傳、不上報、不遙測。
#=======================================================================

SCRIPT_VERSION="2.1.0"
# shellcheck disable=SC2034  # 由「檢查更新」模塊使用
SCRIPT_RAW_URL="https://raw.githubusercontent.com/web3-ai-game/oece-x-blue-sh/main/oece-x-blue.sh"
ISSUE_URL="https://github.com/web3-ai-game/oece-x-blue-sh/issues"

set -Eeuo pipefail

# 安全輔助。開發時與 lib/security.sh 是同一段，測試直接 source 該檔。
# 發佈副本必須自包含：短網址只下發這一個檔。
# curl|bash 時旁邊沒有 lib/。兩邊一起改，不要只改其中一邊。
# 單引號安全轉義（用於寫入可被 source 的 env 檔）
sh_sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# 判斷字串是否為單一 IPv4 / IPv6（拒絕 CIDR、主機名、空白與 shell 元字元）
is_ip() {
    local ip="$1"
    case "$ip" in
        *[!0-9a-fA-F:.]*) return 1 ;;
        *:*)
            printf '%s\n' "$ip" | grep -qE \
                '^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$|^::1$|^::$' || return 1
            ;;
        *)
            printf '%s\n' "$ip" | grep -qE \
                '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
            local o
            for o in ${ip//./ }; do
                [ "$o" -le 255 ] || return 1
            done
            ;;
    esac
    return 0
}

# 回滾窗口必須是 1–120 的整數。非法值拒絕，避免 sleep/systemd 被注入。
valid_rollback_minutes() {
    local m="$1"
    case "$m" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$m" -ge 1 ] && [ "$m" -le 120 ]
}

# SSH 監聽埠。1024–65535，純數字，拒絕注入。
valid_ssh_port() {
    local p="$1"
    case "$p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$p" -ge 1024 ] && [ "$p" -le 65535 ]
}

# 本地帳戶名。小寫、數字、底線、連字號，不以連字號開頭，最長 32。
valid_username() {
    local u="$1"
    case "$u" in
        ''|-*|*[!a-z0-9_-]*) return 1 ;;
    esac
    [ "${#u}" -le 32 ]
}

# 語意化版本比較。只接受 X.Y.Z。回傳 0 表示 a < b。
version_lt() {
    local a="$1" b="$2"
    case "$a" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    case "$b" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    local IFS=.
    # shellcheck disable=SC2086
    set -- $a
    local a1="${1:-0}" a2="${2:-0}" a3="${3:-0}"
    # shellcheck disable=SC2086
    set -- $b
    local b1="${1:-0}" b2="${2:-0}" b3="${3:-0}"
    if [ "$a1" -lt "$b1" ]; then return 0; fi
    if [ "$a1" -gt "$b1" ]; then return 1; fi
    if [ "$a2" -lt "$b2" ]; then return 0; fi
    if [ "$a2" -gt "$b2" ]; then return 1; fi
    [ "$a3" -lt "$b3" ]
}

# env_set 在 BLUE_ENV 定義之後實作。這裡只留純函式，避免未定義變數。

#-----------------------------------------------------------------------
# 全局常量
#-----------------------------------------------------------------------
BLUE_ETC="/etc/oece-x"                 # blue.env（chmod 600）
BLUE_LIB="/var/lib/oece-x"             # manifest / baseline / 狀態
BLUE_LOG="/var/log/oece-x"             # 巡檢報告 / 事件日誌
BLUE_BACKUP="/var/backups/oece-x"      # 回滾備份 + 取證包
BLUE_BASELINE="${BLUE_LIB}/baseline"
# shellcheck disable=SC2034  # 由加固模塊寫入 sshd 設定
BLUE_SSHD_DROPIN="/etc/ssh/sshd_config.d/99-oece-blue.conf"

# 誘餌用戶名：機器人最常暴破的一組
HONEY_USERS="root admin administrator ubuntu test oracle user guest postgres mysql"

# curl 通用參數：HTTPS 校驗、超時、重試
CURL_OPTS=(--fail --silent --show-error --location --retry 3 --retry-delay 1 --connect-timeout 10)

# 運行時狀態
TMP_DIR="$(mktemp -d /tmp/oece-blue.XXXXXX)"
OS_ID=""
OS_PRETTY=""
ARCH=""
PKG_MGR=""
APT_UPDATED=0
AUTH_LOG=""          # 偵測到的 auth 日誌路徑（可能為空 → 走 journalctl）
UI_LANG="zh-Hant"
DRY_RUN=0
AUDIT_JSON=0
DEMO_SCORE=57
OECE_LANG_FILE="/etc/oece-x/lang"
BLUE_INSTALL="/usr/local/sbin/oece-x-blue"

#-----------------------------------------------------------------------
# 語言
#   優先序：--lang / OECE_LANG > /etc/oece-x/lang > LANG。
#   zh_CN、zh_SG 與任何 zh* 一律落到繁體。en* 落到 English。
#   首次互動且沒有偏好檔時，開場詢問一次。
#-----------------------------------------------------------------------
normalize_lang() {
    local raw="$1" low
    low="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$low" in
        en|en-*|english) printf 'en' ;;
        zh-hant|zh_hant|zh-tw|zh_tw|zh-hk|zh_hk|zh-mo|zh_mo|zh|zh-*|zh_*|chinese|traditional)
            printf 'zh-Hant' ;;
        *) printf '' ;;
    esac
}

detect_lang_auto() {
    local src="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" hit
    hit="$(normalize_lang "$src")"
    if [ -n "$hit" ]; then
        printf '%s' "$hit"
        return 0
    fi
    printf 'zh-Hant'
}

resolve_lang() {
    local hit=""
    if [ -n "${OECE_LANG:-}" ]; then
        hit="$(normalize_lang "$OECE_LANG")"
        if [ -n "$hit" ]; then
            printf '%s' "$hit"
            return 0
        fi
    fi
    if [ -r "$OECE_LANG_FILE" ]; then
        hit="$(normalize_lang "$(head -1 "$OECE_LANG_FILE" 2>/dev/null || true)")"
        if [ -n "$hit" ]; then
            printf '%s' "$hit"
            return 0
        fi
    fi
    detect_lang_auto
}

persist_lang() {
    local lang="$1" dir
    dir="$(dirname "$OECE_LANG_FILE")"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s\n' "$lang" > "$OECE_LANG_FILE" 2>/dev/null || return 0
    chmod 644 "$OECE_LANG_FILE" 2>/dev/null || true
}

prompt_lang_if_needed() {
    [ -t 0 ] && [ -t 1 ] || return 0
    [ -n "${OECE_LANG:-}" ] && return 0
    [ -s "$OECE_LANG_FILE" ] && return 0
    printf '\n語言 / Language\n'
    printf '  1) 繁體中文（預設 / default）\n'
    printf '  2) English\n'
    printf '10 秒未輸入則使用繁體中文。請選擇 [1]: '
    local reply=""
    if read -r -t 10 reply; then
        :
    else
        printf '\n'
        reply=""
    fi
    case "$reply" in
        2|en|EN|english|English) UI_LANG="en" ;;
        *) UI_LANG="zh-Hant" ;;
    esac
    persist_lang "$UI_LANG"
}

t() {
    local key="$1"
    if [ "${UI_LANG:-zh-Hant}" = "en" ]; then
        case "$key" in
            info.tag) printf '[info]' ;;
            ok.tag) printf '[ok]' ;;
            warn.tag) printf '[warn]' ;;
            err.tag) printf '[error]' ;;
            pause) printf 'Press Enter to return...' ;;
            confirm.yes) printf '  Type yes to confirm (anything else cancels): ' ;;
            err.need_root) printf 'This tool needs root (sshd, firewall, and auth logs).' ;;
            err.use_sudo) printf 'Run: sudo bash oece-x-blue.sh' ;;
            err.linux_only) printf 'Linux only (Debian / Ubuntu / RHEL family).' ;;
            err.unknown_os) printf 'Unrecognized distro: %%s (supported: Debian/Ubuntu/RHEL family)' ;;
            err.no_pkg) printf 'No apt, dnf, or yum found.' ;;
            err.arch) printf 'Unsupported architecture: %%s (amd64 / arm64 only).' ;;
            menu.ask) printf 'Choice: ' ;;
            menu.exit) printf 'Goodbye. Guard the box.' ;;
            menu.invalid) printf 'Unknown choice: %%s' ;;
            banner.tagline) printf 'score · harden · honeypot · monitor · respond' ;;
            group.vis) printf 'Visibility' ;;
            group.harden) printf 'Hardening' ;;
            group.defense) printf 'Active defense' ;;
            group.alert) printf 'Alerting' ;;
            group.response) printf 'Response' ;;
            group.system) printf 'System' ;;
            menu.1) printf 'Live panel' ;;
            menu.1h) printf 'Score, bans, attackers, honeypot' ;;
            menu.2) printf 'Hardening audit' ;;
            menu.2h) printf '32 read-only checks plus fixes' ;;
            menu.3) printf 'Lynis audit' ;;
            menu.3h) printf 'Independent third-party score' ;;
            menu.4) printf 'Harden · basic' ;;
            menu.4h) printf 'No lockout risk: patches, sysctl, mounts' ;;
            menu.5) printf 'Harden · standard' ;;
            menu.5h) printf 'SSH, firewall, IPS, auto-rollback' ;;
            menu.6) printf 'Harden · hardcore' ;;
            menu.6h) printf 'Admin rename, honeypot, port move' ;;
            menu.7) printf 'Cherry-pick' ;;
            menu.7h) printf 'Apply one control at a time' ;;
            menu.8) printf 'CrowdSec' ;;
            menu.8h) printf 'Community IPS (512MB or more)' ;;
            menu.9) printf 'fail2ban' ;;
            menu.9h) printf 'Lightweight bans' ;;
            menu.10) printf 'root honeypot' ;;
            menu.10h) printf 'Decoy accounts, ban on first hit' ;;
            menu.11) printf 'endlessh tarpit' ;;
            menu.11h) printf 'Hold scanners on port 22' ;;
            menu.12) printf 'Firewall' ;;
            menu.12h) printf 'UFW plus Docker bypass fix' ;;
            menu.13) printf 'Alert channels' ;;
            menu.13h) printf 'Telegram / mail' ;;
            menu.14) printf 'Login alerts' ;;
            menu.14h) printf 'PAM hook, push on success' ;;
            menu.15) printf 'Daily report' ;;
            menu.15h) printf 'cron report plus drift detection' ;;
            menu.16) printf 'IOC scan' ;;
            menu.16h) printf 'Read-only intrusion indicators' ;;
            menu.17) printf 'Forensics bundle' ;;
            menu.17h) printf 'Pack evidence plus REPORT.md' ;;
            menu.18) printf 'Ban / unban / kick' ;;
            menu.19) printf 'Emergency lockdown' ;;
            menu.19h) printf 'Allow the current IP, keep 80/443' ;;
            menu.20) printf 'Rollback' ;;
            menu.20h) printf 'Undo one change or restore all' ;;
            menu.21) printf 'Check for updates' ;;
            menu.21h) printf 'Compare versions, do not auto-install' ;;
            menu.0) printf 'Exit' ;;
            grade.excellent) printf 'Excellent' ;;
            grade.good) printf 'Good' ;;
            grade.pass) printf 'Passing' ;;
            grade.weak) printf 'Weak' ;;
            grade.critical) printf 'Critical' ;;
            yes) printf 'yes' ;;
            no) printf 'no' ;;
            dryrun) printf '[dry-run] would run: %%s' ;;
            *) printf '%s' "$key" ;;
        esac
        return 0
    fi
    case "$key" in
        info.tag) printf '[資訊]' ;;
        ok.tag) printf '[完成]' ;;
        warn.tag) printf '[注意]' ;;
        err.tag) printf '[錯誤]' ;;
        pause) printf '按 Enter 返回主選單...' ;;
        confirm.yes) printf '  確認請完整輸入 yes（其他任何輸入取消）: ' ;;
        err.need_root) printf '本腳本需要 root 權限（讀取 sshd 配置 / 防火牆 / auth 日誌需要）。' ;;
        err.use_sudo) printf '請改用：sudo bash oece-x-blue.sh' ;;
        err.linux_only) printf '本腳本僅支援 Linux（Debian / Ubuntu / CentOS 系）。' ;;
        err.unknown_os) printf '未識別的發行版：%%s（官方支援 Debian/Ubuntu/CentOS 系）' ;;
        err.no_pkg) printf '找不到可用的包管理器（apt/dnf/yum），無法繼續。' ;;
        err.arch) printf '暫不支援的架構：%%s（目前支援 amd64 / arm64）' ;;
        menu.ask) printf '請輸入選項: ' ;;
        menu.exit) printf '再見。守好你的機器。' ;;
        menu.invalid) printf '無效選項：%%s' ;;
        banner.tagline) printf '評分 · 加固 · 蜜罐 · 監控 · 應急' ;;
        group.vis) printf '態勢' ;;
        group.harden) printf '加固' ;;
        group.defense) printf '主動防禦' ;;
        group.alert) printf '監控告警' ;;
        group.response) printf '應急響應' ;;
        group.system) printf '系統' ;;
        menu.1) printf '藍隊面板' ;;
        menu.1h) printf '即時儀表板：評分/封禁/攻擊源/蜜罐' ;;
        menu.2) printf '加固評分體檢' ;;
        menu.2h) printf '32 項唯讀檢查 + 修復指引' ;;
        menu.3) printf 'Lynis 深度審計' ;;
        menu.3h) printf '第三方獨立評分（可選安裝）' ;;
        menu.4) printf '一鍵加固 · 基礎' ;;
        menu.4h) printf '零鎖門風險：補丁/sysctl/掛載' ;;
        menu.5) printf '一鍵加固 · 標準' ;;
        menu.5h) printf 'SSH 收緊 + 防火牆 + 入侵防禦' ;;
        menu.6) printf '一鍵加固 · 硬核' ;;
        menu.6h) printf '管理員換人 + root 蜜罐 + 改端口' ;;
        menu.7) printf '逐項加固' ;;
        menu.7h) printf '手動挑選單項' ;;
        menu.8) printf 'CrowdSec' ;;
        menu.8h) printf '社群威脅情報 IPS（建議 ≥512MB）' ;;
        menu.9) printf 'fail2ban' ;;
        menu.9h) printf '輕量封禁' ;;
        menu.10) printf 'root 蜜罐' ;;
        menu.10h) printf '誘餌帳戶 + 秒封 + 命中統計' ;;
        menu.11) printf 'endlessh 焦油坑' ;;
        menu.11h) printf '22 埠掛住掃描器數小時' ;;
        menu.12) printf '防火牆' ;;
        menu.12h) printf 'UFW + Docker 繞過修復' ;;
        menu.13) printf '告警通道配置' ;;
        menu.13h) printf 'Telegram / 郵件' ;;
        menu.14) printf '登入即時告警' ;;
        menu.14h) printf 'PAM 鉤子，登入成功即推送' ;;
        menu.15) printf '每日巡檢報告' ;;
        menu.15h) printf 'cron 日報 + 配置漂移偵測' ;;
        menu.16) printf 'IOC 快檢' ;;
        menu.16h) printf '入侵指標掃描（唯讀）' ;;
        menu.17) printf '一鍵取證包' ;;
        menu.17h) printf '打包全部證據 + REPORT.md' ;;
        menu.18) printf '封禁 / 解封 / 踢人' ;;
        menu.19) printf '緊急鎖定' ;;
        menu.19h) printf '只放行當前 IP，保留 80/443' ;;
        menu.20) printf '回滾與還原' ;;
        menu.20h) printf '逐項撤銷 / 全部還原' ;;
        menu.21) printf '檢查更新' ;;
        menu.21h) printf '只比對版本，不自動覆蓋' ;;
        menu.0) printf '退出' ;;
        grade.excellent) printf '優秀' ;;
        grade.good) printf '良好' ;;
        grade.pass) printf '及格' ;;
        grade.weak) printf '偏弱' ;;
        grade.critical) printf '危險' ;;
        yes) printf '是' ;;
        no) printf '否' ;;
        dryrun) printf '[dry-run] 將執行：%%s' ;;
        *) printf '%s' "$key" ;;
    esac
}

#-----------------------------------------------------------------------
# 顏色與輸出
#-----------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_CYAN=$'\033[0;36m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

info()  { printf '%s%s%s %s\n' "$C_CYAN"   "$(t info.tag)"  "$C_RESET" "$*"; }
ok()    { printf '%s%s%s %s\n' "$C_GREEN"  "$(t ok.tag)"    "$C_RESET" "$*"; }
warn()  { printf '%s%s%s %s\n' "$C_YELLOW" "$(t warn.tag)"  "$C_RESET" "$*"; }
err()   { printf '%s%s%s %s\n' "$C_RED"    "$(t err.tag)"   "$C_RESET" "$*" >&2; }

divider() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────" "$C_RESET"; }

section() {
    printf '\n%s%s◆ %s%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"
    divider
}

# 計算字串顯示寬度（中文字 3 bytes 顯示 2 格，ASCII 1 byte 1 格）
display_width() {
    local s="$1" total ascii nonascii
    total=$(printf '%s' "$s" | wc -c)
    ascii=$(printf '%s' "$s" | tr -cd '\1-\177' | wc -c)
    nonascii=$(( total - ascii ))
    printf '%d' $(( ascii + nonascii * 2 / 3 ))
}

# 依「顯示寬度」補齊到指定欄寬（CJK 佔 2 格，printf %-Ns 只認位元組故不可用）
pad_to() {
    local s="$1" target="$2" w pad
    w=$(display_width "$s")
    pad=$(( target - w ))
    [ "$pad" -lt 1 ] && pad=1
    printf '%s%*s' "$s" "$pad" ""
}

# 對齊輸出 key-value（key 統一補齊到 14 格顯示寬度）
kv() {
    local key="$1" val="$2" w pad
    w=$(display_width "$key")
    pad=$(( 14 - w ))
    [ "$pad" -lt 1 ] && pad=1
    printf ' %s%s%s%*s%s\n' "$C_CYAN" "$key" "$C_RESET" "$pad" "" "$val"
}

#-----------------------------------------------------------------------
# 確認與交互
#-----------------------------------------------------------------------
confirm() {
    local prompt="$1" reply
    printf '%s%s%s [y/N]: ' "$C_YELLOW" "$prompt" "$C_RESET"
    read -r reply || reply=""
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# 危險操作二次確認：必須完整輸入 yes
confirm_danger() {
    local prompt="$1" reply
    printf '%s⚠ %s%s\n' "$C_RED" "$prompt" "$C_RESET"
    printf '%s%s%s' "$C_RED" "$(t confirm.yes)" "$C_RESET"
    read -r reply || reply=""
    [ "$reply" = "yes" ]
}

pause() {
    printf '\n%s%s%s' "$C_DIM" "$(t pause)" "$C_RESET"
    read -r _ || true
}

#-----------------------------------------------------------------------
# 錯誤處理與清理
#-----------------------------------------------------------------------
on_error() {
    local line="$1" code="$2"
    err "內部錯誤：第 ${line} 行命令失敗（exit=${code}）"
    err "歡迎回報 issue: ${ISSUE_URL}"
}
trap 'on_error $LINENO $?' ERR

on_exit() {
    # 只在 TTY 恢復游標，否則轉義序列會污染管線輸出（cron / 日報）
    [ -t 1 ] && printf '\033[?25h' 2>/dev/null
    rm -rf "$TMP_DIR" 2>/dev/null || true
    return 0
}
trap on_exit EXIT

on_interrupt() {
    printf '\n'
    warn "已中斷，再見。"
    exit 130
}
trap on_interrupt INT

#-----------------------------------------------------------------------
# 環境檢測
#-----------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "$(t err.need_root)"
        err "$(t err.use_sudo)"
        exit 1
    fi
}

detect_os() {
    if [ "$(uname -s)" != "Linux" ]; then
        err "$(t err.linux_only)"
        exit 1
    fi
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_PRETTY="${PRETTY_NAME:-unknown}"
    else
        OS_ID="unknown" OS_PRETTY="unknown"
    fi

    case "$OS_ID" in
        debian|ubuntu)                       PKG_MGR="apt" ;;
        centos|rhel|rocky|almalinux|fedora)  PKG_MGR="dnf"
                                             command -v dnf >/dev/null 2>&1 || PKG_MGR="yum" ;;
        *)
            warn "$(printf "$(t err.unknown_os)" "$OS_PRETTY")"
            if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
            elif command -v dnf >/dev/null 2>&1;   then PKG_MGR="dnf"
            elif command -v yum >/dev/null 2>&1;   then PKG_MGR="yum"
            else
                err "$(t err.no_pkg)"
                exit 1
            fi
            ;;
    esac
}

# shellcheck disable=SC2034  # ARCH 由 endlessh / CrowdSec 二進制下載使用
detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            err "$(printf "$(t err.arch)" "$m")"
            exit 1
            ;;
    esac
}

# 統一包安裝入口
pkg_install() {
    case "$PKG_MGR" in
        apt)
            if [ "$APT_UPDATED" -eq 0 ]; then
                info "更新 apt 索引..."
                apt-get update -qq || warn "apt 索引更新失敗，嘗試繼續安裝"
                APT_UPDATED=1
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
            ;;
        dnf) dnf install -y -q "$@" ;;
        yum) yum install -y -q "$@" ;;
    esac
}

ensure_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    if [ "${#missing[@]}" -gt 0 ]; then
        warn "缺少基礎依賴：${missing[*]}"
        if confirm "是否自動安裝？"; then
            pkg_install "${missing[@]}" ca-certificates
            ok "依賴安裝完成"
        else
            warn "部分功能將不可用。"
        fi
    fi
}

# 建立工作目錄（唯讀模式下也需要 baseline 目錄）
ensure_dirs() {
    mkdir -p "$BLUE_ETC" "$BLUE_LIB" "$BLUE_LOG" "$BLUE_BACKUP" "$BLUE_BASELINE" 2>/dev/null || true
    chmod 700 "$BLUE_ETC" "$BLUE_LIB" "$BLUE_BACKUP" 2>/dev/null || true
}

#-----------------------------------------------------------------------
# 安全下載：HTTPS-only、顯示來源、重試、清楚報錯
#-----------------------------------------------------------------------
safe_download() {
    local url="$1" dest="$2"
    case "$url" in
        https://*) : ;;
        *)
            err "拒絕非 HTTPS 下載來源：${url}"
            return 1
            ;;
    esac
    info "下載來源: ${url}"
    if ! curl "${CURL_OPTS[@]}" --progress-bar -o "$dest" "$url"; then
        err "下載失敗：${url}"
        return 1
    fi
    return 0
}

verify_sha256() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        err "SHA256 校驗失敗！"
        err "  預期: ${expected}"
        err "  實際: ${actual}"
        err "檔案已刪除。可能是下載損壞或來源被篡改，請勿使用。"
        rm -f "$file"
        return 1
    fi
    ok "SHA256 校驗通過"
    return 0
}

#-----------------------------------------------------------------------
# 選單渲染
#-----------------------------------------------------------------------
menu_group() {
    printf '%s%s── %s ──%s\n' "$C_DIM" "$C_BOLD" "$*" "$C_RESET"
}

menu_item() {
    # menu_item NUM "label" ["hint"] [star=1]
    local num="$1" label="$2" hint="${3:-}" star="${4:-}"
    local star_s=""
    [ "$star" = "1" ] && star_s=" ${C_YELLOW}★${C_RESET}"
    printf ' %s%2s)%s  %s%s%s%s\n' \
        "$C_CYAN" "$num" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" "$star_s"
    if [ -n "$hint" ]; then
        printf '       %s%s%s\n' "$C_DIM" "$hint" "$C_RESET"
    fi
}

#=======================================================================
# 共用資料源：sshd 配置 / auth 日誌 / 防火牆 / 入侵防禦
#   全部靜默降級：取不到就回空字串，絕不中斷。
#=======================================================================

# sshd 設定來源狀態
#   注意：這兩個變數必須在「父層 shell」初始化。若在 $( ) 內賦值，
#   寫入只存在於子 shell，父層永遠讀不到（先前版本的真實 bug）。
SSHD_SNAPSHOT=""
SSHD_SRC=0           # 0=sshd -T 權威  1=檔案/預設值推定  2=本機無 SSH 服務

sshd_present() {
    command -v sshd >/dev/null 2>&1 || [ -f /etc/ssh/sshd_config ]
}

# 啟動時解析一次 sshd 設定來源
init_sshd_source() {
    SSHD_SNAPSHOT="$(sshd -T 2>/dev/null || true)"
    if [ -n "$SSHD_SNAPSHOT" ]; then
        SSHD_SRC=0
    elif sshd_present; then
        SSHD_SRC=1
    else
        SSHD_SRC=2
    fi
}

sshd_snapshot() {
    printf '%s' "$SSHD_SNAPSHOT"
}

# 降級 1：直接解析設定檔。
#   Debian/Ubuntu 的 sshd_config 首行為 Include sshd_config.d/*.conf，
#   而 OpenSSH 語意是「先取得者優先」，故 drop-in 必須排在主設定檔之前。
sshd_val_from_files() {
    local key="$1" files=() f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] && files+=("$f")
    done
    [ -f /etc/ssh/sshd_config ] && files+=("/etc/ssh/sshd_config")
    [ "${#files[@]}" -gt 0 ] || return 0
    grep -hiE "^[[:space:]]*${key}[[:space:]]+" "${files[@]}" 2>/dev/null \
        | head -1 | awk '{print tolower($2)}' || true
}

# 降級 2：OpenSSH 官方預設值。
#   關鍵：設定檔沒寫 PasswordAuthentication 不代表「沒開」，預設就是 yes。
#   不套用預設值會嚴重低報真實風險。
sshd_default() {
    case "$1" in
        permitrootlogin)        printf 'prohibit-password' ;;
        passwordauthentication) printf 'yes' ;;
        permitemptypasswords)   printf 'no' ;;
        pubkeyauthentication)   printf 'yes' ;;
        maxauthtries)           printf '6' ;;
        logingracetime)         printf '120' ;;
        port)                   printf '22' ;;
        *)                      printf '' ;;
    esac
}

# 取 sshd 有效配置的單一鍵值（小寫鍵）：sshd -T → 檔案 → 官方預設
sshd_val() {
    local key="$1" v
    case "$SSHD_SRC" in
        0)
            sshd_snapshot | awk -v k="$key" '$1==k{print $2; exit}' || true
            ;;
        1)
            # sshd -T 失敗（設定有誤 / 缺 privsep 目錄 / 舊版無 -T）→ 走降級鏈
            v="$(sshd_val_from_files "$key")"
            if [ -n "$v" ]; then printf '%s' "$v"; else sshd_default "$key"; fi
            ;;
        *)  : ;;   # 無 SSH 服務，回空字串
    esac
}

# 取值來源標註：非權威時附註，避免使用者誤把推定值當實測值
est_note() {
    [ "$SSHD_SRC" -eq 1 ] && printf ' %s' "（推定：sshd -T 不可用，依設定檔/OpenSSH 預設值推導）"
    return 0
}

# 偵測 auth 日誌來源
detect_auth_log() {
    if [ -r /var/log/auth.log ]; then
        AUTH_LOG="/var/log/auth.log"
    elif [ -r /var/log/secure ]; then
        AUTH_LOG="/var/log/secure"
    else
        AUTH_LOG=""
    fi
}

# 日誌檔降級路徑：粗略過濾出「今天 + 昨天」的行。
#   syslog 傳統格式為 "Jul 23 10:00:00"，新版 rsyslog 可能是 RFC3339
#   "2026-07-23T10:00:00"，兩種都比對。日期取不到就不加該 pattern，
#   避免 grep -F -e "" 退化成匹配全部。
auth_file_recent() {
    [ -n "$AUTH_LOG" ] || return 0
    local pats=() d
    for d in "$(date '+%b %e' 2>/dev/null || true)" \
             "$(date -d yesterday '+%b %e' 2>/dev/null || true)" \
             "$(date '+%Y-%m-%d' 2>/dev/null || true)" \
             "$(date -d yesterday '+%Y-%m-%d' 2>/dev/null || true)"; do
        [ -n "$d" ] && pats+=(-e "$d")
    done
    if [ "${#pats[@]}" -eq 0 ]; then
        cat "$AUTH_LOG" "${AUTH_LOG}.1" 2>/dev/null || true
        return 0
    fi
    cat "$AUTH_LOG" "${AUTH_LOG}.1" 2>/dev/null | grep -F "${pats[@]}" || true
}

# 輸出近 24 小時的 sshd 認證日誌
#   優先 journalctl（可精確按時間過濾），降級到日誌檔
auth_stream() {
    local since="${1:-24 hours ago}" out=""
    if command -v journalctl >/dev/null 2>&1; then
        # 關鍵：journalctl 無資料時會印 "-- No entries --" 這類 meta 行，
        # 那是非空字串。不先濾掉就會被誤判為「有資料」而不降級到日誌檔，
        # 導致所有統計恆為 0。
        out="$(journalctl --since "$since" -t sshd -t sshd-session --no-pager 2>/dev/null \
               | grep -v '^-- ' || true)"
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    auth_file_recent
}

# 防火牆狀態：回傳 "類型|狀態摘要"
fw_status() {
    if command -v ufw >/dev/null 2>&1; then
        local s
        s="$(ufw status 2>/dev/null | head -1 || true)"
        # 順序關鍵："Status: inactive" 也會匹配 *active*，
        # 必須先判 inactive，否則會把「防火牆已停用」誤報成「生效中」。
        case "$s" in
            *inactive*) printf 'ufw|inactive' ;;
            *active*)   printf 'ufw|active' ;;
            *)          printf 'ufw|inactive' ;;
        esac
        return 0
    fi
    if command -v nft >/dev/null 2>&1; then
        if nft list ruleset 2>/dev/null | grep -q 'hook input'; then
            printf 'nftables|active'
        else
            printf 'nftables|empty'
        fi
        return 0
    fi
    if command -v iptables >/dev/null 2>&1; then
        local pol
        pol="$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT/{print $3; exit}' || true)"
        if [ "$pol" = "DROP" ]; then printf 'iptables|active'; else printf 'iptables|open'; fi
        return 0
    fi
    printf 'none|missing'
}

# 入侵防禦引擎：回傳 "引擎|封禁數"
ips_status() {
    if command -v cscli >/dev/null 2>&1; then
        local n
        n="$(cscli decisions list -o json 2>/dev/null | grep -c '"id"' || true)"
        [ -z "$n" ] && n=0
        printf 'CrowdSec|%s' "$n"
        return 0
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        local n=0 jail jails
        jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ' || true)"
        for jail in $jails; do
            local c
            c="$(fail2ban-client status "$jail" 2>/dev/null | awk '/Total banned:/{print $NF; exit}' || true)"
            case "$c" in ''|*[!0-9]*) c=0 ;; esac
            n=$(( n + c ))
        done
        printf 'fail2ban|%s' "$n"
        return 0
    fi
    printf 'none|0'
}

# 待裝安全更新數（取不到回空）
pending_security_updates() {
    case "$PKG_MGR" in
        apt)
            if command -v apt-get >/dev/null 2>&1; then
                apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null \
                    | grep -c '^Inst.*security' || true
            fi
            ;;
        dnf|yum)
            if command -v dnf >/dev/null 2>&1; then
                dnf -q updateinfo list --security 2>/dev/null | grep -c . || true
            fi
            ;;
    esac
}

# 是否需要重啟
reboot_required() {
    if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
        t yes
    elif command -v needs-restarting >/dev/null 2>&1; then
        if needs-restarting -r >/dev/null 2>&1; then t no; else t yes; fi
    else
        t no
    fi
}

# 列出所有使用者的 authorized_keys 檔案路徑
list_authkey_files() {
    local user home
    while IFS=: read -r user _ _ _ _ home _; do
        [ -n "$home" ] || continue
        [ -d "$home" ] || continue
        for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
            [ -f "$f" ] && printf '%s\t%s\n' "$user" "$f"
        done
    done < /etc/passwd
}

# 計算單一 authorized_keys 內的有效金鑰數
count_valid_keys() {
    local f="$1" n=0 line
    [ -f "$f" ] || { printf '0'; return 0; }
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        if printf '%s\n' "$line" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1; then
            n=$(( n + 1 ))
        fi
    done < "$f"
    printf '%d' "$n"
}

#=======================================================================
# 評分引擎
#   score_add <組> <狀態 PASS|WARN|FAIL|SKIP> <權重> <標題> <說明> [修復提示]
#=======================================================================
SCORE_GOT=0
SCORE_MAX=0
SCORE_ROWS=()

score_reset() {
    SCORE_GOT=0
    SCORE_MAX=0
    SCORE_ROWS=()
}

score_add() {
    local group="$1" status="$2" weight="$3" title="$4" detail="${5:-}" fix="${6:-}"
    case "$status" in
        PASS) SCORE_GOT=$(( SCORE_GOT + weight ));     SCORE_MAX=$(( SCORE_MAX + weight )) ;;
        WARN) SCORE_GOT=$(( SCORE_GOT + weight / 2 )); SCORE_MAX=$(( SCORE_MAX + weight )) ;;
        FAIL)                                          SCORE_MAX=$(( SCORE_MAX + weight )) ;;
        SKIP) : ;;   # 本機不適用，不計入分母
    esac
    SCORE_ROWS+=("${group}|${status}|${title}|${detail}|${fix}")
}

score_pct() {
    if [ "$SCORE_MAX" -le 0 ]; then printf '0'; return 0; fi
    printf '%d' $(( SCORE_GOT * 100 / SCORE_MAX ))
}

score_bar() {
    local pct="$1" width="${2:-20}" filled i out=""
    filled=$(( pct * width / 100 ))
    for (( i = 0; i < width; i++ )); do
        if [ "$i" -lt "$filled" ]; then out="${out}▊"; else out="${out}░"; fi
    done
    printf '%s' "$out"
}

score_color() {
    local pct="$1"
    if   [ "$pct" -ge 90 ]; then printf '%s' "$C_GREEN"
    elif [ "$pct" -ge 75 ]; then printf '%s' "$C_CYAN"
    elif [ "$pct" -ge 60 ]; then printf '%s' "$C_YELLOW"
    elif [ "$pct" -ge 40 ]; then printf '%s' "$C_YELLOW"
    else                         printf '%s' "$C_RED"
    fi
}

score_grade() {
    local pct="$1"
    if   [ "$pct" -ge 90 ]; then t grade.excellent
    elif [ "$pct" -ge 75 ]; then t grade.good
    elif [ "$pct" -ge 60 ]; then t grade.pass
    elif [ "$pct" -ge 40 ]; then t grade.weak
    else                         t grade.critical
    fi
}

status_glyph() {
    case "$1" in
        PASS) printf '%s✔%s' "$C_GREEN"  "$C_RESET" ;;
        WARN) printf '%s▲%s' "$C_YELLOW" "$C_RESET" ;;
        FAIL) printf '%s✘%s' "$C_RED"    "$C_RESET" ;;
        *)    printf '%s–%s' "$C_DIM"    "$C_RESET" ;;
    esac
}

#=======================================================================
# 檢查項 · 第 1 組：身份與存取
#=======================================================================
checks_identity() {
    local g="身份與存取"

    # 1. root 可否 SSH 登入
    local prl note
    prl="$(sshd_val permitrootlogin)"; note="$(est_note)"
    case "$prl" in
        no)                score_add "$g" PASS 10 "root SSH 登入" "已完全禁止（no）${note}" ;;
        prohibit-password|without-password)
                           score_add "$g" PASS 8  "root SSH 登入" "僅允許金鑰（${prl}）${note}" ;;
        yes)               score_add "$g" FAIL 10 "root SSH 登入" "允許 root 直接登入${note}" "選單 10 · root 蜜罐" ;;
        forced-commands-only)
                           score_add "$g" PASS 8  "root SSH 登入" "${prl}${note}" ;;
        *)                 score_add "$g" SKIP 0  "root SSH 登入" "本機未安裝 SSH 服務" ;;
    esac

    # 2. 密碼認證
    local pa
    pa="$(sshd_val passwordauthentication)"; note="$(est_note)"
    case "$pa" in
        no)  score_add "$g" PASS 10 "密碼認證" "已關閉，僅金鑰登入${note}" ;;
        yes) score_add "$g" FAIL 10 "密碼認證" "開啟中，可被暴破${note}" "選單 5 · 標準加固" ;;
        *)   score_add "$g" SKIP 0  "密碼認證" "本機未安裝 SSH 服務" ;;
    esac

    # 3. 空密碼登入
    local pep
    pep="$(sshd_val permitemptypasswords)"; note="$(est_note)"
    case "$pep" in
        no)  score_add "$g" PASS 5 "空密碼登入" "已禁止${note}" ;;
        yes) score_add "$g" FAIL 5 "空密碼登入" "允許空密碼，極度危險${note}" "選單 5 · 標準加固" ;;
        *)   score_add "$g" SKIP 0 "空密碼登入" "本機未安裝 SSH 服務" ;;
    esac

    # 4. uid=0 帳戶數
    local uid0 n0
    uid0="$(awk -F: '$3==0{printf "%s ", $1}' /etc/passwd 2>/dev/null || true)"
    n0="$(printf '%s' "$uid0" | wc -w | tr -d ' ')"
    if [ "$n0" = "1" ]; then
        score_add "$g" PASS 6 "uid=0 帳戶" "僅 root（正常）"
    elif [ "$n0" = "0" ]; then
        score_add "$g" SKIP 0 "uid=0 帳戶" "無法讀取 /etc/passwd"
    else
        score_add "$g" WARN 6 "uid=0 帳戶" "共 ${n0} 個：${uid0}— 若非你刻意設置，這是後門強指標" "選單 16 · IOC 快檢"
    fi

    # 5. 空密碼帳戶
    local emptypw
    emptypw="$(awk -F: '($2==""){printf "%s ", $1}' /etc/shadow 2>/dev/null || true)"
    if [ -z "$emptypw" ]; then
        score_add "$g" PASS 6 "空密碼帳戶" "無"
    else
        score_add "$g" FAIL 6 "空密碼帳戶" "存在：${emptypw}" "passwd -l <user>"
    fi

    # 6. sudoers NOPASSWD
    local nopw
    nopw="$(grep -rhE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | wc -l | tr -d ' ' || true)"
    case "$nopw" in ''|*[!0-9]*) nopw=0 ;; esac
    if [ "$nopw" -eq 0 ]; then
        score_add "$g" PASS 4 "sudo 免密規則" "無 NOPASSWD"
    else
        score_add "$g" WARN 4 "sudo 免密規則" "${nopw} 條 NOPASSWD（雲鏡像常見預設，確認是你要的）"
    fi

    # 7. authorized_keys 盤點
    local keyfiles total=0 line user f n detail=""
    keyfiles="$(list_authkey_files 2>/dev/null || true)"
    if [ -n "$keyfiles" ]; then
        while IFS=$'\t' read -r user f; do
            [ -n "$f" ] || continue
            n="$(count_valid_keys "$f")"
            total=$(( total + n ))
            detail="${detail}${user}:${n} "
        done <<< "$keyfiles"
    fi
    if [ "$total" -gt 0 ]; then
        score_add "$g" PASS 8 "公鑰盤點" "共 ${total} 把：${detail}— 逐一確認都是你自己的"
    else
        score_add "$g" FAIL 8 "公鑰盤點" "全系統無任何有效公鑰，禁用密碼登入會直接鎖門" "先配公鑰再加固"
    fi

    # 8. MaxAuthTries
    local mat
    mat="$(sshd_val maxauthtries)"; note="$(est_note)"
    case "$mat" in
        ''|*[!0-9]*) score_add "$g" SKIP 0 "MaxAuthTries" "本機未安裝 SSH 服務" ;;
        *)
            if   [ "$mat" -le 3 ]; then score_add "$g" PASS 4 "MaxAuthTries" "${mat}${note}"
            elif [ "$mat" -le 6 ]; then score_add "$g" WARN 4 "MaxAuthTries" "${mat}（建議 ≤3）${note}" "選單 5 · 標準加固"
            else                        score_add "$g" FAIL 4 "MaxAuthTries" "${mat}（過於寬鬆）${note}" "選單 5 · 標準加固"
            fi
            ;;
    esac

    # 9. LoginGraceTime
    local lgt
    lgt="$(sshd_val logingracetime)"; note="$(est_note)"
    case "$lgt" in
        ''|*[!0-9]*) score_add "$g" SKIP 0 "LoginGraceTime" "本機未安裝 SSH 服務" ;;
        *)
            if [ "$lgt" -le 30 ] && [ "$lgt" -gt 0 ]; then
                score_add "$g" PASS 3 "LoginGraceTime" "${lgt}s${note}"
            else
                score_add "$g" WARN 3 "LoginGraceTime" "${lgt}s（建議 20-30s，降低半開連線耗用）${note}" "選單 5 · 標準加固"
            fi
            ;;
    esac
}

#=======================================================================
# 檢查項 · 第 2 組：網路暴露
#=======================================================================
checks_exposure() {
    local g="網路暴露"

    # 10. 防火牆
    local fw fwtype fwstate
    fw="$(fw_status)"
    fwtype="${fw%%|*}"
    fwstate="${fw##*|}"
    case "$fwstate" in
        active) score_add "$g" PASS 12 "防火牆" "${fwtype} 生效中" ;;
        *)      score_add "$g" FAIL 12 "防火牆" "${fwtype}：${fwstate}（入站無過濾）" "選單 12 · 防火牆" ;;
    esac

    # 11. 對公網監聽的服務
    #     注意：ss 缺席（無法列舉）與確實 0 個監聽是兩件事，不可混為一談
    local listen n
    if ! command -v ss >/dev/null 2>&1; then
        score_add "$g" SKIP 0 "公網監聽埠" "無法列舉（缺 iproute2/ss）"
    else
        listen="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' || true)"
        n="$(printf '%s' "$listen" | grep -c . || true)"
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        if   [ "$n" -eq 0 ]; then score_add "$g" PASS 6 "公網監聽埠" "0 個對外監聽"
        elif [ "$n" -le 3 ]; then score_add "$g" PASS 6 "公網監聽埠" "${n} 個（精簡）"
        elif [ "$n" -le 6 ]; then score_add "$g" WARN 6 "公網監聽埠" "${n} 個 — 逐一確認是否都需要對公網開放"
        else                      score_add "$g" FAIL 6 "公網監聽埠" "${n} 個，攻擊面偏大" "選單 12 · 防火牆"
        fi
    fi

    # 12. Docker 繞過防火牆
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local pub
        pub="$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -o '0\.0\.0\.0:[0-9]*' | wc -l | tr -d ' ' || true)"
        case "$pub" in ''|*[!0-9]*) pub=0 ;; esac
        if [ "$pub" -eq 0 ]; then
            score_add "$g" PASS 8 "Docker 埠暴露" "無容器發布到 0.0.0.0"
        elif grep -q 'DOCKER-USER' /etc/ufw/after.rules 2>/dev/null; then
            score_add "$g" PASS 8 "Docker 埠暴露" "${pub} 個發布埠，已裝 DOCKER-USER 過濾鏈"
        elif [ "$fwstate" = "active" ]; then
            score_add "$g" FAIL 8 "Docker 埠暴露" "${pub} 個發布埠繞過了防火牆（Docker 直改 iptables）" "選單 12 · Docker 繞過修復"
        else
            score_add "$g" WARN 8 "Docker 埠暴露" "${pub} 個發布埠且防火牆未啟用" "選單 12 · 防火牆"
        fi
    else
        score_add "$g" SKIP 0 "Docker 埠暴露" "未安裝 Docker"
    fi

    # 13. IPv6 防護同步
    if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
        if [ "$fwtype" = "ufw" ]; then
            if grep -qE '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
                score_add "$g" PASS 4 "IPv6 防護" "UFW 已同步管控 IPv6"
            else
                score_add "$g" FAIL 4 "IPv6 防護" "有公網 IPv6 但 UFW 未管 IPv6（v4 封了 v6 沒封）" "選單 12 · 防火牆"
            fi
        else
            score_add "$g" WARN 4 "IPv6 防護" "有公網 IPv6，請確認防火牆規則同時覆蓋 v6"
        fi
    else
        score_add "$g" SKIP 0 "IPv6 防護" "無公網 IPv6"
    fi
}

#=======================================================================
# 檢查項 · 第 3 組：補丁
#=======================================================================
checks_patch() {
    local g="補丁"

    # 14. 待裝安全更新
    local secn
    secn="$(pending_security_updates 2>/dev/null | tr -d ' \n' || true)"
    case "$secn" in ''|*[!0-9]*) secn="" ;; esac
    if [ -z "$secn" ]; then
        score_add "$g" SKIP 0 "待裝安全更新" "無法查詢"
    elif [ "$secn" -eq 0 ]; then
        score_add "$g" PASS 10 "待裝安全更新" "0 個，已是最新"
    elif [ "$secn" -le 5 ]; then
        score_add "$g" WARN 10 "待裝安全更新" "${secn} 個待裝" "選單 4 · 基礎加固"
    else
        score_add "$g" FAIL 10 "待裝安全更新" "${secn} 個待裝，補丁嚴重滯後" "選單 4 · 基礎加固"
    fi

    # 15. 自動安全更新
    local auto="no"
    if [ "$PKG_MGR" = "apt" ]; then
        if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then auto="yes"; fi
    else
        if systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1 \
        || systemctl is-enabled dnf-automatic-install.timer >/dev/null 2>&1; then auto="yes"; fi
    fi
    if [ "$auto" = "yes" ]; then
        score_add "$g" PASS 8 "自動安全更新" "已啟用"
    else
        score_add "$g" FAIL 8 "自動安全更新" "未啟用 — 這是投入產出比最高的一項" "選單 4 · 基礎加固"
    fi

    # 16. 重啟需求
    local rb
    rb="$(reboot_required)"
    if [ "$rb" = "$(t no)" ]; then
        score_add "$g" PASS 3 "重啟需求" "無"
    else
        score_add "$g" WARN 3 "重啟需求" "有內核/庫更新待生效，請安排重啟"
    fi
}

#=======================================================================
# 檢查項 · 第 4 組：內核與掛載
#=======================================================================
# 期望的 sysctl：鍵 期望值
SYSCTL_NET_EXPECT="
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.log_martians=1
"
SYSCTL_KERN_EXPECT="
kernel.kptr_restrict=1
kernel.dmesg_restrict=1
kernel.sysrq=0
kernel.randomize_va_space=2
fs.protected_hardlinks=1
fs.protected_symlinks=1
"

# 比對一組 sysctl，回傳未達標的鍵（空格分隔）
sysctl_mismatch() {
    local expect="$1" line key want got bad=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        want="${line##*=}"
        got="$(sysctl -n "$key" 2>/dev/null || true)"
        [ -n "$got" ] || continue
        if [ "$got" != "$want" ]; then
            bad="${bad}${key} "
        fi
    done <<< "$expect"
    printf '%s' "$bad"
}

checks_kernel() {
    local g="內核與掛載"

    # 17. 網路層 sysctl
    local badnet nbad
    badnet="$(sysctl_mismatch "$SYSCTL_NET_EXPECT")"
    nbad="$(printf '%s' "$badnet" | wc -w | tr -d ' ')"
    if [ "$nbad" -eq 0 ]; then
        score_add "$g" PASS 8 "網路層 sysctl" "7 項全部達標"
    elif [ "$nbad" -le 2 ]; then
        score_add "$g" WARN 8 "網路層 sysctl" "${nbad} 項未達標：${badnet}" "選單 4 · 基礎加固"
    else
        score_add "$g" FAIL 8 "網路層 sysctl" "${nbad} 項未達標：${badnet}" "選單 4 · 基礎加固"
    fi

    # 18. 內核層 sysctl
    local badk nbadk
    badk="$(sysctl_mismatch "$SYSCTL_KERN_EXPECT")"
    nbadk="$(printf '%s' "$badk" | wc -w | tr -d ' ')"
    if [ "$nbadk" -eq 0 ]; then
        score_add "$g" PASS 6 "內核層 sysctl" "6 項全部達標"
    elif [ "$nbadk" -le 2 ]; then
        score_add "$g" WARN 6 "內核層 sysctl" "${nbadk} 項未達標：${badk}" "選單 4 · 基礎加固"
    else
        score_add "$g" FAIL 6 "內核層 sysctl" "${nbadk} 項未達標：${badk}" "選單 4 · 基礎加固"
    fi

    # 19. /dev/shm 掛載選項
    local shmopt
    shmopt="$(findmnt -no OPTIONS /dev/shm 2>/dev/null || true)"
    if [ -z "$shmopt" ]; then
        score_add "$g" SKIP 0 "/dev/shm 掛載" "無法讀取"
    elif printf '%s' "$shmopt" | grep -q noexec && printf '%s' "$shmopt" | grep -q nosuid; then
        score_add "$g" PASS 5 "/dev/shm 掛載" "noexec,nosuid 已生效"
    else
        score_add "$g" FAIL 5 "/dev/shm 掛載" "缺 noexec/nosuid — 攻擊者常在此落地執行檔" "選單 4 · 基礎加固"
    fi

    # 20. /tmp 掛載選項（獨立分區才有意義）
    local tmpsrc tmpopt
    tmpsrc="$(findmnt -no SOURCE --target /tmp 2>/dev/null || true)"
    tmpopt="$(findmnt -no OPTIONS --target /tmp 2>/dev/null || true)"
    if [ "$(findmnt -no TARGET --target /tmp 2>/dev/null || true)" != "/tmp" ]; then
        score_add "$g" WARN 4 "/tmp 掛載" "/tmp 未獨立掛載（在 ${tmpsrc:-根分區} 上），無法單獨加 noexec" "選單 4 · 基礎加固"
    elif printf '%s' "$tmpopt" | grep -q noexec; then
        score_add "$g" PASS 4 "/tmp 掛載" "noexec 已生效"
    else
        score_add "$g" FAIL 4 "/tmp 掛載" "獨立掛載但缺 noexec" "選單 4 · 基礎加固"
    fi

    # 21. core dump
    local cd_soft
    cd_soft="$(ulimit -c 2>/dev/null || true)"
    if [ "$cd_soft" = "0" ]; then
        score_add "$g" PASS 3 "core dump" "已停用"
    else
        score_add "$g" WARN 3 "core dump" "未停用（可能洩漏記憶體內的憑證）" "選單 4 · 基礎加固"
    fi
}

#=======================================================================
# 檢查項 · 第 5 組：偵測能力
#=======================================================================
checks_detection() {
    local g="偵測能力"

    # 22. 入侵防禦引擎
    local ips engine bans
    ips="$(ips_status)"
    engine="${ips%%|*}"
    bans="${ips##*|}"
    case "$engine" in
        CrowdSec) score_add "$g" PASS 12 "入侵防禦" "CrowdSec 運行中，${bans} 條封禁決策" ;;
        fail2ban) score_add "$g" PASS 10 "入侵防禦" "fail2ban 運行中，累計封禁 ${bans}" ;;
        *)        score_add "$g" FAIL 12 "入侵防禦" "未安裝 — 暴破無人攔截" "選單 8 · CrowdSec 或 9 · fail2ban" ;;
    esac

    # 23. auditd
    if systemctl is-active auditd >/dev/null 2>&1; then
        score_add "$g" PASS 6 "auditd" "運行中"
    elif command -v auditctl >/dev/null 2>&1; then
        score_add "$g" WARN 6 "auditd" "已安裝但未運行" "systemctl enable --now auditd"
    else
        score_add "$g" WARN 6 "auditd" "未安裝（事後追查缺少系統調用記錄）" "選單 5 · 標準加固"
    fi

    # 24. 檔案完整性基線（AIDE）
    if command -v aide >/dev/null 2>&1; then
        local db
        db="$(find /var/lib/aide -maxdepth 1 -name 'aide.db*' -type f 2>/dev/null | head -1 || true)"
        if [ -n "$db" ]; then
            local age
            age="$(( ( $(date +%s) - $(stat -c %Y "$db" 2>/dev/null || date +%s) ) / 86400 ))"
            if [ "$age" -le 30 ]; then
                score_add "$g" PASS 6 "檔案完整性基線" "AIDE 基線 ${age} 天前建立"
            else
                score_add "$g" WARN 6 "檔案完整性基線" "AIDE 基線已 ${age} 天未更新"
            fi
        else
            score_add "$g" WARN 6 "檔案完整性基線" "AIDE 已裝但無基線資料庫" "aideinit"
        fi
    else
        score_add "$g" WARN 6 "檔案完整性基線" "未安裝 AIDE" "選單 5 · 標準加固"
    fi

    # 25. 登入告警
    if [ -x /usr/local/bin/oece-blue-login-alert ]; then
        score_add "$g" PASS 5 "登入即時告警" "PAM 鉤子已安裝"
    else
        score_add "$g" WARN 5 "登入即時告警" "未安裝 — 有人成功登入你不會知道" "選單 14 · 登入即時告警"
    fi

    # 26. 日誌保留
    local keep
    keep="$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[MG]' | head -1 || true)"
    if [ -n "$keep" ]; then
        score_add "$g" PASS 3 "日誌保留" "journald 佔用 ${keep}"
    else
        score_add "$g" SKIP 0 "日誌保留" "無 journald"
    fi
}

#=======================================================================
# 檢查項 · 第 6 組：完整性與入侵指標
#=======================================================================
checks_integrity() {
    local g="完整性"

    # 27. /etc/ld.so.preload
    if [ -s /etc/ld.so.preload ]; then
        score_add "$g" FAIL 8 "ld.so.preload" "非空！這是 rootkit 最經典的落腳點：$(tr '\n' ' ' < /etc/ld.so.preload)" "選單 16 · IOC 快檢"
    else
        score_add "$g" PASS 8 "ld.so.preload" "空或不存在（正常）"
    fi

    # 28. 指向已刪除檔案的進程（挖礦/後門強指標）
    local deleted=0 n e tgt
    for e in /proc/[0-9]*/exe; do
        tgt="$(readlink "$e" 2>/dev/null || true)"
        case "$tgt" in
            *' (deleted)') deleted=$(( deleted + 1 )) ;;
        esac
    done
    if [ "$deleted" -eq 0 ]; then
        score_add "$g" PASS 8 "已刪除二進制進程" "無"
    else
        score_add "$g" FAIL 8 "已刪除二進制進程" "${deleted} 個進程的執行檔已被刪除 — 挖礦木馬典型特徵" "選單 16 · IOC 快檢"
    fi

    # 29. SUID 檔案數 vs 基線
    local suidnow base
    suidnow="$(find / -xdev -perm -4000 -type f 2>/dev/null | sort || true)"
    n="$(printf '%s' "$suidnow" | grep -c . || true)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    base="${BLUE_BASELINE}/suid.list"
    if [ -f "$base" ]; then
        local added
        added="$(comm -13 "$base" <(printf '%s\n' "$suidnow") 2>/dev/null | grep -c . || true)"
        case "$added" in ''|*[!0-9]*) added=0 ;; esac
        if [ "$added" -eq 0 ]; then
            score_add "$g" PASS 7 "SUID 檔案" "${n} 個，與基線一致"
        else
            score_add "$g" FAIL 7 "SUID 檔案" "比基線新增 ${added} 個 SUID — 提權後門常見手法" "選單 16 · IOC 快檢"
        fi
    else
        printf '%s\n' "$suidnow" > "$base" 2>/dev/null || true
        score_add "$g" WARN 7 "SUID 檔案" "${n} 個，已建立首次基線（下次即可比對變化）"
    fi

    # 30. 可疑計劃任務（含遠端拉取執行）
    local suspicious
    # /etc/cron.d 與 /etc/cron.*/ 這兩個路徑會重疊命中同一檔案，故必須 sort -u
    suspicious="$(grep -rlE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh|base64[[:space:]]+-d' \
        /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily \
        /etc/cron.weekly /etc/cron.monthly /var/spool/cron 2>/dev/null \
        | sort -u | head -5 || true)"
    if [ -z "$suspicious" ]; then
        score_add "$g" PASS 6 "計劃任務" "無「下載即執行」模式"
    else
        score_add "$g" FAIL 6 "計劃任務" "發現遠端拉取執行：$(printf '%s' "$suspicious" | tr '\n' ' ')" "選單 16 · IOC 快檢"
    fi

    # 31. 臨時目錄可執行檔
    local tmpexec
    tmpexec="$(find /tmp /dev/shm /var/tmp -maxdepth 2 -type f -perm -u+x 2>/dev/null | head -20 | grep -c . || true)"
    case "$tmpexec" in ''|*[!0-9]*) tmpexec=0 ;; esac
    if [ "$tmpexec" -eq 0 ]; then
        score_add "$g" PASS 5 "臨時目錄可執行檔" "無"
    else
        score_add "$g" WARN 5 "臨時目錄可執行檔" "${tmpexec} 個 — 多數是正常構建產物，但值得逐一確認" "選單 16 · IOC 快檢"
    fi

    # 32. 全域可寫目錄缺 sticky bit
    local ww
    ww="$(find / -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null | head -10 | grep -c . || true)"
    case "$ww" in ''|*[!0-9]*) ww=0 ;; esac
    if [ "$ww" -eq 0 ]; then
        score_add "$g" PASS 4 "全域可寫目錄" "皆有 sticky bit"
    else
        score_add "$g" WARN 4 "全域可寫目錄" "${ww} 個缺 sticky bit，任何用戶可刪他人檔案"
    fi
}

#=======================================================================
# 模塊 2 · 加固評分體檢
#=======================================================================
run_all_checks() {
    score_reset
    checks_identity
    checks_exposure
    checks_patch
    checks_kernel
    checks_detection
    checks_integrity
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    printf '%s' "$s"
}

# 沙盒與真機 JSON 共用的六組鍵。真機檢查組對到這六個桶。
group_bucket() {
    case "$1" in
        身份與存取|identity|ssh) printf 'ssh' ;;
        暴露面|exposure|fw) printf 'fw' ;;
        偵測與響應|detection|ips) printf 'ips' ;;
        誘捕|trap) printf 'trap' ;;
        內核與掛載|kernel|kern) printf 'kern' ;;
        完整性|integrity|aud) printf 'aud' ;;
        *) printf '' ;;
    esac
}

emit_audit_json() {
    local host="$1" region="$2" score="$3" passed="$4"
    local ssh_p="$5" ssh_t="$6" fw_p="$7" fw_t="$8"
    local ips_p="$9" ips_t="${10}" trap_p="${11}" trap_t="${12}"
    local kern_p="${13}" kern_t="${14}" aud_p="${15}" aud_t="${16}"
    printf '{"host":"%s","region":"%s","score":%s,"passed_checks":%s,"total_checks":32,"groups":{"ssh":{"passed":%s,"total":%s},"fw":{"passed":%s,"total":%s},"ips":{"passed":%s,"total":%s},"trap":{"passed":%s,"total":%s},"kern":{"passed":%s,"total":%s},"aud":{"passed":%s,"total":%s}}}\n' \
        "$(json_escape "$host")" "$(json_escape "$region")" \
        "$score" "$passed" \
        "$ssh_p" "$ssh_t" "$fw_p" "$fw_t" "$ips_p" "$ips_t" \
        "$trap_p" "$trap_t" "$kern_p" "$kern_t" "$aud_p" "$aud_t"
}

emit_live_audit_json() {
    local bucket status title host region
    local ssh_p=0 fw_p=0 ips_p=0 trap_p=0 kern_p=0 aud_p=0
    local ssh_t=0 fw_t=0 ips_t=0 trap_t=0 kern_t=0 aud_t=0
    local passed=0 row
    for row in "${SCORE_ROWS[@]}"; do
        IFS='|' read -r _ status title _ _ <<< "$row"
        bucket="$(group_bucket "${row%%|*}")"
        case "$title" in
            *蜜罐*|*焦油*|*endlessh*|*honeypot*) bucket="trap" ;;
        esac
        [ -n "$bucket" ] || continue
        case "$bucket" in
            ssh)  ssh_t=$(( ssh_t + 1 ));  [ "$status" = "PASS" ] && ssh_p=$(( ssh_p + 1 )) ;;
            fw)   fw_t=$(( fw_t + 1 ));    [ "$status" = "PASS" ] && fw_p=$(( fw_p + 1 )) ;;
            ips)  ips_t=$(( ips_t + 1 ));  [ "$status" = "PASS" ] && ips_p=$(( ips_p + 1 )) ;;
            trap) trap_t=$(( trap_t + 1 )); [ "$status" = "PASS" ] && trap_p=$(( trap_p + 1 )) ;;
            kern) kern_t=$(( kern_t + 1 )); [ "$status" = "PASS" ] && kern_p=$(( kern_p + 1 )) ;;
            aud)  aud_t=$(( aud_t + 1 ));  [ "$status" = "PASS" ] && aud_p=$(( aud_p + 1 )) ;;
        esac
        [ "$status" = "PASS" ] && passed=$(( passed + 1 ))
    done
    host="$(hostname 2>/dev/null || printf 'localhost')"
    region="${OS_PRETTY:-linux}"
    emit_audit_json "$host" "$region" "$(score_pct)" "$passed" \
        "$ssh_p" "${ssh_t:-0}" "$fw_p" "${fw_t:-0}" "$ips_p" "${ips_t:-0}" \
        "$trap_p" "${trap_t:-0}" "$kern_p" "${kern_t:-0}" "$aud_p" "${aud_t:-0}"
}

module_audit() {
    if [ "$AUDIT_JSON" -eq 0 ]; then
        section "加固評分體檢"
        info "唯讀掃描，不改動任何配置。SUID 全盤掃描約需 5-20 秒…"
        printf '\n'
    fi

    run_all_checks
    if [ "$AUDIT_JSON" -eq 1 ]; then
        emit_live_audit_json
        return 0
    fi

    local pct col grade lastgroup="" row group status title detail fix
    pct="$(score_pct)"
    col="$(score_color "$pct")"
    grade="$(score_grade "$pct")"

    for row in "${SCORE_ROWS[@]}"; do
        IFS='|' read -r group status title detail fix <<< "$row"
        if [ "$group" != "$lastgroup" ]; then
            printf '\n%s%s── %s ──%s\n' "$C_DIM" "$C_BOLD" "$group" "$C_RESET"
            lastgroup="$group"
        fi
        printf ' %s %s%s%s %s\n' "$(status_glyph "$status")" "$C_BOLD" "$(pad_to "$title" 22)" "$C_RESET" "$detail"
        if [ -n "$fix" ] && [ "$status" != "PASS" ]; then
            printf '     %s↳ 修復：%s%s\n' "$C_DIM" "$fix" "$C_RESET"
        fi
    done

    printf '\n'
    divider
    printf ' %s加固評分%s  %s%s%s  %s%s/100%s  ·  %s%s%s\n' \
        "$C_BOLD" "$C_RESET" \
        "$col" "$(score_bar "$pct")" "$C_RESET" \
        "$col" "$pct" "$C_RESET" \
        "$col" "$grade" "$C_RESET"
    printf ' %s得分 %s / 滿分 %s（不適用項目已排除在分母外）%s\n' \
        "$C_DIM" "$SCORE_GOT" "$SCORE_MAX" "$C_RESET"
    # 機器可解析行。日報只讀這一行，不依賴中文文案。
    printf 'score=%s got=%s max=%s\n' "$pct" "$SCORE_GOT" "$SCORE_MAX"
    divider

    # 存檔供面板做「vs 昨日」比較
    ensure_dirs
    printf '%s\n' "$pct" > "${BLUE_LIB}/score.current" 2>/dev/null || true
    local today
    today="$(date +%F)"
    if [ ! -f "${BLUE_LIB}/score.${today}" ]; then
        printf '%s\n' "$pct" > "${BLUE_LIB}/score.${today}" 2>/dev/null || true
    fi

    printf '\n%s下一步建議%s\n' "$C_BOLD" "$C_RESET"
    if [ "$pct" -lt 60 ]; then
        printf ' %s→%s 先跑「選單 4 · 一鍵加固 · 基礎」，零鎖門風險，能拿回大部分分數\n' "$C_GREEN" "$C_RESET"
    fi
    printf ' %s→%s 再跑「選單 5 · 一鍵加固 · 標準」（會動 SSH，全程掛自動回滾定時器）\n' "$C_GREEN" "$C_RESET"
    printf ' %s→%s 想看即時態勢：「選單 1 · 藍隊面板」\n' "$C_GREEN" "$C_RESET"
}

#=======================================================================
# 即時統計（面板資料源）· 全部靜默降級
#=======================================================================

# 24h 失敗登入次數
stat_failed_24h() {
    local n
    # 必須含 "not allowed because"：被 DenyUsers/AllowUsers 擋下的嘗試不會產生
    # "Failed password"，漏掉它會出現「失敗登入 0 / 蜜罐命中 14」這種自相矛盾的數字。
    n="$(auth_stream "24 hours ago" \
        | grep -cE 'Failed (password|publickey)|Invalid user|authentication failure|not allowed because' || true)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

# 蜜罐命中：針對誘餌用戶名的登入嘗試，輸出 "總數|明細"
stat_honeypot() {
    local stream users_re u total detail="" c
    stream="$(auth_stream "24 hours ago")"
    users_re="$(printf '%s' "$HONEY_USERS" | tr ' ' '|')"

    # 用單一 regex 計「命中行數」。早期版本對每個誘餌用戶名各跑一次 grep 再相加，
    # 同一行日誌會被多個 pattern 重複計算，導致命中數虛高於實際失敗登入數。
    total="$(printf '%s\n' "$stream" \
        | grep -cE "(Invalid user (${users_re})[ ,]|Failed [^ ]+ for (invalid user )?(${users_re}) from |User (${users_re}) from .*not allowed)" || true)"
    case "$total" in ''|*[!0-9]*) total=0 ;; esac

    if [ "$total" -gt 0 ]; then
        for u in $HONEY_USERS; do
            c="$(printf '%s\n' "$stream" \
                | grep -cE "(Invalid user ${u}[ ,]|Failed [^ ]+ for (invalid user )?${u} from |User ${u} from .*not allowed)" || true)"
            case "$c" in ''|*[!0-9]*) c=0 ;; esac
            [ "$c" -gt 0 ] && detail="${detail}${u} ${c} / "
        done
    fi
    detail="${detail% / }"
    printf '%s|%s' "$total" "$detail"
}

# Top N 攻擊來源 IP
stat_top_attackers() {
    local n="${1:-3}"
    auth_stream "24 hours ago" \
        | grep -E 'Failed |Invalid user' \
        | grep -oE 'from ([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9a-fA-F:]*:[0-9a-fA-F:]+)' \
        | awk '{print $2}' \
        | sort | uniq -c | sort -rn | head -"$n" \
        | awk '{printf "%s (%s 次)  ", $2, $1}' || true
}

# endlessh 統計："困住數|累計小時"
stat_endlessh() {
    if ! systemctl is-active endlessh >/dev/null 2>&1; then
        printf '|'
        return 0
    fi
    local logs accepts secs
    logs="$(journalctl -u endlessh --since '7 days ago' --no-pager 2>/dev/null || true)"
    accepts="$(printf '%s\n' "$logs" | grep -c 'ACCEPT' || true)"
    case "$accepts" in ''|*[!0-9]*) accepts=0 ;; esac
    # CLOSE 行帶 time=<秒> 欄位
    secs="$(printf '%s\n' "$logs" | grep -oE 'time=[0-9.]+' | cut -d= -f2 \
        | awk '{s+=$1} END{printf "%.1f", s/3600}' || true)"
    [ -n "$secs" ] || secs="0.0"
    printf '%s|%s' "$accepts" "$secs"
}

# 當前登入會話
stat_sessions() {
    who 2>/dev/null | awk '{printf "%s@%s ", $1, ($5!="" ? $5 : "local")}' | tr -d '()' || true
}

# 監聽埠摘要（含服務名）
stat_listen_brief() {
    ss -ltnpH 2>/dev/null \
        | awk '{
                addr=$4
                sub(/\]$/, "", addr)
                n=split(addr, a, ":")
                port=a[n]
                svc=""
                if (match($0, /users:\(\("[^"]+/)) {
                    svc=substr($0, RSTART+9, RLENGTH-9)
                }
                if (port ~ /^[0-9]+$/ && !(port in seen)) {
                    seen[port]=1
                    printf "%s(%s) ", port, (svc=="" ? "?" : svc)
                }
               }' || true
}

#=======================================================================
# 模塊 1 · 藍隊面板
#=======================================================================
render_panel() {
    local pct col grade fw fwtype fwstate ips engine bans
    local failed hp hptotal hpdetail top esh eshn eshh sess listen secn rb load disk

    run_all_checks
    pct="$(score_pct)"
    col="$(score_color "$pct")"
    grade="$(score_grade "$pct")"

    fw="$(fw_status)";  fwtype="${fw%%|*}";  fwstate="${fw##*|}"
    ips="$(ips_status)"; engine="${ips%%|*}"; bans="${ips##*|}"
    failed="$(stat_failed_24h)"
    hp="$(stat_honeypot)"; hptotal="${hp%%|*}"; hpdetail="${hp##*|}"
    top="$(stat_top_attackers 3)"
    esh="$(stat_endlessh)"; eshn="${esh%%|*}"; eshh="${esh##*|}"
    sess="$(stat_sessions)"
    listen="$(stat_listen_brief)"
    secn="$(pending_security_updates 2>/dev/null | tr -d ' \n' || true)"
    rb="$(reboot_required)"
    load="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || true)"
    disk="$(df -h / 2>/dev/null | awk 'NR==2{print $5" 已用 / "$2}' || true)"

    # 與昨日比較
    local yest delta=""
    yest="$(cat "${BLUE_LIB}/score.$(date -d yesterday +%F 2>/dev/null || echo none)" 2>/dev/null || true)"
    if [ -n "$yest" ] && [ "$yest" -eq "$yest" ] 2>/dev/null; then
        local d=$(( pct - yest ))
        if   [ "$d" -gt 0 ]; then delta="  ${C_GREEN}↑ +${d}${C_RESET} vs 昨日"
        elif [ "$d" -lt 0 ]; then delta="  ${C_RED}↓ ${d}${C_RESET} vs 昨日"
        else                      delta="  ${C_DIM}持平${C_RESET}"
        fi
    fi

    # 標題列以顯示寬度補齊到 62 欄，CJK 才不會把右邊框頂歪
    local host hdr
    host="$(hostname 2>/dev/null || echo '-')"
    [ "${#host}" -gt 16 ] && host="${host:0:16}"
    hdr="$(printf '  OECE-X BLUE · 藍隊態勢面板    %s   %s' "$(date '+%m-%d %H:%M')" "$host")"

    [ -t 1 ] && clear 2>/dev/null || true
    printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "${C_BOLD}${C_BLUE}" "$C_RESET"
    printf '%s║%s║%s\n' "${C_BOLD}${C_BLUE}" "$(pad_to "$hdr" 62)" "$C_RESET"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "${C_BOLD}${C_BLUE}" "$C_RESET"

    printf '\n %s加固評分%s  %s%s%s  %s%3s/100%s  %s%s\n' \
        "$C_BOLD" "$C_RESET" "$col" "$(score_bar "$pct")" "$C_RESET" \
        "$col" "$pct" "$C_RESET" "$grade" "$delta"

    divider
    kv "防火牆" "$(if [ "$fwstate" = "active" ]; then printf '%s%s 生效中%s' "$C_GREEN" "$fwtype" "$C_RESET"; else printf '%s%s %s%s' "$C_RED" "$fwtype" "$fwstate" "$C_RESET"; fi)"
    kv "入侵防禦" "$(if [ "$engine" = "none" ]; then printf '%s未安裝%s' "$C_RED" "$C_RESET"; else printf '%s · %s 條封禁' "$engine" "$bans"; fi)"
    kv "24h 失敗登入" "$(if [ "$failed" -gt 1000 ]; then printf '%s%s%s（正被持續掃描）' "$C_YELLOW" "$failed" "$C_RESET"; else printf '%s' "$failed"; fi)"
    if [ "$hptotal" -gt 0 ]; then
        kv "蜜罐命中" "$(printf '%s%s%s  %s%s%s' "$C_YELLOW" "$hptotal" "$C_RESET" "$C_DIM" "$hpdetail" "$C_RESET")"
    else
        kv "蜜罐命中" "0"
    fi
    [ -n "$top" ] && kv "Top 攻擊源" "$top"
    if [ -n "$eshn" ] && [ "$eshn" != "0" ]; then
        kv "endlessh" "$(printf '已困住 %s 個掃描器 · 累計浪費 %s 小時' "$eshn" "$eshh")"
    fi
    divider
    kv "當前會話" "${sess:-—}"
    kv "監聽埠" "${listen:-—}"
    kv "安全更新" "$(if [ -z "$secn" ]; then printf '—'; elif [ "$secn" -eq 0 ]; then printf '%s已最新%s' "$C_GREEN" "$C_RESET"; else printf '%s%s 個待裝%s' "$C_YELLOW" "$secn" "$C_RESET"; fi)"
    kv "重啟需求" "$rb"
    kv "負載 / 磁碟" "${load:-—}   ${disk:-—}"
    divider
}

module_panel() {
    render_panel
    printf '\n %s[r]%s 重新整理   %s[w]%s 每 10 秒自動刷新   %s[a]%s 完整評分明細   %s[Enter]%s 返回\n' \
        "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf ' 請選擇: '
    local c
    read -r c || c=""
    case "$c" in
        r|R) module_panel ;;
        w|W)
            info "自動刷新中，按 Ctrl-C 退出…"
            sleep 1
            while true; do
                render_panel
                printf '\n %s每 10 秒刷新 · Ctrl-C 退出%s\n' "$C_DIM" "$C_RESET"
                sleep 10
            done
            ;;
        a|A) module_audit ;;
        *)   return 0 ;;
    esac
}

#=======================================================================
# 模塊 3 · Lynis 深度審計（第三方獨立評分）
#=======================================================================
module_lynis() {
    section "Lynis 深度審計"
    info "Lynis 是業界通用的開源審計工具，給出獨立的 hardening index。"
    info "它只讀不寫，跑完約 1-3 分鐘。"

    if ! command -v lynis >/dev/null 2>&1; then
        warn "未安裝 lynis。"
        confirm "從系統源安裝 lynis？" || return 0
        pkg_install lynis || { err "安裝失敗（部分發行版需要 EPEL）"; return 1; }
    fi

    printf '\n'
    lynis audit system --quick --no-colors 2>/dev/null | tail -40 || true
    printf '\n'
    ok "完整報告：/var/log/lynis.log · 建議清單：/var/log/lynis-report.dat"
}

#=======================================================================
# 變更清單（manifest）
#   每個加固動作記錄「做了什麼 / 怎麼撤銷」，讓所有操作可逆。
#   格式：時間戳 \t 項目ID \t 描述 \t 撤銷命令
#=======================================================================
MANIFEST="${BLUE_LIB}/manifest.tsv"

manifest_add() {
    local id="$1" desc="$2" undo="$3"
    ensure_dirs
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$id" "$desc" "$undo" >> "$MANIFEST"
}

manifest_has() {
    [ -f "$MANIFEST" ] && grep -q "	$1	" "$MANIFEST" 2>/dev/null
}

#=======================================================================
# 備份與自動還原（防鎖門機制的核心）
#=======================================================================
BLUE_PENDING="${BLUE_LIB}/pending"
BLUE_RESTORE_BIN="/usr/local/sbin/oece-blue-restore"
ROLLBACK_UNIT="oece-blue-rollback"

# 回滾路徑必須是備份根下的真實目錄，名稱為 20YYMMDD-HHMMSS。
# -d 會跟隨符號連結，攻擊者可把符合名稱的連結指到任意目錄。
# 這裡先拒絕連結，再用實體路徑確認沒有逃出 BLUE_BACKUP。
rollback_path_ok() {
    local bk="$1" real root
    case "$bk" in
        "${BLUE_BACKUP}"/20[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) return 1 ;;
    esac
    [ -d "$bk" ] || return 1
    [ -L "$bk" ] && return 1
    root="$(readlink -f "$BLUE_BACKUP" 2>/dev/null || printf '%s' "$BLUE_BACKUP")"
    real="$(readlink -f "$bk" 2>/dev/null || true)"
    [ -n "$real" ] || return 1
    case "$real" in
        "$root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# 建立一份完整回滾點，回傳備份目錄路徑
backup_create() {
    local bk
    bk="${BLUE_BACKUP}/$(date +%Y%m%d-%H%M%S)"
    # -p 對已存在的符號連結會在目標裡建目錄，路徑檢查會被繞過。
    if [ -e "$bk" ] || [ -L "$bk" ]; then
        err "回滾點路徑已存在，拒絕覆寫：${bk}"
        return 1
    fi
    mkdir "$bk" || return 1

    [ -f /etc/ssh/sshd_config ] && cp -a /etc/ssh/sshd_config "$bk/sshd_config"
    [ -d /etc/ssh/sshd_config.d ] && cp -a /etc/ssh/sshd_config.d "$bk/sshd_config.d"

    # 關鍵：即使 ufw / fail2ban 尚未安裝也要記錄狀態。
    # 否則加固過程「新裝並啟用」的元件，在還原時會因為備份裡沒有對應
    # 檔案而被整段跳過 —— 結果 default deny 的防火牆在還原後仍然生效。
    if command -v ufw >/dev/null 2>&1; then
        ufw status 2>/dev/null | head -1 > "$bk/ufw.state" || true
        ufw status numbered > "$bk/ufw.numbered" 2>/dev/null || true
        if [ -d /etc/ufw ]; then
            cp -a /etc/ufw "$bk/ufw.d" 2>/dev/null || true
        fi
    else
        printf 'Status: absent\n' > "$bk/ufw.state"
    fi

    if systemctl is-active fail2ban >/dev/null 2>&1; then
        printf 'active\n' > "$bk/fail2ban.state"
    else
        printf 'inactive\n' > "$bk/fail2ban.state"
    fi

    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$bk/iptables.rules" 2>/dev/null || true
    fi
    if [ -d /etc/systemd/system/ssh.socket.d ]; then
        cp -a /etc/systemd/system/ssh.socket.d "$bk/ssh.socket.d" 2>/dev/null || true
    fi
    cp -a /etc/passwd "$bk/passwd" 2>/dev/null || true

    printf '%s' "$bk"
}

# 寫出獨立的還原腳本。刻意做成自包含檔案：
# 即使主腳本已離開系統，定時器仍能完成還原。
write_restore_script() {
    cat > "$BLUE_RESTORE_BIN" <<'RESTORE_EOF'
#!/usr/bin/env bash
# oece-x-blue 自動還原腳本（由 arm_rollback 排定，勿手動刪除）
mkdir -p /var/log/oece-x
BK="$(cat /var/lib/oece-x/pending 2>/dev/null || true)"
[ -n "$BK" ] || exit 0
# pending 是本工具自己寫的。還原時仍拒絕名稱不符、符號連結，以及實體路徑逃出備份根。
# 拒絕原因寫進 rollback.log，定時器沒有終端時仍看得到。
{
case "$BK" in
    /var/backups/oece-x/20[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) echo "拒絕非本工具建立的回滾路徑"; exit 1 ;;
esac
[ -d "$BK" ] || exit 0
[ -L "$BK" ] && { echo "拒絕符號連結回滾路徑"; exit 1; }
_bk_real="$(readlink -f "$BK" 2>/dev/null || true)"
_bk_root="$(readlink -f /var/backups/oece-x 2>/dev/null || printf '%s' /var/backups/oece-x)"
case "$_bk_real" in
    "$_bk_root"/*) ;;
    *) echo "回滾路徑逃出備份根，已中止"; exit 1 ;;
esac
} >> /var/log/oece-x/rollback.log 2>&1
{
    echo "=== $(date -Is) 未在時限內確認，自動還原觸發 ==="
    if [ -d "$BK/sshd_config.d" ]; then
        rm -f /etc/ssh/sshd_config.d/99-oece-blue.conf
        cp -a "$BK/sshd_config.d/." /etc/ssh/sshd_config.d/ 2>/dev/null
    else
        rm -f /etc/ssh/sshd_config.d/99-oece-blue.conf
        echo "已移除本次加固寫入的 sshd drop-in"
    fi
    [ -f "$BK/sshd_config" ] && cp -a "$BK/sshd_config" /etc/ssh/sshd_config
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || \
        service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || true
        echo "sshd 設定已還原並 reload"
    else
        echo "警告：還原後 sshd -t 仍失敗，未 reload"
    fi
    if command -v ufw >/dev/null 2>&1; then
        [ -d "$BK/ufw.d" ] && cp -a "$BK/ufw.d/." /etc/ufw/ 2>/dev/null
        # absent = 加固前根本沒裝 ufw，是本次加固新裝的 → 必須停用，
        # 否則 default deny 的防火牆會在還原後繼續擋人。
        if grep -qiE 'inactive|absent' "$BK/ufw.state" 2>/dev/null; then
            ufw --force disable >/dev/null 2>&1 || true
            echo "ufw 已停用（還原到加固前狀態）"
        else
            ufw --force enable >/dev/null 2>&1 || true
            echo "ufw 規則已還原"
        fi
    fi
    if grep -qi inactive "$BK/fail2ban.state" 2>/dev/null; then
        if systemctl is-active fail2ban >/dev/null 2>&1; then
            rm -f /etc/fail2ban/jail.d/oece-blue.local
            systemctl stop fail2ban >/dev/null 2>&1 || true
            systemctl disable fail2ban >/dev/null 2>&1 || true
            echo "fail2ban 已停用（還原到加固前狀態）"
        fi
    fi
    if [ -f "$BK/ssh.socket.d/99-oece-blue.conf" ] || [ -d "$BK/ssh.socket.d" ]; then
        rm -f /etc/systemd/system/ssh.socket.d/99-oece-blue.conf
        if [ -d "$BK/ssh.socket.d" ]; then
            mkdir -p /etc/systemd/system/ssh.socket.d
            cp -a "$BK/ssh.socket.d/." /etc/systemd/system/ssh.socket.d/ 2>/dev/null || true
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart ssh.socket >/dev/null 2>&1 || true
        echo "ssh.socket drop-in 已還原"
    elif [ -f /etc/systemd/system/ssh.socket.d/99-oece-blue.conf ]; then
        rm -f /etc/systemd/system/ssh.socket.d/99-oece-blue.conf
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart ssh.socket >/dev/null 2>&1 || true
        echo "已移除本次加固寫入的 ssh.socket drop-in"
    fi
    # 裸 iptables 機器沒有 ufw 可還原。快照存在且 iptables-restore 可用才套用。
    # 套用失敗只記日誌，不中斷其餘還原。
    if [ -f "$BK/iptables.rules" ] && [ ! -L "$BK/iptables.rules" ] \
       && [ -s "$BK/iptables.rules" ] && command -v iptables-restore >/dev/null 2>&1; then
        if iptables-restore < "$BK/iptables.rules" 2>/dev/null; then
            echo "iptables 規則已從快照還原"
        else
            echo "警告：iptables-restore 失敗，未套用快照（其餘還原已完成）"
        fi
    fi
    echo "=== 還原完成 ==="
} >> /var/log/oece-x/rollback.log 2>&1
rm -f /var/lib/oece-x/pending
RESTORE_EOF
    chmod 700 "$BLUE_RESTORE_BIN"
}

# $0 在 bash <(curl) / curl | bash 下不是磁碟檔。回滾不能指回它。
is_ephemeral_script_path() {
    local p="${1:-$0}"
    case "$p" in
        bash|-bash|sh|-sh|/dev/fd/*|/dev/stdin|/proc/self/fd/*|/proc/*/fd/*) return 0 ;;
    esac
    [ -f "$p" ] || return 0
    case "$p" in
        /*|./*|../*) return 1 ;;
        *) return 0 ;;
    esac
}

persist_running_script() {
    local src="${1:-$0}" dest="$BLUE_INSTALL" body
    if ! is_ephemeral_script_path "$src"; then
        printf '%s' "$src"
        return 0
    fi
    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        err "目前是管道執行，回滾找不到腳本檔。請先存到磁碟再跑選單 5 以後的項目。"
        err "curl -fsSL ${SCRIPT_RAW_URL} -o oece-x-blue.sh && sudo bash oece-x-blue.sh"
        return 1
    fi
    mkdir -p /usr/local/sbin 2>/dev/null || {
        err "無法建立 /usr/local/sbin，已拒絕掛回滾。"
        return 1
    }
    if [ -f "$src" ]; then
        cp -f "$src" "$dest" || return 1
    else
        body="$(cat 2>/dev/null || true)"
        if [ -z "$body" ]; then
            err "讀不到正在執行的腳本內容，已拒絕掛回滾。"
            return 1
        fi
        printf '%s\n' "$body" > "$dest" || return 1
    fi
    chmod 755 "$dest" || return 1
    ok "已落盤：${dest}。回滾將指向這個檔，不指向管道。"
    printf '%s' "$dest"
}

require_durable_script() {
    is_ephemeral_script_path || return 0
    persist_running_script >/dev/null
}

# 排定 N 分鐘後自動還原。三級降級：systemd-run → at → nohup
arm_rollback() {
    local minutes="$1" bk="$2"
    if ! valid_rollback_minutes "$minutes"; then
        err "回滾窗口無效：${minutes}（須為 1–120 的整數）"
        return 1
    fi
    # 名稱符合之外，還必須是真實目錄，且不得經由符號連結逃出備份根。
    if ! rollback_path_ok "$bk"; then
        err "拒絕非本工具建立的回滾路徑。"
        return 1
    fi
    ensure_dirs
    printf '%s' "$bk" > "$BLUE_PENDING"
    write_restore_script

    if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
        if systemd-run --unit="$ROLLBACK_UNIT" --on-active="${minutes}min" \
             "$BLUE_RESTORE_BIN" >/dev/null 2>&1; then
            printf 'systemd' > "${BLUE_LIB}/rollback.method"
            return 0
        fi
    fi
    if command -v at >/dev/null 2>&1; then
        local at_out at_id
        at_out="$(printf '%s\n' "$BLUE_RESTORE_BIN" | at now + "$minutes" minutes 2>&1)" || at_out=""
        # at 把工作編號印在 stderr，例如 "job 17 at ..."
        at_id="$(printf '%s\n' "$at_out" | sed -n 's/.*[Jj]ob \([0-9][0-9]*\).*/\1/p' | head -1)"
        if [ -n "$at_id" ]; then
            printf '%s' "$at_id" > "${BLUE_LIB}/rollback.at"
            printf 'at' > "${BLUE_LIB}/rollback.method"
            return 0
        fi
    fi
    # 最後手段：背景進程。機器重啟會失效，故明確告知使用者。
    # 用引號陣列傳參，不把路徑拼進 bash -c 字串。
    # 單引號是故意的：參數由後面的位置參數傳入，不在字串裡展開。
    # shellcheck disable=SC2016
    nohup bash -c 'sleep "$1"; "$2"' _ "$(( minutes * 60 ))" "$BLUE_RESTORE_BIN" >/dev/null 2>&1 &
    printf '%s' "$!" > "${BLUE_LIB}/rollback.pid"
    printf 'nohup' > "${BLUE_LIB}/rollback.method"
    warn "systemd/at 均不可用，改用背景進程計時（重啟後失效）。"
    return 0
}

rollback_pending() {
    [ -f "$BLUE_PENDING" ]
}

# 取消定時器 = 確認加固結果保留
blue_confirm() {
    if ! rollback_pending; then
        info "目前沒有等待確認的加固操作。"
        return 0
    fi
    local method
    method="$(cat "${BLUE_LIB}/rollback.method" 2>/dev/null || true)"
    local pid at_id
    case "$method" in
        systemd)
            systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
            ;;
        at)
            # 只取消自己排的那一筆。沒有記錄到編號時不 atrm，避免清掉使用者其他 at 工作。
            at_id="$(cat "${BLUE_LIB}/rollback.at" 2>/dev/null || true)"
            case "$at_id" in
                ''|*[!0-9]*)
                    warn "找不到本工具的 at 工作編號，未取消任何 at 工作。請手動 atq 核對。"
                    ;;
                *)
                    atrm "$at_id" 2>/dev/null || true
                    ;;
            esac
            ;;
        nohup)
            pid="$(cat "${BLUE_LIB}/rollback.pid" 2>/dev/null || true)"
            case "$pid" in
                ''|*[!0-9]*) ;;
                *) kill "$pid" 2>/dev/null || true ;;
            esac
            ;;
    esac
    rm -f "$BLUE_PENDING" "${BLUE_LIB}/rollback.pid" "${BLUE_LIB}/rollback.method" "${BLUE_LIB}/rollback.at"
    ok "已確認保留加固結果，自動還原定時器已取消。"
    info "回滾點仍保留在 ${BLUE_BACKUP}/，日後可用「選單 20 · 回滾與還原」撤銷。"
}

# 立即還原（不等定時器）
blue_rollback_now() {
    local bk="${1:-}"
    if [ -z "$bk" ]; then
        bk="$(find "$BLUE_BACKUP" -maxdepth 1 -type d -name '20*' 2>/dev/null | sort | tail -1 || true)"
    fi
    if ! rollback_path_ok "$bk"; then
        err "拒絕非本工具建立的回滾路徑。"
        return 1
    fi
    printf '%s' "$bk" > "$BLUE_PENDING"
    write_restore_script
    "$BLUE_RESTORE_BIN"
    ok "已從 ${bk} 還原。"
    tail -12 "${BLUE_LOG}/rollback.log" 2>/dev/null || true
}

#=======================================================================
# sshd 設定寫入
#=======================================================================
# drop-in 只有在主設定檔含 Include 時才生效，否則寫了等於沒寫
ensure_sshd_include() {
    local conf="/etc/ssh/sshd_config"
    [ -f "$conf" ] || return 1
    mkdir -p /etc/ssh/sshd_config.d
    if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$conf"; then
        return 0
    fi
    warn "sshd_config 缺少 Include 指令，drop-in 不會生效 —— 正在補上。"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n%s\n' "$(cat "$conf")" > "${conf}.oece-tmp"
    mv "${conf}.oece-tmp" "$conf"
    ok "已在 sshd_config 頂部加入 Include 指令"
}

sshd_set() {
    local key="$1" val="$2" tmp
    # 鍵名只允許 OpenSSH 關鍵字字元，避免寫進 drop-in 的行被當成指令。
    case "$key" in
        ''|*[!A-Za-z0-9]*) err "拒絕非法 sshd 鍵名。"; return 1 ;;
    esac
    case "$val" in
        *$'\n'*|*$'\r'*) err "拒絕含換行的 sshd 值。"; return 1 ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        info "$(printf "$(t dryrun)" "sshd_set ${key} ${val}")"
        return 0
    fi
    mkdir -p /etc/ssh/sshd_config.d
    tmp="${BLUE_SSHD_DROPIN}.tmp"
    if [ -f "$BLUE_SSHD_DROPIN" ]; then
        grep -vE "^${key}[[:space:]]" "$BLUE_SSHD_DROPIN" > "$tmp" || true
    else
        printf '# managed by oece-x-blue.sh — 由腳本管理，可整檔刪除以還原\n' > "$tmp"
    fi
    printf '%s %s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$BLUE_SSHD_DROPIN"
    chmod 644 "$BLUE_SSHD_DROPIN"
}

sshd_validate_reload() {
    if ! sshd -t 2>/dev/null; then
        err "sshd -t 校驗失敗，拒絕 reload。設定未生效，系統仍為原狀。"
        sshd -t 2>&1 | head -5 || true
        return 1
    fi
    if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null \
       || service ssh reload 2>/dev/null || service sshd reload 2>/dev/null; then
        ok "sshd 已重新載入設定"
        return 0
    fi
    warn "無法自動 reload sshd，請手動執行 systemctl reload sshd"
    return 0
}

#=======================================================================
# 動手前的守門員
#   任何會改 sshd / 防火牆 / 帳戶的操作都必須先過這一關。
#=======================================================================
harden_preflight() {
    local target_user="${1:-}"
    section "加固前置檢查（preflight）"

    # 1. 當前會話來源
    local src_ip="" cur_user
    if [ -n "${SSH_CONNECTION:-}" ]; then
        src_ip="$(printf '%s' "$SSH_CONNECTION" | awk '{print $1}')"
        if ! is_ip "$src_ip"; then
            src_ip=""
        fi
        kv "當前會話" "來自 ${src_ip:-未知位址}（SSH）"
    else
        kv "當前會話" "本機/主控台（非 SSH）"
    fi
    cur_user="$(id -un 2>/dev/null || echo root)"
    [ -z "$target_user" ] && target_user="$cur_user"
    kv "加固後保留帳戶" "$target_user"

    # 2. 公鑰驗證 —— 這是最關鍵的一步
    local home keyfile nkeys=0
    home="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6 || true)"
    [ -z "$home" ] && home="/root"
    keyfile="${home}/.ssh/authorized_keys"
    nkeys="$(count_valid_keys "$keyfile")"

    if [ "$nkeys" -gt 0 ]; then
        kv "可用公鑰" "${nkeys} 把（${keyfile}）"
        printf '%s' "$C_DIM"
        ssh-keygen -l -f "$keyfile" 2>/dev/null | head -5 | sed 's/^/       /' || true
        printf '%s' "$C_RESET"
    else
        printf '\n'
        err "帳戶 ${target_user} 沒有任何有效公鑰（${keyfile}）。"
        err "現在禁用密碼登入，你將立刻被永久鎖在門外。"
        printf '\n'
        info "請先在本機執行，再回來加固："
        printf '   %sssh-copy-id %s@%s%s\n\n' "$C_GREEN" "$target_user" "${src_ip:-<伺服器IP>}" "$C_RESET"
        return 1
    fi

    # 3. sshd 必須啟用公鑰認證
    local pk
    pk="$(sshd_val pubkeyauthentication)"
    if [ "$pk" = "no" ]; then
        err "sshd 目前 PubkeyAuthentication=no，禁用密碼後將無任何可用登入方式。"
        return 1
    fi
    kv "公鑰認證" "${pk:-yes}"

    # 4. 救援通道確認
    printf '\n'
    warn "改 SSH / 防火牆前，請確認你有雲商的 VNC / 序列埠控制台可用。"
    warn "確認雲商控制台的 VNC / 序列埠救援入口可用。"
    if ! confirm "你已確認救援控制台可用（或願意承擔風險）？"; then
        info "已取消。建議先找到控制台入口再回來。"
        return 1
    fi
    ok "前置檢查通過"
    return 0
}

# 套用變更後的統一收尾：提示使用者驗證並確認
post_harden_notice() {
    local minutes="$1" port="${2:-}" user="${3:-}"
    printf '\n'
    printf '%s%s╔══════════════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%s%s║  ⚠  現在請「另開一個終端」測試登入，不要關掉這個視窗！       ║%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%s%s╚══════════════════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '\n'
    local hint="ssh"
    [ -n "$user" ] && hint="${hint} ${user}@<伺服器IP>" || hint="${hint} <你的帳戶>@<伺服器IP>"
    [ -n "$port" ] && hint="${hint} -p ${port}"
    printf '  1) 新終端執行： %s%s%s\n' "$C_GREEN" "$hint" "$C_RESET"
    printf '  2) 登入成功後執行： %sbash %s --confirm%s\n' "$C_GREEN" "$0" "$C_RESET"
    printf '\n'
    printf '  %s若 %s 分鐘內未確認，系統將自動還原到加固前的狀態。%s\n' "$C_YELLOW" "$minutes" "$C_RESET"
    printf '  %s回滾點：%s%s\n' "$C_DIM" "$(cat "$BLUE_PENDING" 2>/dev/null || echo '-')" "$C_RESET"
    printf '\n'
}

#=======================================================================
# 模塊 4 · 一鍵加固 · 基礎（零鎖門風險）
#=======================================================================
apply_sysctl_hardening() {
    local f="/etc/sysctl.d/99-oece-blue.conf" line
    {
        printf '# managed by oece-x-blue.sh — 刪除本檔並 sysctl --system 即可還原\n'
        while IFS= read -r line; do
            [ -n "$line" ] && printf '%s\n' "${line/=/ = }"
        done <<< "$SYSCTL_NET_EXPECT"
        while IFS= read -r line; do
            [ -n "$line" ] && printf '%s\n' "${line/=/ = }"
        done <<< "$SYSCTL_KERN_EXPECT"
    } > "$f"
    sysctl --system >/dev/null 2>&1 || sysctl -p "$f" >/dev/null 2>&1 || true
    manifest_add "sysctl" "內核參數加固（13 項）" "rm -f ${f} && sysctl --system"
    ok "sysctl 加固已套用（${f}）"
}

apply_auto_updates() {
    if [ "$PKG_MGR" = "apt" ]; then
        pkg_install unattended-upgrades apt-listchanges || { warn "安裝 unattended-upgrades 失敗"; return 1; }
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
        systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
        manifest_add "autoupdate" "啟用 unattended-upgrades 自動安全更新" \
            "systemctl disable --now unattended-upgrades; rm -f /etc/apt/apt.conf.d/20auto-upgrades"
    else
        pkg_install dnf-automatic || { warn "安裝 dnf-automatic 失敗"; return 1; }
        sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null || true
        sed -i 's/^upgrade_type.*/upgrade_type = security/' /etc/dnf/automatic.conf 2>/dev/null || true
        systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 || true
        manifest_add "autoupdate" "啟用 dnf-automatic 自動安全更新" \
            "systemctl disable --now dnf-automatic.timer"
    fi
    ok "自動安全更新已啟用"
}

apply_shm_hardening() {
    if grep -qE '^\S+\s+/dev/shm\s' /etc/fstab 2>/dev/null; then
        info "/etc/fstab 已有 /dev/shm 項目，跳過以免覆蓋你的設定。"
        return 0
    fi
    printf 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0\n' >> /etc/fstab
    mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null || true
    manifest_add "shm" "/dev/shm 加上 noexec,nosuid,nodev" \
        "sed -i '\\|^tmpfs /dev/shm|d' /etc/fstab && mount -o remount,exec /dev/shm"
    ok "/dev/shm 已加固"
}

apply_coredump_off() {
    printf '* hard core 0\n' > /etc/security/limits.d/99-oece-blue.conf
    mkdir -p /etc/systemd/coredump.conf.d
    printf '[Coredump]\nStorage=none\n' > /etc/systemd/coredump.conf.d/99-oece-blue.conf
    manifest_add "coredump" "停用 core dump（避免記憶體內憑證落盤）" \
        "rm -f /etc/security/limits.d/99-oece-blue.conf /etc/systemd/coredump.conf.d/99-oece-blue.conf"
    ok "core dump 已停用"
}

module_harden_basic() {
    section "一鍵加固 · 基礎"
    info "本檔位只做「不可能把你鎖在門外」的加固："
    printf '   • 啟用自動安全更新\n'
    printf '   • 內核參數加固（13 項 sysctl）\n'
    printf '   • /dev/shm 加 noexec,nosuid,nodev\n'
    printf '   • 停用 core dump\n'
    printf '\n'
    warn "唯一需注意：rp_filter=1（嚴格反向路徑過濾）在非對稱路由環境下可能影響流量。"
    warn "一般 VPS 不受影響；若你跑 VPN 閘道 / 多網卡路由，請改用逐項加固。"
    printf '\n'
    confirm "開始套用基礎加固？" || return 0

    apply_auto_updates    || true
    apply_sysctl_hardening
    apply_shm_hardening
    apply_coredump_off

    printf '\n'
    ok "基礎加固完成。全部變更已記入 manifest，可用「選單 20」撤銷。"
    info "建議重跑「選單 2 · 加固評分體檢」看分數變化。"
}

#=======================================================================
# 模塊 5 · 一鍵加固 · 標準（動 SSH，掛自動回滾）
#=======================================================================
# 自動還原窗口（分鐘）。可用 OECE_ROLLBACK_MIN 覆蓋，方便測試與慢速網路環境。
# 只接受 1–120 的整數；非法值退回 10，避免被拼進 systemd-run / sleep。
ROLLBACK_MINUTES="${OECE_ROLLBACK_MIN:-10}"
if ! valid_rollback_minutes "$ROLLBACK_MINUTES"; then
    warn "OECE_ROLLBACK_MIN 無效（須為 1–120 的整數），改用 10。"
    ROLLBACK_MINUTES=10
fi

module_harden_standard() {
    section "一鍵加固 · 標準"
    info "本檔位會修改 SSH 與防火牆設定，全程掛自動回滾定時器。"
    printf '\n'
    printf ' 將套用：\n'
    printf '   • SSH：禁用密碼登入、root 僅金鑰、MaxAuthTries 3、LoginGraceTime 20\n'
    printf '   • SSH：關閉 X11 轉發 / Agent 轉發，設定閒置斷線\n'
    printf '   • 防火牆：UFW default deny incoming，放行 SSH + 80/443\n'
    printf '   • 入侵防禦：安裝並啟用 fail2ban（sshd jail）\n'
    printf '\n'

    local target_user
    printf '加固後要保留的登入帳戶 [預設 %s]: ' "$(id -un)"
    read -r target_user || target_user=""
    [ -z "$target_user" ] && target_user="$(id -un)"

    # 必須按「名稱」比對：getent passwd 0 會匹配到 uid 0（root），
    # 使用者打錯字時會被靜默解析成另一個帳戶。
    if ! awk -F: -v u="$target_user" '$1==u{found=1} END{exit !found}' /etc/passwd; then
        err "帳戶 ${target_user} 不存在（請輸入用戶名，不是 uid）。"
        return 1
    fi

    harden_preflight "$target_user" || return 1

    local cur_port
    cur_port="$(sshd_val port)"
    [ -z "$cur_port" ] && cur_port=22

    printf '\n'
    confirm_danger "確認套用標準加固？（${ROLLBACK_MINUTES} 分鐘內未確認將自動還原）" || return 0

    # ---- 建立回滾點並武裝定時器（先武裝，再動手）----
    local bk
    bk="$(backup_create)"
    info "回滾點已建立：${bk}"
    arm_rollback "$ROLLBACK_MINUTES" "$bk" || return 1
    ok "自動還原定時器已武裝（${ROLLBACK_MINUTES} 分鐘）"

    # ---- SSH ----
    ensure_sshd_include || true
    sshd_set PasswordAuthentication no
    sshd_set KbdInteractiveAuthentication no
    sshd_set PermitRootLogin prohibit-password
    sshd_set PermitEmptyPasswords no
    sshd_set MaxAuthTries 3
    sshd_set LoginGraceTime 20
    sshd_set X11Forwarding no
    sshd_set AllowAgentForwarding no
    sshd_set ClientAliveInterval 300
    sshd_set ClientAliveCountMax 2

    if ! sshd_validate_reload; then
        err "sshd 設定有問題，立即還原。"
        blue_rollback_now "$bk"
        return 1
    fi
    manifest_add "sshd" "SSH 收緊（禁密碼/root 僅金鑰/MaxAuthTries 3 等）" \
        "rm -f ${BLUE_SSHD_DROPIN} && systemctl reload sshd"

    # ---- 防火牆 ----
    if ! command -v ufw >/dev/null 2>&1; then
        pkg_install ufw || warn "ufw 安裝失敗，跳過防火牆步驟"
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming  >/dev/null 2>&1 || true
        ufw default allow outgoing >/dev/null 2>&1 || true
        ufw allow "${cur_port}/tcp" comment 'SSH (oece-blue)' >/dev/null 2>&1 || true
        ufw allow 80/tcp  >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw --force enable >/dev/null 2>&1 || true
        ok "UFW 已啟用（放行 ${cur_port}/tcp、80、443）"
        manifest_add "ufw" "UFW default deny + 放行 SSH/80/443" "ufw --force disable"
        if command -v docker >/dev/null 2>&1; then
            warn "偵測到 Docker：容器發布的埠會繞過 UFW。修復請走「選單 12 · 防火牆」。"
        fi
    fi

    # ---- 入侵防禦 ----
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        pkg_install fail2ban || warn "fail2ban 安裝失敗"
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        mkdir -p /etc/fail2ban/jail.d
        cat > /etc/fail2ban/jail.d/oece-blue.local <<EOF
[sshd]
enabled  = true
port     = ${cur_port}
maxretry = 4
findtime = 10m
bantime  = 1h
EOF
        # RHEL 系日誌走 /var/log/secure；Debian 13 起預設只有 journald
        if [ -f /var/log/secure ]; then
            printf 'backend = auto\nlogpath = /var/log/secure\n' >> /etc/fail2ban/jail.d/oece-blue.local
        elif [ -f /var/log/auth.log ]; then
            printf 'backend = auto\nlogpath = /var/log/auth.log\n' >> /etc/fail2ban/jail.d/oece-blue.local
        else
            printf 'backend = systemd\n' >> /etc/fail2ban/jail.d/oece-blue.local
        fi
        systemctl enable --now fail2ban >/dev/null 2>&1 || true
        systemctl restart fail2ban >/dev/null 2>&1 || true
        if systemctl is-active fail2ban >/dev/null 2>&1; then
            ok "fail2ban 已啟用（sshd jail，4 次失敗封 1 小時）"
            manifest_add "fail2ban" "fail2ban sshd jail" \
                "rm -f /etc/fail2ban/jail.d/oece-blue.local && systemctl restart fail2ban"
        else
            warn "fail2ban 未能啟動，請稍後檢查 journalctl -u fail2ban"
        fi
    fi

    post_harden_notice "$ROLLBACK_MINUTES" "$cur_port" "$target_user"
}

#=======================================================================
# 模塊 20 · 回滾與還原
#=======================================================================
module_rollback() {
    section "回滾與還原"

    if rollback_pending; then
        warn "偵測到「等待確認」的加固操作，回滾點：$(cat "$BLUE_PENDING")"
        printf '   若你能正常登入，請選 1 確認保留；否則等定時器自動還原。\n\n'
    fi

    printf ' 1) 確認保留加固結果（取消自動還原定時器）\n'
    printf ' 2) 立即還原到最近一次回滾點\n'
    printf ' 3) 查看變更清單（manifest）\n'
    printf ' 4) 查看還原日誌\n'
    printf ' 0) 返回\n\n請選擇: '
    local c
    read -r c || c="0"
    case "$c" in
        1) blue_confirm ;;
        2)
            local bk
            bk="$(find "$BLUE_BACKUP" -maxdepth 1 -type d -name '20*' 2>/dev/null | sort | tail -1 || true)"
            [ -z "$bk" ] && { err "找不到回滾點。"; return 1; }
            confirm_danger "將把 SSH 與防火牆設定還原到 ${bk}" || return 0
            blue_rollback_now "$bk"
            ;;
        3)
            if [ -f "$MANIFEST" ]; then
                printf '\n%s%-22s %-34s %s%s\n' "$C_BOLD" "時間" "項目" "撤銷命令" "$C_RESET"
                divider
                awk -F'\t' '{printf " %-22s %-34s %s\n", $1, $3, $4}' "$MANIFEST"
            else
                info "尚無任何變更記錄。"
            fi
            ;;
        4) tail -40 "${BLUE_LOG}/rollback.log" 2>/dev/null || info "尚無還原日誌。" ;;
        *) return 0 ;;
    esac
}

#=======================================================================
# 模塊 8 · CrowdSec（社群威脅情報 IPS）
#=======================================================================
install_crowdsec_repo() {
    info "不執行遠端安裝腳本。改用官方 packagecloud 倉庫（HTTPS + signed-by）。"
    case "$PKG_MGR" in
        apt)
            pkg_install ca-certificates curl gnupg || return 1
            mkdir -p /etc/apt/keyrings
            if ! curl "${CURL_OPTS[@]}" https://packagecloud.io/crowdsec/crowdsec/gpgkey \
                | gpg --dearmor -o /etc/apt/keyrings/crowdsec-archive-keyring.gpg; then
                err "CrowdSec 金鑰下載失敗。"
                return 1
            fi
            chmod 644 /etc/apt/keyrings/crowdsec-archive-keyring.gpg
            cat > /etc/apt/sources.list.d/crowdsec.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any any main
EOF
            APT_UPDATED=0
            pkg_install crowdsec || return 1
            ;;
        dnf|yum)
            cat > /etc/yum.repos.d/crowdsec.repo <<'EOF'
[crowdsec]
name=CrowdSec
baseurl=https://packagecloud.io/crowdsec/crowdsec/rpm_any/rpm_any/$basearch
gpgcheck=1
gpgkey=https://packagecloud.io/crowdsec/crowdsec/gpgkey
repo_gpgcheck=1
EOF
            pkg_install crowdsec || return 1
            ;;
        *) err "此發行版沒有受支援的 CrowdSec 倉庫路徑。"; return 1 ;;
    esac
    if [ -f /etc/crowdsec/online_api_credentials.yaml ]; then
        mv /etc/crowdsec/online_api_credentials.yaml \
           /etc/crowdsec/online_api_credentials.yaml.disabled-by-oece 2>/dev/null || true
    fi
    return 0
}

module_crowdsec() {
    section "CrowdSec · 社群威脅情報 IPS"
    info "CrowdSec 用行為場景（scenario）偵測攻擊，並以 nftables/ipset 執行封禁。"
    info "相較 fail2ban，它扛得住百萬級 IP 名單，且可取得全球共享黑名單。"

    local memkb memmb
    memkb="$(awk '/MemTotal/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
    memmb=$(( memkb / 1024 ))
    kv "本機記憶體" "${memmb} MB"
    if [ "$memmb" -lt 512 ]; then
        warn "記憶體低於 512MB，CrowdSec（約 50-150MB）可能吃緊，建議改用選單 9 · fail2ban。"
        confirm "仍要繼續安裝 CrowdSec？" || return 0
    fi

    if command -v cscli >/dev/null 2>&1; then
        ok "CrowdSec 已安裝"
    else
        printf '\n'
        info "安裝來源：packagecloud.io/crowdsec（HTTPS，signed-by，不執行遠端腳本）。"
        confirm_danger "加入 CrowdSec 官方倉庫並安裝套件？" || return 0
        install_crowdsec_repo || { err "CrowdSec 安裝失敗"; return 1; }
        manifest_add "crowdsec" "安裝 CrowdSec（社群情報共享預設關閉）" "systemctl disable --now crowdsec"
    fi

    # ---- 隱私：社群情報共享 ----
    printf '\n'
    section "社群情報共享（請認真讀完再決定）"
    printf ' %s啟用%s：你的機器會把「被封禁的攻擊 IP」上報給 CrowdSec 中央 API，\n' "$C_BOLD" "$C_RESET"
    printf '        同時取得全球社群黑名單 —— 別人被打，你提前封。\n'
    printf ' %s不啟用%s：純本地行為偵測，零資料外傳，但沒有社群黑名單。\n\n' "$C_BOLD" "$C_RESET"
    warn "本腳本其餘部分零遙測；這是唯一會外傳資料的選項，故預設為「不啟用」。"
    printf '\n'
    if confirm "啟用社群情報共享（上報 + 接收黑名單）？"; then
        cscli capi register >/dev/null 2>&1 || true
        ok "已啟用社群情報共享"
        manifest_add "crowdsec-capi" "啟用 CrowdSec 社群情報共享" "cscli console disable --all"
    else
        # 移除 CAPI 憑證即停止上報與接收
        if [ -f /etc/crowdsec/online_api_credentials.yaml ]; then
            mv /etc/crowdsec/online_api_credentials.yaml \
               /etc/crowdsec/online_api_credentials.yaml.disabled-by-oece 2>/dev/null || true
        fi
        cscli console disable --all >/dev/null 2>&1 || true
        ok "已關閉社群情報共享 —— 本機零資料外傳"
        info "日後想啟用：cscli capi register && systemctl restart crowdsec"
    fi

    # ---- bouncer（實際執行封禁的元件）----
    if ! command -v cs-firewall-bouncer >/dev/null 2>&1 \
       && ! systemctl list-unit-files 2>/dev/null | grep -q crowdsec-firewall-bouncer; then
        info "安裝防火牆 bouncer（沒有 bouncer 就只偵測不封禁）…"
        if command -v nft >/dev/null 2>&1; then
            pkg_install crowdsec-firewall-bouncer-nftables || \
            pkg_install crowdsec-firewall-bouncer-iptables || warn "bouncer 安裝失敗"
        else
            pkg_install crowdsec-firewall-bouncer-iptables || warn "bouncer 安裝失敗"
        fi
        manifest_add "crowdsec-bouncer" "CrowdSec 防火牆 bouncer" \
            "systemctl disable --now crowdsec-firewall-bouncer"
    fi

    systemctl enable --now crowdsec >/dev/null 2>&1 || true
    systemctl restart crowdsec >/dev/null 2>&1 || true

    printf '\n'
    if systemctl is-active crowdsec >/dev/null 2>&1; then
        ok "CrowdSec 運行中"
        cscli metrics 2>/dev/null | head -20 || true
    else
        err "CrowdSec 未能啟動，請查 journalctl -u crowdsec"
    fi
    info "常用命令：cscli decisions list · cscli alerts list · cscli metrics"
}

#=======================================================================
# 模塊 9 · fail2ban（輕量封禁）
#=======================================================================
module_fail2ban() {
    section "fail2ban · 輕量封禁"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        confirm "安裝 fail2ban？" || return 0
        pkg_install fail2ban || { err "安裝失敗"; return 1; }
    fi

    local cur_port
    cur_port="$(sshd_val port)"; [ -z "$cur_port" ] && cur_port=22

    mkdir -p /etc/fail2ban/jail.d
    {
        printf '[sshd]\nenabled = true\nport = %s\nmaxretry = 4\nfindtime = 10m\nbantime = 1h\n' "$cur_port"
        # Debian 13 起預設無 auth.log，只有 journald
        if   [ -f /var/log/secure ];   then printf 'backend = auto\nlogpath = /var/log/secure\n'
        elif [ -f /var/log/auth.log ]; then printf 'backend = auto\nlogpath = /var/log/auth.log\n'
        else                                printf 'backend = systemd\n'
        fi
        # recidive：反覆被封的慣犯，直接封一週
        printf '\n[recidive]\nenabled = true\nbantime = 1w\nfindtime = 1d\nmaxretry = 3\n'
    } > /etc/fail2ban/jail.d/oece-blue.local

    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    if systemctl is-active fail2ban >/dev/null 2>&1; then
        ok "fail2ban 已啟用（sshd 4 次封 1 小時 · recidive 慣犯封 1 週）"
        manifest_add "fail2ban" "fail2ban sshd + recidive jail" \
            "rm -f /etc/fail2ban/jail.d/oece-blue.local && systemctl restart fail2ban"
        printf '\n'
        fail2ban-client status 2>/dev/null || true
    else
        err "fail2ban 未能啟動，請查 journalctl -u fail2ban"
    fi
}

#=======================================================================
# 模塊 10 · root 蜜罐
#=======================================================================
honeypot_ban_rules() {
    local cur_port="$1" users_re
    users_re="$(printf '%s' "$HONEY_USERS" | tr ' ' '|')"

    if command -v fail2ban-client >/dev/null 2>&1; then
        cat > /etc/fail2ban/filter.d/oece-honeypot.conf <<EOF
# 誘餌用戶名命中偵測 — 由 oece-x-blue.sh 產生
[Definition]
failregex = ^.*(?:Invalid user|invalid user) (?:${users_re}) from <HOST>
            ^.*Failed \\S+ for (?:invalid user )?(?:${users_re}) from <HOST>
            ^.*User (?:${users_re}) from <HOST> not allowed because
ignoreregex =
EOF
        {
            printf '[oece-honeypot]\nenabled = true\nfilter = oece-honeypot\nport = %s\n' "$cur_port"
            # 誘餌帳戶沒有任何正當用途 —— 第一次嘗試就封
            printf 'maxretry = 1\nfindtime = 1d\nbantime = 1w\n'
            if   [ -f /var/log/secure ];   then printf 'backend = auto\nlogpath = /var/log/secure\n'
            elif [ -f /var/log/auth.log ]; then printf 'backend = auto\nlogpath = /var/log/auth.log\n'
            else                                printf 'backend = systemd\n'
            fi
        } > /etc/fail2ban/jail.d/oece-honeypot.local
        systemctl restart fail2ban >/dev/null 2>&1 || true
        if fail2ban-client status oece-honeypot >/dev/null 2>&1; then
            ok "蜜罐秒封規則已生效（誘餌用戶名 1 次即封 1 週）"
            manifest_add "honeypot-ban" "蜜罐誘餌用戶名秒封規則" \
                "rm -f /etc/fail2ban/jail.d/oece-honeypot.local /etc/fail2ban/filter.d/oece-honeypot.conf && systemctl restart fail2ban"
        else
            warn "蜜罐 jail 未生效，請查 fail2ban-client status"
        fi
    else
        warn "未安裝 fail2ban / CrowdSec，蜜罐只會記錄不會封禁。"
        info "建議先跑「選單 9 · fail2ban」或「選單 8 · CrowdSec」。"
    fi
}

# 管理員必須真的能取得 root，否則禁用 root SSH 後會「登得進去但什麼都做不了」
admin_can_become_root() {
    local admin="$1" st
    st="$(passwd -S "$admin" 2>/dev/null | awk '{print $2}' || true)"
    case "$st" in
        P|PS) return 0 ;;   # 已設定可用密碼
    esac
    if grep -rqE "^[[:space:]]*${admin}[[:space:]].*NOPASSWD" /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
        return 0
    fi
    return 1
}

module_honeypot() {
    section "root 蜜罐"
    info "機器人 99% 的暴破都打 root / admin / ubuntu / test 這幾個名字。"
    info "把它們全部變成誘餌：真管理員換一個名字，誘餌帳戶鎖死並第一次嘗試就封。"
    printf '\n'
    kv "誘餌用戶名" "$HONEY_USERS"

    # ---- 步驟 1：確保有真管理員 ----
    printf '\n%s步驟 1 / 6：確認真管理員帳戶%s\n' "$C_BOLD" "$C_RESET"
    local admin
    printf '真管理員用戶名（不可是 root；不存在會自動建立）: '
    read -r admin || admin=""
    if [ -z "$admin" ] || [ "$admin" = "root" ] || ! valid_username "$admin"; then
        err "必須指定一個非 root 的管理員用戶名（小寫字母/數字/底線/連字號，不以連字號開頭）。"
        return 1
    fi

    if awk -F: -v u="$admin" '$1==u{f=1} END{exit !f}' /etc/passwd; then
        ok "帳戶 ${admin} 已存在"
    else
        confirm "帳戶 ${admin} 不存在，現在建立（含 sudo 權限）？" || return 0
        useradd -m -s /bin/bash "$admin" || { err "建立失敗"; return 1; }
        if getent group sudo >/dev/null 2>&1; then usermod -aG sudo "$admin"
        else usermod -aG wheel "$admin" 2>/dev/null || true
        fi
        ok "已建立 ${admin} 並加入管理員群組"
        manifest_add "admin-user" "建立管理員帳戶 ${admin}" "userdel -r ${admin}"
        warn "請立刻為它設定密碼（sudo 需要）：passwd ${admin}"
    fi

    # ---- 步驟 2：公鑰 ----
    printf '\n%s步驟 2 / 6：確認 %s 的公鑰%s\n' "$C_BOLD" "$admin" "$C_RESET"
    local ahome akeys nkeys
    ahome="$(getent passwd "$admin" | cut -d: -f6)"
    akeys="${ahome}/.ssh/authorized_keys"
    nkeys="$(count_valid_keys "$akeys")"
    if [ "$nkeys" -eq 0 ]; then
        warn "${admin} 沒有任何公鑰。"
        printf '  1) 從 root 複製現有公鑰\n  2) 貼上一把公鑰\n  0) 中止\n請選擇: '
        local kc; read -r kc || kc="0"
        case "$kc" in
            1)
                mkdir -p "${ahome}/.ssh"
                cp /root/.ssh/authorized_keys "$akeys" 2>/dev/null || { err "root 也沒有公鑰"; return 1; }
                ;;
            2)
                printf '貼上公鑰（ssh-ed25519 / ssh-rsa 開頭）: '
                local pk; read -r pk || pk=""
                [ -z "$pk" ] && { err "未輸入"; return 1; }
                mkdir -p "${ahome}/.ssh"
                printf '%s\n' "$pk" >> "$akeys"
                ;;
            *) return 0 ;;
        esac
        chown -R "${admin}:${admin}" "${ahome}/.ssh"
        chmod 700 "${ahome}/.ssh"; chmod 600 "$akeys"
        nkeys="$(count_valid_keys "$akeys")"
        [ "$nkeys" -eq 0 ] && { err "公鑰無效，中止。"; return 1; }
    fi
    ok "${admin} 有 ${nkeys} 把有效公鑰"

    # ---- 步驟 3：提權能力（能登入 ≠ 能管理）----
    printf '\n%s步驟 3 / 6：確認 %s 真的能取得 root 權限%s\n' "$C_BOLD" "$admin" "$C_RESET"
    if admin_can_become_root "$admin"; then
        ok "${admin} 可以正常提權（已設密碼或有 NOPASSWD sudo）"
    else
        printf '\n'
        err "${admin} 沒有設定密碼，也沒有 NOPASSWD sudo —— sudo 會直接失敗。"
        err "一旦禁用 root SSH，你將「登得進去但什麼都做不了」。"
        printf '\n'
        printf '  1) 現在設定密碼（推薦）\n'
        printf '  2) 設定 NOPASSWD sudo（免密碼提權，方便但較弱）\n'
        printf '  0) 中止\n請選擇: '
        local pc; read -r pc || pc="0"
        case "$pc" in
            1)
                passwd "$admin" || { err "設定密碼失敗，中止。"; return 1; }
                manifest_add "admin-passwd" "為 ${admin} 設定密碼" "passwd -d ${admin}"
                ;;
            2)
                printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$admin" > "/etc/sudoers.d/90-oece-${admin}"
                chmod 440 "/etc/sudoers.d/90-oece-${admin}"
                if visudo -c >/dev/null 2>&1; then
                    ok "已設定 NOPASSWD sudo"
                    manifest_add "admin-nopasswd" "${admin} NOPASSWD sudo" "rm -f /etc/sudoers.d/90-oece-${admin}"
                else
                    rm -f "/etc/sudoers.d/90-oece-${admin}"
                    err "sudoers 校驗失敗，已回退。"; return 1
                fi
                ;;
            *) info "已中止。請先讓 ${admin} 能提權再回來。"; return 0 ;;
        esac
        admin_can_become_root "$admin" || { err "仍無法提權，中止。"; return 1; }
        ok "提權能力已確認"
    fi

    # ---- 前置檢查 + 回滾武裝 ----
    harden_preflight "$admin" || return 1
    local cur_port
    cur_port="$(sshd_val port)"; [ -z "$cur_port" ] && cur_port=22

    # AllowUsers 只寫一個名字會把其他已有公鑰的帳號立刻踢出。
    # 預設保留「已有有效公鑰、且不在誘餌名單」的帳號，並讓操作者確認。
    local keep="$admin" user f nkeys honey_re
    honey_re=" $(printf '%s' "$HONEY_USERS" | tr ' ' '\n' | grep -vx "$admin" | tr '\n' ' ')"
    while IFS=$'\t' read -r user f; do
        [ -n "$user" ] || continue
        [ "$user" = "$admin" ] && continue
        case "$honey_re" in
            *" ${user} "*) continue ;;
        esac
        nkeys="$(count_valid_keys "$f")"
        [ "$nkeys" -gt 0 ] || continue
        case " ${keep} " in
            *" ${user} "*) ;;
            *) keep="${keep} ${user}" ;;
        esac
    done < <(list_authkey_files 2>/dev/null || true)
    printf '\n'
    warn "AllowUsers 將只放行：${keep}"
    warn "不在這份名單、也不在誘餌名單的帳號，reload 後無法 SSH 登入。"
    if ! confirm "這份保留名單正確？"; then
        printf '改成空白分隔的帳號名單（必須包含 %s）: ' "$admin"
        local custom
        read -r custom || custom=""
        [ -z "$custom" ] && { info "已中止。"; return 0; }
        case " ${custom} " in
            *" ${admin} "*) keep="$custom" ;;
            *) err "名單必須包含 ${admin}。"; return 1 ;;
        esac
        local one
        for one in $keep; do
            valid_username "$one" || { err "非法帳號名：${one}"; return 1; }
        done
    fi

    printf '\n'
    warn "套用後：root 將無法透過 SSH 登入。保留帳號：${keep}"
    confirm_danger "確認啟用 root 蜜罐？（${ROLLBACK_MINUTES} 分鐘內未確認將自動還原）" || return 0

    local bk; bk="$(backup_create)"
    arm_rollback "$ROLLBACK_MINUTES" "$bk" || return 1
    ok "回滾點：${bk}（定時器已武裝）"

    # ---- 步驟 3：sshd 層封鎖 ----
    printf '\n%s步驟 4 / 6：sshd 層封鎖誘餌用戶名%s\n' "$C_BOLD" "$C_RESET"
    ensure_sshd_include || true
    sshd_set PermitRootLogin no
    sshd_set DenyUsers "$HONEY_USERS"
    sshd_set AllowUsers "$keep"
    if ! sshd_validate_reload; then
        err "sshd 設定有誤，立即還原。"
        blue_rollback_now "$bk"
        return 1
    fi
    ok "sshd 已禁止 root 登入，AllowUsers：${keep}"
    manifest_add "honeypot-sshd" "sshd 禁 root + DenyUsers 誘餌 + AllowUsers ${keep}" \
        "rm -f ${BLUE_SSHD_DROPIN} && systemctl reload sshd"

    # ---- 步驟 4：帳戶層鎖定 ----
    printf '\n%s步驟 5 / 6：鎖定 root 帳戶密碼%s\n' "$C_BOLD" "$C_RESET"
    if passwd -l root >/dev/null 2>&1; then
        ok "root 密碼已鎖定（passwd -l）"
        manifest_add "honeypot-rootlock" "鎖定 root 密碼" "passwd -u root"
    else
        warn "鎖定 root 密碼失敗"
    fi

    printf '\n'
    warn "進階選項：把 root 的 shell 改成 nologin，會讓蜜罐更徹底 ——"
    warn "但同時會影響 su - 、部分 cron 任務，以及某些雲商的救援流程。"
    if confirm "要把 root 的 shell 改成 /usr/sbin/nologin 嗎？（不確定就選 N）"; then
        local oldshell
        oldshell="$(getent passwd root | cut -d: -f7)"
        if usermod -s /usr/sbin/nologin root 2>/dev/null; then
            ok "root shell 已改為 nologin"
            manifest_add "honeypot-rootshell" "root shell → nologin" "usermod -s ${oldshell} root"
        else
            warn "修改失敗"
        fi
    else
        info "已保留 root 的 shell（推薦的保守選擇）"
    fi

    # ---- 步驟 5：秒封規則 ----
    printf '\n%s步驟 6 / 6：誘餌用戶名秒封規則%s\n' "$C_BOLD" "$C_RESET"
    honeypot_ban_rules "$cur_port"

    post_harden_notice "$ROLLBACK_MINUTES" "$cur_port" "$admin"
}

#=======================================================================
# 安全改 SSH 埠
#   血的教訓：手動 echo "Port 2222" >> 設定檔再 restart，會因為
#   ① 防火牆沒放行新埠 ② Debian/Ubuntu 的 ssh.socket 仍綁舊埠
#   而直接把自己鎖在門外。這個函式把三件事一次做對，並掛回滾定時器。
#=======================================================================
change_ssh_port() {
    local cur_port new_port
    cur_port="$(sshd_val port)"; [ -z "$cur_port" ] && cur_port=22

    printf '新 SSH 埠 [1024-65535，當前 %s]: ' "$cur_port"
    read -r new_port || new_port=""
    if ! valid_ssh_port "$new_port"; then
        err "請使用 1024-65535 之間的純數字埠。"; return 1
    fi
    if ss -ltnH 2>/dev/null | awk '{addr=$4; sub(/\]$/,"",addr); n=split(addr,a,":"); print a[n]}' \
         | grep -qx "$new_port"; then
        err "埠 ${new_port} 已被佔用。"; return 1
    fi

    harden_preflight || return 1

    printf '\n'
    warn "若你的雲商有「網路層安全組」（阿里雲/騰訊雲/AWS/GCP），"
    warn "請先在控制台放行 ${new_port} —— 本腳本只能改機器自己的防火牆。"
    confirm_danger "將 SSH 埠從 ${cur_port} 改為 ${new_port}" || return 0

    local bk; bk="$(backup_create)"
    arm_rollback "$ROLLBACK_MINUTES" "$bk" || return 1
    ok "回滾點：${bk}（定時器已武裝）"

    # ① 防火牆先放行新埠 —— 必須在改埠之前，否則改完就連不上
    if command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | head -1 | grep -qi inactive; then
        ufw allow "${new_port}/tcp" comment 'SSH (oece-blue)' >/dev/null 2>&1 || true
        ok "UFW 已放行 ${new_port}/tcp"
    fi

    # ② 改設定
    ensure_sshd_include || true
    sshd_set Port "$new_port"

    # ③ Debian/Ubuntu 的 socket activation 會無視 sshd_config 的 Port，
    #    必須同步改 socket 或停用它，否則新埠根本不會被監聽。
    if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
        info "偵測到 ssh.socket（socket activation）—— 同步調整監聽埠"
        mkdir -p /etc/systemd/system/ssh.socket.d
        printf '[Socket]\nListenStream=\nListenStream=%s\n' "$new_port" \
            > /etc/systemd/system/ssh.socket.d/99-oece-blue.conf
        systemctl daemon-reload
        systemctl restart ssh.socket >/dev/null 2>&1 || true
        manifest_add "ssh-socket-port" "ssh.socket 監聽埠 → ${new_port}" \
            "rm -f /etc/systemd/system/ssh.socket.d/99-oece-blue.conf && systemctl daemon-reload && systemctl restart ssh.socket"
    fi

    if ! sshd -t 2>/dev/null; then
        err "sshd 設定校驗失敗，立即還原。"
        blue_rollback_now "$bk"
        return 1
    fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    sleep 1

    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE ":${new_port}\$"; then
        ok "sshd 已在 ${new_port} 埠監聽"
    else
        err "新埠未監聽，立即還原。"
        blue_rollback_now "$bk"
        return 1
    fi
    manifest_add "ssh-port" "SSH 埠 ${cur_port} → ${new_port}" \
        "rm -f ${BLUE_SSHD_DROPIN} && systemctl restart sshd"

    post_harden_notice "$ROLLBACK_MINUTES" "$new_port" ""
    return 0
}

#=======================================================================
# 模塊 11 · endlessh 焦油坑
#=======================================================================
module_endlessh() {
    section "endlessh 焦油坑"
    info "在 22 埠回應一個永不結束的假 banner，每 10 秒吐一個字元。"
    info "掃描器會傻等好幾個小時，而你的真 SSH 早就搬到別的埠了。"

    local cur_port
    cur_port="$(sshd_val port)"; [ -z "$cur_port" ] && cur_port=22
    kv "目前 SSH 埠" "$cur_port"

    # ---- 強制前置檢查：真 SSH 必須已離開 22 ----
    if [ "$cur_port" = "22" ]; then
        printf '\n'
        err "你的真 SSH 還在 22 埠 —— 現在裝 endlessh 會直接把自己鎖在門外。"
        printf '\n'
        info "正確順序：先把 SSH 搬到別的埠並驗證可登入，再回來裝 endlessh。"
        printf '\n'
        if confirm "現在就用安全流程改 SSH 埠嗎？（會自動處理防火牆並掛回滾定時器）"; then
            change_ssh_port || return 1
            info "請先用新埠登入驗證並執行 --confirm，之後再回來裝 endlessh。"
        fi
        return 1
    fi

    # 22 埠必須是空的
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE ':22$'; then
        err "22 埠已被其他服務佔用，請先釋放。"
        ss -ltnp 2>/dev/null | grep ':22 ' || true
        return 1
    fi
    ok "真 SSH 在 ${cur_port} 埠，22 埠空閒 —— 可以安全部署"

    if ! command -v endlessh >/dev/null 2>&1; then
        confirm "從系統源安裝 endlessh？" || return 0
        pkg_install endlessh || {
            err "系統源沒有 endlessh（Debian 12+ / Ubuntu 24.04+ 才內建）。"
            info "可改用 Docker：docker run -d -p 22:2222 --restart=always --name endlessh ghcr.io/skeeto/endlessh"
            return 1
        }
    fi

    mkdir -p /etc/endlessh
    cat > /etc/endlessh/config <<'EOF'
# managed by oece-x-blue.sh
Port 22
Delay 10000
MaxLineLength 32
MaxClients 4096
LogLevel 1
EOF

    # 綁定 <1024 需要 CAP_NET_BIND_SERVICE
    mkdir -p /etc/systemd/system/endlessh.service.d
    cat > /etc/systemd/system/endlessh.service.d/99-oece-blue.conf <<'EOF'
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
PrivateUsers=false
EOF
    systemctl daemon-reload
    systemctl enable --now endlessh >/dev/null 2>&1 || true
    systemctl restart endlessh >/dev/null 2>&1 || true

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qv inactive; then
        ufw allow 22/tcp comment 'endlessh tarpit' >/dev/null 2>&1 || true
    fi

    printf '\n'
    if systemctl is-active endlessh >/dev/null 2>&1; then
        ok "endlessh 已在 22 埠佈署完成"
        manifest_add "endlessh" "endlessh 焦油坑（22 埠）" \
            "systemctl disable --now endlessh && rm -rf /etc/endlessh /etc/systemd/system/endlessh.service.d && systemctl daemon-reload"
        info "戰績會顯示在「選單 1 · 藍隊面板」。"
    else
        err "endlessh 未能啟動，請查 journalctl -u endlessh"
        return 1
    fi
}

#=======================================================================
# 模塊 12 · 防火牆（含 Docker 繞過修復）
#=======================================================================
UFW_DOCKER_BEGIN="# BEGIN UFW AND DOCKER (oece-x-blue)"
UFW_DOCKER_END="# END UFW AND DOCKER (oece-x-blue)"

apply_docker_ufw_fix() {
    local rules="/etc/ufw/after.rules"
    [ -f "$rules" ] || { err "找不到 ${rules}"; return 1; }

    if grep -qF "$UFW_DOCKER_BEGIN" "$rules"; then
        info "DOCKER-USER 過濾鏈已存在，跳過。"
        return 0
    fi
    cp -a "$rules" "${rules}.oece-bak"
    cat >> "$rules" <<EOF

${UFW_DOCKER_BEGIN}
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN
COMMIT
${UFW_DOCKER_END}
EOF
    systemctl restart ufw >/dev/null 2>&1 || ufw reload >/dev/null 2>&1 || true
    ok "Docker 繞過修復已套用（容器流量現在會經過 UFW）"
    warn "注意：套用後，原本靠 -p 發布的容器埠會被擋。"
    info "要放行某個容器：ufw route allow proto tcp from any to any port <容器內埠>"
    manifest_add "docker-ufw" "Docker DOCKER-USER 過濾鏈" \
        "cp -a ${rules}.oece-bak ${rules} && systemctl restart ufw"
}

show_docker_exposure() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0
    local pub
    pub="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep '0\.0\.0\.0' || true)"
    if [ -z "$pub" ]; then
        info "目前沒有容器發布到 0.0.0.0"
        return 0
    fi
    printf '\n%s對公網發布的容器埠：%s\n' "$C_BOLD" "$C_RESET"
    printf '%s%s%s\n' "$C_YELLOW" "$pub" "$C_RESET"
    if grep -qF "$UFW_DOCKER_BEGIN" /etc/ufw/after.rules 2>/dev/null; then
        ok "已裝 DOCKER-USER 過濾鏈，這些埠受 UFW 管控"
    else
        err "這些埠繞過了 UFW —— ufw deny 對它們完全無效"
    fi
}

apply_cloudflare_only() {
    info "抓取 Cloudflare 官方 IP 段，限制 80/443 僅接受來自 CF 的連線。"
    warn "套用後，直接用 IP 訪問你的網站會被擋（這正是目的）。"
    confirm "確認套用 Cloudflare-only 入口？" || return 0

    local v4 v6 ip n=0 bad=0
    v4="$(curl "${CURL_OPTS[@]}" https://www.cloudflare.com/ips-v4 2>/dev/null || true)"
    v6="$(curl "${CURL_OPTS[@]}" https://www.cloudflare.com/ips-v6 2>/dev/null || true)"
    if [ -z "$v4" ]; then
        err "取不到 Cloudflare IP 段，已中止（不會留下半套規則）。"
        return 1
    fi
    local rules="${TMP_DIR}/cf-cidrs"
    : > "$rules"
    for ip in $v4 $v6; do
        [ -n "$ip" ] || continue
        case "$ip" in
            *[\;\|\&\$\`\<\>\(\)\{\}\'\"]*|*[!0-9a-fA-F:./]*)
                bad=$(( bad + 1 ))
                continue
                ;;
        esac
        printf '%s\n' "$ip" >> "$rules"
        n=$(( n + 1 ))
    done
    if [ "$n" -lt 5 ] || [ "$bad" -gt 0 ]; then
        err "Cloudflare 清單不完整或含非法字元（網段 ${n}，拒絕 ${bad}）。未改防火牆。"
        return 1
    fi
    local bk
    bk="$(backup_create)" || return 1
    ufw delete allow 80/tcp  >/dev/null 2>&1 || true
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
    local failed=0
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        ufw allow from "$ip" to any port 80  proto tcp comment 'Cloudflare' >/dev/null 2>&1 || failed=1
        ufw allow from "$ip" to any port 443 proto tcp comment 'Cloudflare' >/dev/null 2>&1 || failed=1
    done < "$rules"
    if [ "$failed" -ne 0 ]; then
        err "寫入中途失敗，正在還原 ufw 設定。"
        [ -d "$bk/ufw.d" ] && cp -a "$bk/ufw.d/." /etc/ufw/ 2>/dev/null || true
        ufw reload >/dev/null 2>&1 || true
        return 1
    fi
    ok "已放行 ${n} 個 Cloudflare 網段的 80/443"
    manifest_add "cf-only" "80/443 僅放行 Cloudflare 網段" \
        "ufw status numbered | grep Cloudflare  # 需手動逐條 ufw delete"
}

module_firewall() {
    section "防火牆"
    local fw fwtype fwstate
    fw="$(fw_status)"; fwtype="${fw%%|*}"; fwstate="${fw##*|}"
    kv "當前防火牆" "${fwtype} · ${fwstate}"
    show_docker_exposure

    printf '\n'
    printf ' 1) 啟用 UFW（default deny + 放行 SSH/80/443）\n'
    printf ' 2) 修復 Docker 繞過防火牆 ★\n'
    printf ' 3) Cloudflare-only 入口（80/443 僅放行 CF 網段）\n'
    printf ' 4) 查看當前規則\n'
    printf ' 5) 安全改 SSH 埠（自動處理防火牆 + socket）★\n'
    printf ' 0) 返回\n\n請選擇: '
    local c; read -r c || c="0"
    case "$c" in
        1)
            command -v ufw >/dev/null 2>&1 || pkg_install ufw || return 1
            local cur_port; cur_port="$(sshd_val port)"; [ -z "$cur_port" ] && cur_port=22
            harden_preflight || return 1
            confirm_danger "UFW default deny incoming，放行 ${cur_port}/tcp 與 80/443" || return 0
            local bk; bk="$(backup_create)"
            arm_rollback "$ROLLBACK_MINUTES" "$bk" || return 1
            ufw --force reset >/dev/null 2>&1 || true
            ufw default deny incoming  >/dev/null 2>&1
            ufw default allow outgoing >/dev/null 2>&1
            ufw allow "${cur_port}/tcp" comment 'SSH (oece-blue)' >/dev/null 2>&1
            ufw allow 80/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1
            ufw --force enable >/dev/null 2>&1
            ok "UFW 已啟用"
            manifest_add "ufw" "UFW default deny + 放行 SSH/80/443" "ufw --force disable"
            ufw status verbose 2>/dev/null | head -20 || true
            post_harden_notice "$ROLLBACK_MINUTES" "$cur_port" ""
            ;;
        2)
            command -v docker >/dev/null 2>&1 || { err "本機未安裝 Docker。"; return 1; }
            if [ "$fwstate" != "active" ]; then
                err "請先啟用 UFW（選項 1），否則修復沒有意義。"
                return 1
            fi
            confirm_danger "注入 DOCKER-USER 過濾鏈（容器發布埠將受 UFW 管控）" || return 0
            apply_docker_ufw_fix
            show_docker_exposure
            ;;
        3)
            if [ "$fwstate" != "active" ]; then err "請先啟用 UFW（選項 1）。"; return 1; fi
            apply_cloudflare_only
            ;;
        4)
            if command -v ufw >/dev/null 2>&1; then ufw status verbose 2>/dev/null || true
            elif command -v nft >/dev/null 2>&1; then nft list ruleset 2>/dev/null | head -40
            else iptables -S 2>/dev/null | head -40 || true
            fi
            ;;
        5) change_ssh_port ;;
        *) return 0 ;;
    esac
}

#=======================================================================
# 告警通道（Telegram + 郵件）
#   憑證只存 /etc/oece-x/blue.env（chmod 600），絕不進 git、絕不外傳第三方。
#=======================================================================
BLUE_ENV="${BLUE_ETC}/blue.env"
BLUE_NOTIFY_BIN="/usr/local/sbin/oece-blue-notify"

# 寫入 blue.env 的單一鍵值。env_set 在腳本開頭（與 lib/security.sh 同一段）。
env_set_blue() {
    ensure_dirs
    env_set "$@"
}

# 獨立的通知發送器：PAM 鉤子與 cron 直接呼叫，不依賴主腳本存在
write_notify_script() {
    cat > "$BLUE_NOTIFY_BIN" <<'NOTIFY_EOF'
#!/usr/bin/env bash
# oece-x-blue 通知發送器 — 用法: oece-blue-notify <標題> <內文>
# 任何失敗都靜默吞掉，絕不阻塞呼叫方（尤其是 PAM 登入流程）。
ENVF="/etc/oece-x/blue.env"
[ -r "$ENVF" ] || exit 0
# shellcheck disable=SC1090
. "$ENVF" 2>/dev/null || exit 0
TITLE="${1:-oece-x-blue}"
BODY="${2:-}"
HOST="$(hostname 2>/dev/null || echo unknown)"
MSG="[${HOST}] ${TITLE}

${BODY}"
if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    curl -fsS --max-time 8 -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${MSG}" >/dev/null 2>&1 || true
fi
if [ -n "${MAIL_TO:-}" ] && command -v msmtp >/dev/null 2>&1; then
    printf 'To: %s\nSubject: [%s] %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$MAIL_TO" "$HOST" "$TITLE" "$BODY" \
        | msmtp --file=/etc/oece-x/msmtprc "$MAIL_TO" >/dev/null 2>&1 || true
fi
exit 0
NOTIFY_EOF
    chmod 700 "$BLUE_NOTIFY_BIN"
}

blue_notify() {
    [ -x "$BLUE_NOTIFY_BIN" ] || write_notify_script
    "$BLUE_NOTIFY_BIN" "$1" "${2:-}" || true
}

module_alerts_config() {
    section "告警通道配置"
    info "憑證只寫入 ${BLUE_ENV}（chmod 600），不會進 git、不會外傳給第三方。"
    ensure_dirs
    # shellcheck disable=SC1090
    [ -r "$BLUE_ENV" ] && . "$BLUE_ENV" 2>/dev/null

    printf '\n'
    kv "Telegram" "$([ -n "${TG_BOT_TOKEN:-}" ] && echo '已設定' || echo '未設定')"
    kv "郵件" "$([ -n "${MAIL_TO:-}" ] && echo "已設定（${MAIL_TO}）" || echo '未設定')"

    printf '\n 1) 設定 Telegram Bot\n 2) 設定郵件（msmtp）\n 3) 發送測試訊息\n 0) 返回\n\n請選擇: '
    local c; read -r c || c="0"
    local tok cid to h pt us pw
    case "$c" in
        1)
            printf '\n'
            info "取得方式：Telegram 找 @BotFather 建 bot 拿 token；再找 @userinfobot 拿 chat id。"
            printf '\nBot Token: '; read -r tok || tok=""
            printf 'Chat ID  : '; read -r cid || cid=""
            if [ -z "$tok" ] || [ -z "$cid" ]; then err "未輸入完整。"; return 1; fi
            case "$tok" in
                *[$'\n\r']*|*[!A-Za-z0-9:_-]*)
                    err "Bot Token 含非法字元，已拒絕寫入。"
                    return 1
                    ;;
            esac
            case "$cid" in
                ''|*[!0-9-]*)
                    err "Chat ID 必須是整數。"
                    return 1
                    ;;
            esac
            env_set_blue TG_BOT_TOKEN "$tok" || return 1
            env_set_blue TG_CHAT_ID   "$cid" || return 1
            write_notify_script
            ok "Telegram 已設定"
            blue_notify "測試訊息" "如果你看到這則訊息，Telegram 告警已經可以用了。"
            info "已送出測試訊息，請查看你的 Telegram。"
            ;;
        2)
            printf '\n'
            warn "VPS 直發郵件極易進垃圾箱，建議填一個 SMTP 中繼（Gmail / SendGrid 等）。"
            command -v msmtp >/dev/null 2>&1 || pkg_install msmtp msmtp-mta || { err "msmtp 安裝失敗"; return 1; }
            printf '\n收件人   : '; read -r to || to=""
            printf 'SMTP 主機: '; read -r h || h=""
            printf 'SMTP 埠 [587]: '; read -r pt || pt=""; [ -z "$pt" ] && pt=587
            printf 'SMTP 帳號: '; read -r us || us=""
            printf 'SMTP 密碼: '; read -rs pw || pw=""; printf '\n'
            if [ -z "$to" ] || [ -z "$h" ]; then err "未輸入完整。"; return 1; fi
            case "$to" in
                *[$'\n\r']*|*[[:space:]]*|*[!A-Za-z0-9._%+-@]*)
                    err "收件人格式無效。"; return 1 ;;
            esac
            case "$h" in
                *[$'\n\r']*|*[[:space:]]*|*[!A-Za-z0-9.-]*)
                    err "SMTP 主機含非法字元。"; return 1 ;;
            esac
            case "$pt" in
                ''|*[!0-9]*) err "SMTP 埠必須是數字。"; return 1 ;;
            esac
            if [ "$pt" -lt 1 ] || [ "$pt" -gt 65535 ]; then
                err "SMTP 埠超出範圍。"; return 1
            fi
            case "$us" in
                *[$'\n\r']*) err "SMTP 帳號含換行，已拒絕。"; return 1 ;;
            esac
            case "$pw" in
                *[$'\n\r']*) err "SMTP 密碼含換行，已拒絕。"; return 1 ;;
            esac
            # msmtp 以空白分欄。含空白或 # 的密碼改走 passwordeval，避免欄位錯位。
            {
                printf '%s\n' \
                    "defaults" \
                    "auth           on" \
                    "tls            on" \
                    "tls_trust_file /etc/ssl/certs/ca-certificates.crt" \
                    "account        oece" \
                    "host           ${h}" \
                    "port           ${pt}" \
                    "from           ${us}" \
                    "user           ${us}"
                case "$pw" in
                    *[[:space:]]*|*'#'*)
                        printf 'passwordeval   %s\n' "$(sh_sq "printf %s $(sh_sq "$pw")")"
                        ;;
                    *)
                        printf 'password       %s\n' "$pw"
                        ;;
                esac
                printf '%s\n' "account default : oece"
            } > "${BLUE_ETC}/msmtprc"
            chmod 600 "${BLUE_ETC}/msmtprc"
            env_set_blue MAIL_TO "$to" || return 1
            write_notify_script
            ok "郵件已設定（${BLUE_ETC}/msmtprc，chmod 600）"
            blue_notify "測試訊息" "如果你收到這封信，郵件告警已經可以用了。"
            ;;
        3)
            blue_notify "測試訊息" "這是一則來自 oece-x-blue 的測試告警。$(date -Is)"
            ok "已送出（若未設定任何通道則不會有動作）"
            ;;
        *) return 0 ;;
    esac
}

#=======================================================================
# 模塊 14 · 登入即時告警（PAM 鉤子）
#=======================================================================
BLUE_LOGIN_HOOK="/usr/local/bin/oece-blue-login-alert"

module_login_alert() {
    section "登入即時告警"
    info "在 sshd 的 PAM 流程掛一個鉤子：有人登入成功，1 秒內推送到你的手機。"
    info "地理位置查詢預設關閉。開啟後會把來源 IP 送到 ipinfo.io。"

    if [ ! -r "$BLUE_ENV" ]; then
        warn "尚未設定任何告警通道，請先跑「選單 13 · 告警通道配置」。"
        confirm "仍要安裝鉤子（之後再設定通道）？" || return 0
    fi

    local geo_flag="0"
    if confirm "登入告警要查地理位置嗎？（會把來源 IP 送到 ipinfo.io；預設不查）"; then
        geo_flag="1"
        warn "已選擇外傳來源 IP 到 ipinfo.io。可隨時把 blue.env 的 LOGIN_GEO_LOOKUP 改成 0。"
    else
        info "地理位置查詢保持關閉。告警只含本機已知的用戶、來源位址與時間。"
    fi

    write_notify_script
    ensure_dirs
    env_set_blue LOGIN_GEO_LOOKUP "$geo_flag" || return 1
    cat > "$BLUE_LOGIN_HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# oece-x-blue 登入告警鉤子（由 pam_exec 呼叫）
# 鐵律：無論如何都 exit 0，絕不阻塞登入流程。
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0
[ "${PAM_SERVICE:-}" = "sshd" ] || exit 0
{
    GEO=""
    # 預設不外傳。只有 blue.env 明確設 LOGIN_GEO_LOOKUP=1 才查 ipinfo。
    LOOKUP=0
    if [ -r /etc/oece-x/blue.env ]; then
        LOOKUP="$(sed -n "s/^LOGIN_GEO_LOOKUP='\\{0,1\\}\\([01]\\)'\\{0,1\\}.*/\\1/p" /etc/oece-x/blue.env | head -1)"
    fi
    if [ "$LOOKUP" = "1" ]; then
        # 只對單一 IP 查地理位置。主機名、空白或 shell 元字元不得進 URL。
        # 字元集先擋掉路徑與 shell 元字元，再用與 is_ip 相同的格式。
        # IP 只進 query string，不拼進 URL 路徑。
        case "${PAM_RHOST:-}" in
            ''|*[!0-9a-fA-F:.]*) PAM_RHOST="" ;;
            *:*)
                printf '%s\n' "$PAM_RHOST" | grep -qE \
                    '^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$|^::1$|^::$' || PAM_RHOST=""
                ;;
            *)
                printf '%s\n' "$PAM_RHOST" | grep -qE \
                    '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || PAM_RHOST=""
                ;;
        esac
        if [ -n "${PAM_RHOST:-}" ]; then
            GEO="$(curl -fsS --max-time 4 -G \
                  --data-urlencode "ip=${PAM_RHOST}" \
                  "https://ipinfo.io/json" 2>/dev/null \
                  | sed -n 's/.*"country"[: ]*"\([^"]*\)".*/\1/p' | head -1)"
        fi
    fi
    BODY="用戶 : ${PAM_USER:-?}
來源 : ${PAM_RHOST:-本機}${GEO:+ (${GEO})}
時間 : $(date '+%F %T %Z')"
    /usr/local/sbin/oece-blue-notify "🔓 SSH 登入成功" "$BODY"
} >/dev/null 2>&1 &
exit 0
HOOK_EOF
    chmod 700 "$BLUE_LOGIN_HOOK"

    local pamf="/etc/pam.d/sshd"
    if [ ! -f "$pamf" ]; then err "找不到 ${pamf}"; return 1; fi
    if grep -q "oece-blue-login-alert" "$pamf"; then
        info "PAM 鉤子已存在。"
    else
        cp -a "$pamf" "${pamf}.oece-bak"
        printf '\n# oece-x-blue 登入告警（optional：失敗不影響登入）\nsession optional pam_exec.so %s\n' \
            "$BLUE_LOGIN_HOOK" >> "$pamf"
        ok "PAM 鉤子已安裝到 ${pamf}"
        manifest_add "login-alert" "SSH 登入即時告警 PAM 鉤子" \
            "cp -a ${pamf}.oece-bak ${pamf} && rm -f ${BLUE_LOGIN_HOOK}"
    fi
    warn "請「另開一個終端」重新登入一次，確認收得到推送且登入未受影響。"
}

#=======================================================================
# 模塊 15 · 每日巡檢報告 + 配置漂移偵測
#=======================================================================
BLUE_DAILY_BIN="/usr/local/sbin/oece-blue-daily"

module_daily_report() {
    section "每日巡檢報告"
    info "每天跑一次評分，與上次比對「配置漂移」，把異動推送給你。"
    info "漂移偵測才是價值所在：評分下降 · 新增 uid=0 帳戶 · 新增公鑰 · 新增監聽埠。"

    local self
    self="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    if [ ! -f "$self" ]; then
        err "無法定位腳本自身路徑，請下載成本地檔案再執行（非 curl 管道）。"
        return 1
    fi
    install -m 700 "$self" /usr/local/sbin/oece-x-blue.sh 2>/dev/null || true

    write_notify_script
    cat > "$BLUE_DAILY_BIN" <<'DAILY_EOF'
#!/usr/bin/env bash
# oece-x-blue 每日巡檢 + 配置漂移偵測
LIB=/var/lib/oece-x; LOG=/var/log/oece-x; SNAP="$LIB/drift"
mkdir -p "$LOG" "$SNAP"
TODAY="$(date +%F)"
REPORT="$LOG/daily-${TODAY}.md"

SCORE="$(NO_COLOR=1 bash /usr/local/sbin/oece-x-blue.sh --audit 2>/dev/null \
        | sed -n 's/^score=\([0-9][0-9]*\) got=\([0-9][0-9]*\) max=\([0-9][0-9]*\).*/\2 \3/p' | head -1)"
GOT="${SCORE%% *}"; MAX="${SCORE##* }"
PCT=0
if [ -n "$MAX" ] && [ "$MAX" -gt 0 ] 2>/dev/null; then PCT=$(( GOT * 100 / MAX )); fi

awk -F: '$3==0{print $1}' /etc/passwd 2>/dev/null | sort > "$SNAP/uid0.new"
ss -ltnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u > "$SNAP/ports.new"
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] && ssh-keygen -l -f "$f" 2>/dev/null | awk '{print $2}'
done | sort -u > "$SNAP/keys.new"

DRIFT=""
for k in uid0 ports keys; do
    if [ -f "$SNAP/$k.old" ]; then
        ADD="$(comm -13 "$SNAP/$k.old" "$SNAP/$k.new" 2>/dev/null)"
        if [ -n "$ADD" ]; then DRIFT="${DRIFT}
【新增 ${k}】
${ADD}"; fi
    fi
    cp -f "$SNAP/$k.new" "$SNAP/$k.old"
done

PREV="$(cat "$LIB/score.last" 2>/dev/null || echo "$PCT")"
printf '%s\n' "$PCT" > "$LIB/score.last"
DELTA=$(( PCT - PREV ))

{
    printf '# oece-x-blue 每日巡檢 — %s\n\n' "$TODAY"
    printf -- '- 加固評分：**%s/100**（較上次 %+d）\n' "$PCT" "$DELTA"
    printf -- '- 主機：%s\n\n' "$(hostname)"
    if [ -n "$DRIFT" ]; then printf '## 配置漂移\n```%s\n```\n' "$DRIFT"
    else printf '## 無配置漂移\n'; fi
} > "$REPORT"

SUBJ="每日巡檢 ${PCT}/100"
BODY="評分 ${PCT}/100（較上次 ${DELTA}）"
if [ -n "$DRIFT" ]; then
    SUBJ="偵測到配置漂移（${PCT}/100）"
    BODY="${BODY}
${DRIFT}"
fi
if [ "$DELTA" -lt 0 ]; then SUBJ="加固評分下降（${PCT}/100）"; fi
/usr/local/sbin/oece-blue-notify "$SUBJ" "$BODY"
DAILY_EOF
    chmod 700 "$BLUE_DAILY_BIN"

    cat > /etc/cron.d/oece-x-blue <<EOF
# oece-x-blue 每日巡檢（由腳本產生）
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 6 * * * root ${BLUE_DAILY_BIN}
EOF
    ok "已排定每日 06:17 巡檢（/etc/cron.d/oece-x-blue）"
    manifest_add "daily" "每日巡檢 cron + 配置漂移偵測" \
        "rm -f /etc/cron.d/oece-x-blue ${BLUE_DAILY_BIN}"

    printf '\n'
    if confirm "現在立刻跑一次（建立漂移基線）？"; then
        "$BLUE_DAILY_BIN" || true
        ok "報告：${BLUE_LOG}/daily-$(date +%F).md"
        cat "${BLUE_LOG}/daily-$(date +%F).md" 2>/dev/null || true
    fi
}

#=======================================================================
# 模塊 16 · IOC 快檢（唯讀）
#=======================================================================
IOC_HITS=0
ioc_check() {
    local title="$1" found="$2"
    if [ -n "$found" ]; then
        IOC_HITS=$(( IOC_HITS + 1 ))
        printf '\n %s✘ %s%s\n' "$C_RED" "$title" "$C_RESET"
        printf '%s\n' "$found" | head -10 | sed 's/^/     /'
    else
        printf ' %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$title"
    fi
}

module_ioc() {
    section "IOC 快檢 · 入侵指標掃描"
    info "全程唯讀，不改動任何東西。發現異常只提示，由你判斷。"
    IOC_HITS=0

    ioc_check "額外的 uid=0 帳戶" "$(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd 2>/dev/null || true)"
    ioc_check "ld.so.preload 非空" "$(cat /etc/ld.so.preload 2>/dev/null || true)"

    local deleted="" e tgt
    for e in /proc/[0-9]*/exe; do
        tgt="$(readlink "$e" 2>/dev/null || true)"
        case "$tgt" in
            *' (deleted)') deleted="${deleted}pid $(basename "$(dirname "$e")") → ${tgt}
" ;;
        esac
    done
    ioc_check "執行檔已被刪除的進程（挖礦/後門強指標）" "$deleted"

    ioc_check "計劃任務含下載即執行" "$(grep -rlE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh|base64[[:space:]]+-d' \
        /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly \
        /var/spool/cron 2>/dev/null | sort -u || true)"
    ioc_check "臨時目錄中的可執行檔" "$(find /tmp /dev/shm /var/tmp -maxdepth 2 -type f -perm -u+x 2>/dev/null | head -10 || true)"
    ioc_check "空密碼帳戶" "$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null || true)"
    ioc_check "設了 immutable 屬性的檔案" "$(lsattr -R /etc 2>/dev/null | grep -E '^-{4}i' | head -10 || true)"

    printf '\n %s● 全系統公鑰盤點（請逐一確認都是你自己的）%s\n' "$C_CYAN" "$C_RESET"
    local user f keyfiles
    keyfiles="$(list_authkey_files 2>/dev/null || true)"
    if [ -n "$keyfiles" ]; then
        while IFS=$'\t' read -r user f; do
            [ -n "$f" ] || continue
            printf '     %s:\n' "$user"
            ssh-keygen -l -f "$f" 2>/dev/null | sed 's/^/       /' || true
        done <<< "$keyfiles"
    fi

    printf '\n'
    divider
    if [ "$IOC_HITS" -eq 0 ]; then
        ok "未發現明顯入侵指標（不等於絕對安全，只是常見指標都乾淨）"
    else
        err "發現 ${IOC_HITS} 類可疑指標 —— 建議立刻跑「選單 17 · 一鍵取證包」保存證據。"
    fi
}

#=======================================================================
# 模塊 17 · 一鍵取證包
#=======================================================================
module_forensics() {
    section "一鍵取證包"
    info "把事後追查會用到的證據一次打包，全程唯讀。"
    ensure_dirs

    local ts dir tarball
    ts="$(date +%Y%m%d-%H%M%S)"
    dir="${BLUE_BACKUP}/forensics-${ts}"
    mkdir -p "$dir"

    info "採集中…"
    last -50  > "$dir/last.txt" 2>/dev/null || true
    lastb -50 > "$dir/lastb.txt" 2>/dev/null || true
    ss -ltnp  > "$dir/listening.txt" 2>/dev/null || true
    ss -tnp   > "$dir/connections.txt" 2>/dev/null || true
    ps auxf   > "$dir/processes.txt" 2>/dev/null || true
    lsmod     > "$dir/modules.txt" 2>/dev/null || true
    cp -a /etc/passwd /etc/group "$dir/" 2>/dev/null || true
    crontab -l > "$dir/root-crontab.txt" 2>/dev/null || true
    cp -a /etc/crontab "$dir/" 2>/dev/null || true
    cp -a /etc/cron.d  "$dir/cron.d" 2>/dev/null || true
    systemctl list-timers --all --no-pager > "$dir/timers.txt" 2>/dev/null || true
    auth_stream "7 days ago" > "$dir/auth-recent.log" 2>/dev/null || true
    find /etc /usr/bin /usr/sbin -mtime -7 -type f 2>/dev/null | head -200 > "$dir/recent-changes.txt" || true
    if command -v docker >/dev/null 2>&1; then docker ps -a > "$dir/docker.txt" 2>/dev/null || true; fi
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        if [ -f "$f" ]; then
            printf '== %s ==\n' "$f"
            ssh-keygen -l -f "$f" 2>/dev/null || true
        fi
    done > "$dir/authorized_keys.txt" 2>/dev/null || true
    if command -v debsums >/dev/null 2>&1; then debsums -c > "$dir/pkg-integrity.txt" 2>&1 || true
    elif command -v rpm >/dev/null 2>&1; then rpm -Va > "$dir/pkg-integrity.txt" 2>&1 || true
    fi

    # markdown 圍欄用變數傳入：直接寫在單引號格式字串裡會被 shellcheck
    # 誤判成命令替換（SC2016）
    local fence='```'
    {
        printf '# oece-x-blue 取證報告\n\n'
        printf -- '- 主機：%s\n' "$(hostname)"
        printf -- '- 採集時間：%s\n' "$(date -Is)"
        printf -- '- 核心：%s\n\n' "$(uname -a)"
        printf '## 當前登入\n%s\n%s\n%s\n\n'   "$fence" "$(who 2>/dev/null)" "$fence"
        printf '## 監聽埠\n%s\n%s\n%s\n\n'     "$fence" "$(ss -ltnp 2>/dev/null | head -20)" "$fence"
        printf '## uid=0 帳戶\n%s\n%s\n%s\n\n' "$fence" "$(awk -F: '$3==0{print $1}' /etc/passwd)" "$fence"
        printf '## 包含檔案\n%s\n%s\n%s\n'      "$fence" "$(ls -1 "$dir")" "$fence"
    } > "$dir/REPORT.md"

    tarball="${BLUE_BACKUP}/forensics-${ts}.tar.gz"
    tar -czf "$tarball" -C "$BLUE_BACKUP" "forensics-${ts}" 2>/dev/null || true
    rm -rf "$dir"
    chmod 600 "$tarball" 2>/dev/null || true

    ok "取證包已產生：${tarball}"
    kv "大小" "$(du -h "$tarball" 2>/dev/null | awk '{print $1}')"
    info "下載到本機：scp <你的帳戶>@<IP>:${tarball} ."
}

#=======================================================================
# 模塊 18 · 封禁 / 解封 / 踢人
#=======================================================================
module_ban() {
    section "封禁 / 解封 / 踢人"
    printf ' 1) 封禁一個 IP\n 2) 解封一個 IP\n 3) 查看已封禁清單\n 4) 踢掉登入中的會話\n 0) 返回\n\n請選擇: '
    local c ip tty
    read -r c || c="0"
    case "$c" in
        1)
            printf '要封禁的 IP: '; read -r ip || ip=""
            [ -z "$ip" ] && return 1
            if ! is_ip "$ip"; then err "只接受單一 IPv4 / IPv6，已拒絕。"; return 1; fi
            local self_ip
            self_ip="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1}')"
            if [ -n "$self_ip" ] && [ "$ip" = "$self_ip" ]; then
                err "拒絕封禁當前 SSH 來源 ${self_ip}。這會立刻把自己鎖在門外。"
                return 1
            fi
            confirm_danger "封禁 ${ip}" || return 0
            if command -v cscli >/dev/null 2>&1; then
                cscli decisions add --ip "$ip" --duration 168h --reason "manual (oece-blue)" >/dev/null 2>&1 \
                    && ok "CrowdSec 已封禁 ${ip} 7 天"
            elif command -v fail2ban-client >/dev/null 2>&1; then
                fail2ban-client set sshd banip "$ip" >/dev/null 2>&1 && ok "fail2ban 已封禁 ${ip}"
            elif command -v ufw >/dev/null 2>&1; then
                ufw insert 1 deny from "$ip" >/dev/null 2>&1 && ok "UFW 已封禁 ${ip}"
            else
                err "沒有可用的封禁工具。"
            fi
            ;;
        2)
            printf '要解封的 IP: '; read -r ip || ip=""
            [ -z "$ip" ] && return 1
            if ! is_ip "$ip"; then err "只接受單一 IPv4 / IPv6，已拒絕。"; return 1; fi
            command -v cscli >/dev/null 2>&1 && cscli decisions delete --ip "$ip" >/dev/null 2>&1
            command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1
            command -v ufw >/dev/null 2>&1 && ufw delete deny from "$ip" >/dev/null 2>&1
            ok "已嘗試從所有可用工具解封 ${ip}"
            ;;
        3)
            if command -v cscli >/dev/null 2>&1; then
                cscli decisions list 2>/dev/null | head -30
            elif command -v fail2ban-client >/dev/null 2>&1; then
                fail2ban-client status sshd 2>/dev/null || true
                fail2ban-client status oece-honeypot 2>/dev/null || true
            else
                warn "未安裝封禁工具。"
            fi
            ;;
        4)
            who 2>/dev/null || true
            printf '\n要踢掉的 TTY（例如 pts/1）: '; read -r tty || tty=""
            [ -z "$tty" ] && return 1
            case "$tty" in
                pts/[0-9]|pts/[0-9][0-9]|tty[0-9]|tty[0-9][0-9]|console) : ;;
                *) err "TTY 格式無效，已拒絕。"; return 1 ;;
            esac
            if pkill -9 -t "$tty"; then ok "已踢掉 ${tty}"; else warn "找不到該會話"; fi
            ;;
        *) return 0 ;;
    esac
}

#=======================================================================
# 模塊 19 · 緊急鎖定
#=======================================================================
module_lockdown() {
    section "緊急鎖定"
    warn "只放行你「當前這個 IP」的 SSH，其餘全部封鎖。用於正在被攻擊時爭取時間。"

    local src_ip cur_port bk
    src_ip="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1}')"
    if [ -z "$src_ip" ]; then
        err "偵測不到當前 SSH 來源 IP（你可能在主控台）。緊急鎖定需從 SSH 執行。"
        return 1
    fi
    if ! is_ip "$src_ip"; then
        err "來源位址不是單一 IP，拒絕套用緊急鎖定。"
        return 1
    fi
    kv "你的來源 IP" "$src_ip"
    cur_port="$(sshd_val port)"; [ -z "$cur_port" ] && cur_port=22

    local extra=""
    if command -v ss >/dev/null 2>&1; then
        extra="$(ss -ltnH 2>/dev/null | awk '{addr=$4; sub(/\]$/,"",addr); n=split(addr,a,":"); print a[n]}' \
            | grep -E '^[0-9]+$' | sort -u | grep -vxE "^(${cur_port}|80|443)$" | tr '\n' ' ' || true)"
    fi
    printf '\n'
    warn "套用後：SSH 只放行 ${src_ip}；80/443 仍對公網開放，避免把網站一起打死。"
    [ -n "$extra" ] && warn "這些對外埠將被關閉：${extra}"
    warn "如果你的 IP 會變動（家用寬頻 / 行動網路），你可能會失聯。"
    if [ -f "$BLUE_BACKUP" ] || command -v ufw >/dev/null 2>&1; then
        info "現有 UFW 規則會先備份，再 reset。回滾窗口內未確認會還原。"
    fi
    confirm_danger "確認緊急鎖定？（${ROLLBACK_MINUTES} 分鐘內未確認將自動還原）" || return 0

    command -v ufw >/dev/null 2>&1 || pkg_install ufw || { err "需要 ufw"; return 1; }
    bk="$(backup_create)" || return 1
    arm_rollback "$ROLLBACK_MINUTES" "$bk" || return 1

    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming  >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow from "$src_ip" to any port "$cur_port" proto tcp comment 'EMERGENCY (oece-blue)' >/dev/null 2>&1
    ufw allow 80/tcp comment 'EMERGENCY keep http' >/dev/null 2>&1 || true
    ufw allow 443/tcp comment 'EMERGENCY keep https' >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1

    ok "緊急鎖定已生效 —— 只有 ${src_ip} 能連 ${cur_port} 埠；80/443 仍開放"
    manifest_add "lockdown" "緊急鎖定（SSH 僅 ${src_ip}，保留 80/443）" "ufw --force disable"
    blue_notify "緊急鎖定已啟用" "只放行 ${src_ip} 連接 ${cur_port} 埠。"
    ufw status verbose 2>/dev/null | head -12 || true
    post_harden_notice "$ROLLBACK_MINUTES" "$cur_port" ""
}

#=======================================================================
# 開場動畫
#=======================================================================
anim_enabled() {
    [ -t 1 ] || return 1
    [ -z "${OECE_NO_ANIM:-}" ] || return 1
    [ -z "${OECE_FAST:-}" ] || return 1
    return 0
}

print_banner_static() {
    printf '%s%s' "$C_BLUE" "$C_BOLD"
    cat <<'BANNER'
  ___  ___ ___ ___   __  __  ___ _   _   _ ___
 / _ \| __/ __| __| \ \/ / | _ ) | | | | | __|
| (_) | _| (__| _|   >  <  | _ \ |_| |_| | _|
 \___/|___\___|___| /_/\_\ |___/____|___|___|
BANNER
    printf '%s' "$C_RESET"
    printf '%s  oece-x-blue.sh v%s · %s%s\n' "$C_DIM" "$SCRIPT_VERSION" "$(t banner.tagline)" "$C_RESET"
    printf '%s  YouTube @oece-x · oece-x.com · bash <(curl -sL oece-x.com/b)%s\n' "$C_DIM" "$C_RESET"
}

intro_animation() {
    anim_enabled || return 0
    printf '\033[?25l' 2>/dev/null || true
    # anim_enabled 已保證是 TTY，此處可安全使用游標控制
    local msgs=(
        "載入藍隊規則庫…"
        "讀取 sshd 有效配置…"
        "盤點公鑰與特權帳戶…"
        "掃描對外暴露面…"
    )
    local m
    for m in "${msgs[@]}"; do
        printf '\r%s  ▸ %s%s' "$C_DIM" "$m" "$C_RESET"
        sleep 0.18 2>/dev/null || true
    done
    printf '\r%*s\r' 60 ""
    printf '\033[?25h' 2>/dev/null || true
}

#=======================================================================
# 模塊 6 · 一鍵加固 · 硬核
#   組合流程：標準加固（若尚未做）→ 指定管理員 → 蜜罐 → 可選改埠。
#   每一步都是既有函式。改 SSH / 帳戶的步驟自己會 preflight + 回滾。
#   不在這裡另寫一套 sshd 規則，避免和選單 5 / 10 / 12 分叉。
#=======================================================================
module_harden_hardcore() {
    section "一鍵加固 · 硬核"
    info "這是組合流程，不是另一套規則。順序固定，任一步取消就停在已完成的那一步。"
    printf '\n'
    printf ' 1) 標準加固（SSH 收緊 + UFW + fail2ban）—— 若 drop-in 已在則跳過\n'
    printf ' 2) root 蜜罐（真管理員換人、誘餌用戶名、秒封）\n'
    printf ' 3) 可選：把 SSH 搬離 22（之後才能裝 endlessh）\n'
    printf '\n'
    warn "步驟 2、3 會動 SSH。每一步自己掛回滾定時器。不要在生產機上跑。"
    confirm_danger "開始硬核組合？（可在每一步再取消）" || return 0

    if [ -f "$BLUE_SSHD_DROPIN" ] && grep -q '^PasswordAuthentication no' "$BLUE_SSHD_DROPIN" 2>/dev/null; then
        info "已有標準加固 drop-in，跳過步驟 1。若要重做，先用選單 20 還原。"
    else
        # 標準加固在套用前會問一次。取消、帳戶不存在或前置檢查失敗都回 1。
        # 組合流程必須停住，不能把「使用者取消」當成已完成再去跑蜜罐。
        if ! module_harden_standard; then
            warn "標準加固未完成，硬核組合停在這裡。蜜罐與改埠未動。"
            return 1
        fi
        if rollback_pending; then
            warn "標準加固還在等待確認。請另開終端登入並執行 --confirm，再回來跑蜜罐。"
            return 0
        fi
    fi

    printf '\n'
    info "下一步：root 蜜罐。沒有非 root 管理員公鑰就會在 preflight 停住。"
    if ! confirm "繼續安裝 root 蜜罐？"; then
        info "已停在標準加固。蜜罐與改埠未動。"
        return 0
    fi
    module_honeypot || return 1
    if rollback_pending; then
        warn "蜜罐還在等待確認。確認登入後再改埠，不要疊兩個未確認的回滾點。"
        return 0
    fi

    printf '\n'
    if confirm "要把 SSH 搬離 22 嗎？（不確定就選 N；endlessh 需要這一步）"; then
        change_ssh_port || return 1
    else
        info "保留目前 SSH 埠。endlessh 請等真 SSH 離開 22 再裝。"
    fi
    ok "硬核組合跑完已確認的步驟。未確認的變更仍掛在回滾定時器上。"
}

#=======================================================================
# 模塊 7 · 逐項加固
#   只呼叫已經存在的套用函式。動 SSH 的項目必須先過 preflight 並武裝回滾。
#=======================================================================
# 路徑寫到呼叫端傳入的變數名。訊息走終端，不混進回傳值。
cherry_needs_rollback() {
    local __out="$1" bk
    if rollback_pending; then
        warn "已有等待確認的加固。先到選單 20 確認或還原，再逐項改 SSH。"
        return 1
    fi
    harden_preflight || return 1
    bk="$(backup_create)"
    arm_rollback "$ROLLBACK_MINUTES" "$bk" || return 1
    ok "回滾點：${bk}"
    printf -v "$__out" '%s' "$bk"
}

module_cherry_pick() {
    section "逐項加固"
    info "每一項都是選單 4/5 裡已經在用的動作。動 SSH 的項目會先做前置檢查並掛回滾。"
    printf '\n'
    printf ' 1) 自動安全更新\n'
    printf ' 2) sysctl（13 項）\n'
    printf ' 3) /dev/shm noexec,nosuid,nodev\n'
    printf ' 4) 停用 core dump\n'
    printf ' 5) SSH：禁用密碼登入（掛回滾）\n'
    printf ' 6) SSH：MaxAuthTries 3 + LoginGraceTime 20（掛回滾）\n'
    printf ' 7) SSH：關閉 X11 / Agent 轉發（掛回滾）\n'
    printf ' 0) 返回\n\n請選擇: '
    local c bk
    read -r c || c="0"
    case "$c" in
        1) apply_auto_updates || return 1 ;;
        2) apply_sysctl_hardening ;;
        3) apply_shm_hardening ;;
        4) apply_coredump_off ;;
        5)
            confirm_danger "禁用密碼與鍵盤互動登入，root 僅金鑰" || return 0
            cherry_needs_rollback bk || return 1
            ensure_sshd_include || true
            sshd_set PasswordAuthentication no
            sshd_set KbdInteractiveAuthentication no
            sshd_set PermitRootLogin prohibit-password
            sshd_set PermitEmptyPasswords no
            if ! sshd_validate_reload; then
                blue_rollback_now "$bk"
                return 1
            fi
            manifest_add "sshd-nopass" "禁用密碼登入" \
                "rm -f ${BLUE_SSHD_DROPIN} && systemctl reload sshd"
            post_harden_notice "$ROLLBACK_MINUTES" "" ""
            ;;
        6)
            confirm_danger "MaxAuthTries 3、LoginGraceTime 20" || return 0
            cherry_needs_rollback bk || return 1
            ensure_sshd_include || true
            sshd_set MaxAuthTries 3
            sshd_set LoginGraceTime 20
            if ! sshd_validate_reload; then
                blue_rollback_now "$bk"
                return 1
            fi
            manifest_add "sshd-tries" "收緊認證次數與寬限時間" \
                "rm -f ${BLUE_SSHD_DROPIN} && systemctl reload sshd"
            post_harden_notice "$ROLLBACK_MINUTES" "" ""
            ;;
        7)
            confirm_danger "關閉 X11Forwarding 與 AllowAgentForwarding" || return 0
            cherry_needs_rollback bk || return 1
            ensure_sshd_include || true
            sshd_set X11Forwarding no
            sshd_set AllowAgentForwarding no
            sshd_set ClientAliveInterval 300
            sshd_set ClientAliveCountMax 2
            if ! sshd_validate_reload; then
                blue_rollback_now "$bk"
                return 1
            fi
            manifest_add "sshd-forward" "關閉 X11 / Agent 轉發" \
                "rm -f ${BLUE_SSHD_DROPIN} && systemctl reload sshd"
            post_harden_notice "$ROLLBACK_MINUTES" "" ""
            ;;
        *) return 0 ;;
    esac
    ok "該項已處理。其餘項目未動。"
}

#=======================================================================
# --demo · 免 root 只讀沙盒
#   與 guard-demo.oece-x.com 共用 DO SGP1 與 57/75/83 三檔。
#   不寫磁碟，不讀本機 sshd / 防火牆。
#=======================================================================
demo_baseline() {
    case "$1" in
        57) printf '57 18 3 6 3 5 3 6 1 4 4 6 4 5' ;;
        75) printf '75 24 5 6 5 5 4 6 2 4 4 6 4 5' ;;
        83) printf '83 27 5 6 5 5 5 6 4 4 4 6 4 5' ;;
        *) return 1 ;;
    esac
}

demo_emit_json() {
    local row score passed
    row="$(demo_baseline "$DEMO_SCORE")" || return 1
    # shellcheck disable=SC2086
    set -- $row
    score="$1"; passed="$2"
    emit_audit_json "DO SGP1" "DigitalOcean · Singapore" "$score" "$passed" \
        "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}"
}

demo_print_panel() {
    local row score passed
    row="$(demo_baseline "$DEMO_SCORE")" || return 1
    # shellcheck disable=SC2086
    set -- $row
    score="$1"; passed="$2"
    printf '\n'
    printf '%sDO SGP1%s  DigitalOcean · Singapore\n' "$C_BOLD" "$C_RESET"
    printf '%s只讀沙盒%s  對齊 https://guard-demo.oece-x.com  不寫本機\n' "$C_DIM" "$C_RESET"
    divider
    printf ' 分數 %s%s%s/100   通過 %s/32\n' "$C_BOLD" "$score" "$C_RESET" "$passed"
    printf ' SSH %s/%s   FW %s/%s   IPS %s/%s\n' "$3" "$4" "$5" "$6" "$7" "$8"
    printf ' TRAP %s/%s  KERN %s/%s  AUD %s/%s\n' "$9" "${10}" "${11}" "${12}" "${13}" "${14}"
    divider
    printf ' 威脅樣例（RFC 5737，不是真實主機）\n'
    printf '  203.0.113.18    ssh root     honeypot hit\n'
    printf '  198.51.100.41   ssh root     honeypot hit\n'
    printf '  192.0.2.73      nginx        denied\n'
    printf '  endlessh tarpit  port 22 held  00:14:22\n'
    divider
}

demo_rollback_drill() {
    local left=10 reply=""
    warn "模擬掛載 10 秒自動回滾。不會建立定時器，也不會改系統。"
    printf '輸入 yes 確認連通性並鎖定 83 分。逾時則模擬還原到 57。\n'
    while [ "$left" -gt 0 ]; do
        printf '\r  回滾倒數 %2ss  輸入 yes: ' "$left"
        if read -r -t 1 reply; then
            break
        fi
        left=$(( left - 1 ))
        reply=""
    done
    printf '\n'
    case "$reply" in
        yes|YES)
            DEMO_SCORE=83
            ok "已取消模擬回滾，基線鎖定在 83。"
            ;;
        *)
            DEMO_SCORE=57
            warn "未確認。模擬還原完成，基線回到 57。"
            ;;
    esac
}

module_demo() {
    local choice=""
    demo_baseline "$DEMO_SCORE" >/dev/null || { err "沙盒分數只接受 57、75、83。"; return 1; }
    if [ "$AUDIT_JSON" -eq 1 ]; then
        demo_emit_json
        return 0
    fi
    while true; do
        demo_print_panel
        printf ' 1) 基線 57   2) 基線 75   3) 基線 83\n'
        printf ' 4) 防鎖門演練（倒數 → yes → 鎖定 83）\n'
        printf ' 5) 印出 JSON\n'
        printf ' 0) 離開沙盒\n'
        printf '請選擇: '
        if ! read -r choice; then
            printf '\n'
            break
        fi
        case "$choice" in
            1) DEMO_SCORE=57 ;;
            2) DEMO_SCORE=75 ;;
            3) DEMO_SCORE=83 ;;
            4) demo_rollback_drill ;;
            5) demo_emit_json ;;
            0) break ;;
            *) warn "無效選項：${choice}" ;;
        esac
    done
}

offer_demo_instead_of_root() {
    local reply=""
    warn "這台環境沒有 root，或是 macOS。加固選單需要 Linux root。"
    info "可以進入 --demo：DO SGP1 只讀沙盒，57 / 75 / 83，不改任何檔案。"
    info "線上同一套模型：https://guard-demo.oece-x.com"
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        info "非互動環境不自動進入沙盒。請執行：bash oece-x-blue.sh --demo"
        return 0
    fi
    printf '進入只讀沙盒？[Y/n] '
    read -r reply || reply=""
    case "$reply" in
        n|N|no|NO) info "已取消。"; return 0 ;;
        *) module_demo ;;
    esac
}

#=======================================================================
# 模塊 21 · 檢查更新
#   只比對 SCRIPT_VERSION。不自動覆蓋本機腳本：官網 /b 與 GitHub raw
#   都還沒有發布 SHA256，自動替換會變成未校驗的 curl|bash。
#=======================================================================
module_self_update() {
    section "檢查更新"
    info "只讀遠端版本號，不下載安裝、不覆蓋本機檔案。"
    kv "本機版本" "$SCRIPT_VERSION"
    kv "比對來源" "$SCRIPT_RAW_URL"

    if ! command -v curl >/dev/null 2>&1; then
        err "沒有 curl，無法比對。請先安裝 curl，或看 GitHub releases。"
        return 1
    fi

    local remote
    remote="$(curl "${CURL_OPTS[@]}" --max-time 15 "$SCRIPT_RAW_URL" 2>/dev/null \
        | sed -n 's/^SCRIPT_VERSION="\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' \
        | head -1 || true)"
    if [ -z "$remote" ]; then
        err "讀不到遠端 SCRIPT_VERSION。網路、GitHub 或原始檔格式有問題。本機檔案未改。"
        return 1
    fi
    kv "遠端版本" "$remote"

    if [ "$remote" = "$SCRIPT_VERSION" ]; then
        ok "已是遠端 main 上的同一版本。"
        return 0
    fi
    if version_lt "$SCRIPT_VERSION" "$remote"; then
        warn "遠端較新（${remote}）。本工具不會自動覆蓋。"
        printf '\n'
        info "要升級：下載該檔、核對你信任的 SHA256、再替換本機副本。"
        info "在 SHA256 發布之前，不要用 curl | bash 當已校驗安裝。"
        printf '  %s\n' "$SCRIPT_RAW_URL"
        return 0
    fi
    info "本機 ${SCRIPT_VERSION} 比遠端 main ${remote} 新（常見於尚未發布的工作副本）。未改檔案。"
}

#=======================================================================
# 主選單
#=======================================================================

# 有待確認的加固時，在選單頂部持續提醒
pending_banner() {
    rollback_pending || return 0
    printf '%s%s ⚠ 有加固操作等待確認 —— 若你已能正常登入，請進「選單 20 → 1」確認保留，%s\n' \
        "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%s%s   否則設定將自動還原。%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
}

main_menu() {
    while true; do
        printf '\n'
        print_banner_static
        divider
        pending_banner
        menu_group "$(t group.vis)"
        menu_item 1 "$(t menu.1)" "$(t menu.1h)" 1
        menu_item 2 "$(t menu.2)" "$(t menu.2h)" 1
        menu_item 3 "$(t menu.3)" "$(t menu.3h)"
        menu_group "$(t group.harden)"
        menu_item 4 "$(t menu.4)" "$(t menu.4h)" 1
        menu_item 5 "$(t menu.5)" "$(t menu.5h)" 1
        menu_item 6 "$(t menu.6)" "$(t menu.6h)"
        menu_item 7 "$(t menu.7)" "$(t menu.7h)"
        menu_group "$(t group.defense)"
        menu_item 8 "$(t menu.8)" "$(t menu.8h)" 1
        menu_item 9 "$(t menu.9)" "$(t menu.9h)"
        menu_item 10 "$(t menu.10)" "$(t menu.10h)" 1
        menu_item 11 "$(t menu.11)" "$(t menu.11h)" 1
        menu_item 12 "$(t menu.12)" "$(t menu.12h)" 1
        menu_group "$(t group.alert)"
        menu_item 13 "$(t menu.13)" "$(t menu.13h)"
        menu_item 14 "$(t menu.14)" "$(t menu.14h)" 1
        menu_item 15 "$(t menu.15)" "$(t menu.15h)"
        menu_group "$(t group.response)"
        menu_item 16 "$(t menu.16)" "$(t menu.16h)" 1
        menu_item 17 "$(t menu.17)" "$(t menu.17h)"
        menu_item 18 "$(t menu.18)"
        menu_item 19 "$(t menu.19)" "$(t menu.19h)"
        menu_group "$(t group.system)"
        menu_item 20 "$(t menu.20)" "$(t menu.20h)"
        menu_item 21 "$(t menu.21)" "$(t menu.21h)"
        menu_item 0 "$(t menu.0)"
        divider
        printf '%s' "$(t menu.ask)"

        local choice
        read -r choice || { printf '\n'; break; }
        case "$choice" in
            # 模塊回傳非 0 代表「使用者取消」或「前置檢查未通過」，
            # 那是正常流程，不該觸發 ERR trap 印出「內部錯誤」。
            1)  module_panel            || true ;;
            2)  module_audit            || true; pause ;;
            3)  module_lynis            || true; pause ;;
            4)  module_harden_basic     || true; pause ;;
            5)  require_durable_script && module_harden_standard || true; pause ;;
            6)  require_durable_script && module_harden_hardcore || true; pause ;;
            7)  require_durable_script && module_cherry_pick || true; pause ;;
            8)  require_durable_script && module_crowdsec || true; pause ;;
            9)  require_durable_script && module_fail2ban || true; pause ;;
            10) require_durable_script && module_honeypot || true; pause ;;
            11) require_durable_script && module_endlessh || true; pause ;;
            12) require_durable_script && module_firewall || true; pause ;;
            13) module_alerts_config    || true; pause ;;
            14) require_durable_script && module_login_alert || true; pause ;;
            15) module_daily_report     || true; pause ;;
            16) module_ioc              || true; pause ;;
            17) module_forensics        || true; pause ;;
            18) module_ban              || true; pause ;;
            19) require_durable_script && module_lockdown || true; pause ;;
            20) module_rollback         || true; pause ;;
            21) module_self_update      || true; pause ;;
            0)  info "$(t menu.exit)"; break ;;
            *)  warn "$(printf "$(t menu.invalid)" "$choice")" ;;
        esac
    done
}

usage() {
    cat <<EOF
oece-x-blue.sh v${SCRIPT_VERSION} — VPS blue-team panel / 藍隊加固面板

用法 / Usage:
  bash oece-x-blue.sh                 互動選單 / interactive menu
  bash oece-x-blue.sh --panel         面板 / live panel
  bash oece-x-blue.sh --audit         評分 / score (cron-safe)
  bash oece-x-blue.sh --audit --json  機器可讀 JSON / machine-readable JSON
  bash oece-x-blue.sh --demo          免 root 沙盒 / rootless DO SGP1 sandbox
  bash oece-x-blue.sh --demo --audit --json
  bash oece-x-blue.sh --confirm       確認保留 / cancel rollback timer
  bash oece-x-blue.sh --rollback      立即還原 / restore now
  bash oece-x-blue.sh --lang zh-Hant  繁體中文
  bash oece-x-blue.sh --lang en       English
  bash oece-x-blue.sh --dry-run       只印計畫 / print the plan
  bash oece-x-blue.sh --version
  bash oece-x-blue.sh --help
  OECE_LANG=en OECE_NO_ANIM=1 bash oece-x-blue.sh

語言 / Language:
  --lang 與 OECE_LANG 優先。其次讀 /etc/oece-x/lang。
  LANG=zh_CN 與其他 zh* 一律使用繁體。en* 使用 English。
  首次互動且沒有偏好檔時，會先詢問一次。

一鍵執行（未校驗便利入口，正式環境請先下載再核對 SHA256）:
  bash <(curl -sL oece-x.com/b)

防禦性運維工具。不含代理或繞過封鎖功能。
蜜罐資料只留本機。CrowdSec 社群情報預設關閉。
EOF
}

bootstrap() {
    require_root
    detect_os
    detect_arch
    detect_auth_log
    init_sshd_source
    ensure_dirs
}

apply_lang_arg() {
    local hit
    hit="$(normalize_lang "$1")"
    if [ -z "$hit" ]; then
        printf 'unknown language: %s (use zh-Hant or en)\n' "$1" >&2
        exit 1
    fi
    UI_LANG="$hit"
    OECE_LANG="$hit"
    export OECE_LANG
}

can_run_live_menu() {
    [ "$(uname -s 2>/dev/null || echo unknown)" = "Linux" ] || return 1
    [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]
}

main() {
    local interactive=1 mode="" want_demo=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --version|-v) printf 'oece-x-blue.sh v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            --help|-h)    usage; exit 0 ;;
            --lang)
                shift
                [ $# -gt 0 ] || { usage; exit 1; }
                apply_lang_arg "$1"
                ;;
            --lang=*)
                apply_lang_arg "${1#--lang=}"
                ;;
            --dry-run) DRY_RUN=1 ;;
            --json) AUDIT_JSON=1 ;;
            --demo) want_demo=1 ;;
            --score)
                shift
                [ $# -gt 0 ] || { usage; exit 1; }
                DEMO_SCORE="$1"
                ;;
            --score=*) DEMO_SCORE="${1#--score=}" ;;
            --audit) mode="audit"; interactive=0 ;;
            --panel) mode="panel"; interactive=0 ;;
            --confirm) mode="confirm"; interactive=0 ;;
            --rollback) mode="rollback"; interactive=0 ;;
            "") break ;;
            *) usage; exit 1 ;;
        esac
        shift
    done
    UI_LANG="$(resolve_lang)"

    if [ "$want_demo" -eq 1 ]; then
        if [ "$mode" = "audit" ]; then
            demo_baseline "$DEMO_SCORE" >/dev/null || { err "沙盒分數只接受 57、75、83。"; exit 1; }
            if [ "$AUDIT_JSON" -eq 1 ]; then
                demo_emit_json
            else
                demo_print_panel
            fi
            exit 0
        fi
        module_demo
        exit $?
    fi

    case "$mode" in
        audit)    bootstrap; module_audit; exit 0 ;;
        panel)    bootstrap; module_panel; exit 0 ;;
        confirm)  bootstrap; blue_confirm; exit 0 ;;
        rollback) bootstrap; blue_rollback_now; exit 0 ;;
        "")       : ;;
        *)        usage; exit 1 ;;
    esac

    if ! can_run_live_menu; then
        offer_demo_instead_of_root
        exit 0
    fi

    bootstrap
    if [ "$interactive" -eq 1 ]; then
        prompt_lang_if_needed
        UI_LANG="$(resolve_lang)"
    fi
    ensure_deps
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "$(printf "$(t dryrun)" "interactive session (writes are skipped where guarded)")"
    fi
    intro_animation
    main_menu
}

main "$@"

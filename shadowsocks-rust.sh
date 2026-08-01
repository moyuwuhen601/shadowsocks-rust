#!/usr/bin/env bash

# ==================================================
# Shadowsocks-Rust 一键管理脚本 (Ultimate Edition)
# Author: MoyuWuhen & Gemini
# Github: https://github.com/moyuwuhen601/shadowsocks-rust
# ==================================================

# 不使用 set -e：这是交互式管理脚本，单个菜单操作失败时应返回菜单；
# 关键步骤在各函数中显式检查并返回非零状态。
set -o pipefail

# --- 基础设置 ---
VERSION="2.2.0"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="$CONFIG_DIR/config.json"
REMARKS_FILE="$CONFIG_DIR/remarks"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
BIN_PATH="/usr/local/bin/ssserver"
SERVICE_USER="shadowsocks-rust"
SERVICE_GROUP="shadowsocks-rust"
STATE_DIR="/var/lib/shadowsocks-rust"
MANAGED_USER_MARKER="$STATE_DIR/managed-user"
MANAGED_GROUP_MARKER="$STATE_DIR/managed-group"
CORE_BACKUP_PATH="${BIN_PATH}.previous"
TMP_DIR=""
CONFIG_TXN_DIR=""
CONFIG_TXN_ACTIVE=0
CONFIG_SERVICE_WAS_ACTIVE=0
CONFIG_SERVICE_WAS_ENABLED=0
CORE_INSTALLED_THIS_RUN=0
CORE_HAD_PREVIOUS=0

# --- 颜色定义 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PURPLE="\033[35m"
PLAIN="\033[0m"

# --- 辅助函数 ---
print_line() { echo -e "${BLUE}------------------------------------------------------${PLAIN}"; }
print_ok() { echo -e "${GREEN}[OK]${PLAIN} $1"; }
print_err() { echo -e "${RED}[ERROR]${PLAIN} $1"; }
print_info() { echo -e "${YELLOW}[INFO]${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }

# --- 退出清理 ---
cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

handle_exit() {
    if (( CONFIG_TXN_ACTIVE )); then
        rollback_config_transaction >/dev/null 2>&1 || true
    elif (( CORE_INSTALLED_THIS_RUN )); then
        rollback_core_update >/dev/null 2>&1 || true
    fi
    cleanup
}

prompt_input() {
    local target=$1 prompt=$2

    if ! IFS= read -r -p "$prompt" "${target?}"; then
        echo ""
        print_warn "输入已中断，本次操作已取消。"
        return 1
    fi
}

preflight() {
    if [[ $EUID -ne 0 ]]; then
        print_err "必须使用 root 用户运行此脚本！"
        return 1
    fi
    if [[ ! -t 0 ]]; then
        print_err "这是交互式脚本，请在终端中直接运行，不要通过管道执行。"
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1 || \
        [[ ! -d /run/systemd/system ]] || \
        ! systemctl show --property=Version --value >/dev/null 2>&1; then
        print_err "当前环境没有正在运行的 systemd，无法安装本服务。"
        return 1
    fi
}

# --- 获取系统架构 ---
check_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) RUST_ARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) RUST_ARCH="aarch64-unknown-linux-gnu" ;;
        armv7l) RUST_ARCH="armv7-unknown-linux-gnueabihf" ;;
        i386|i486|i586|i686) RUST_ARCH="i686-unknown-linux-musl" ;;
        loongarch64) RUST_ARCH="loongarch64-unknown-linux-gnu" ;;
        riscv64) RUST_ARCH="riscv64gc-unknown-linux-gnu" ;;
        *) print_err "不支持的架构: $arch"; return 1 ;;
    esac
}

# --- 时间同步（SS2022 要求两端时间误差不能过大） ---
sync_time() {
    print_info "正在启用系统时间同步（不会修改当前时区）..."

    if ! command -v timedatectl >/dev/null 2>&1; then
        print_warn "未找到 timedatectl，请自行确认系统已通过 NTP 同步时间。"
        return 0
    fi

    if ! timedatectl set-ntp true >/dev/null 2>&1; then
        print_warn "无法自动启用 NTP，请自行确认 chrony、ntpd 或其他时间同步服务正常。"
        return 0
    fi

    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
        print_ok "系统时间已同步，当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    else
        print_warn "NTP 已启用但暂未确认同步；若使用 SS2022，请先确认服务器时间准确。"
    fi
}

# --- 安装依赖 ---
install_deps() {
    local command_name missing=()

    print_info "正在检查并安装依赖..."

    for command_name in curl jq tar xz qrencode openssl lsof sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if (( ${#missing[@]} == 0 )); then
        print_ok "依赖已满足，无需重复安装"
        return 0
    fi

    print_info "缺少命令: ${missing[*]}"

    if ! command -v apt-get >/dev/null 2>&1; then
        print_err "当前版本仅支持使用 apt 的 Debian/Ubuntu 系统。"
        return 1
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get update -q; then
        print_err "软件源更新失败，请检查网络或 apt 源。"
        return 1
    fi

    # xz-utils 是解压官方 .tar.xz 发布包所必需的；旧版遗漏它会导致
    # tar 解压失败，随后 service 因找不到 ssserver 报 203/EXEC。
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        ca-certificates coreutils curl jq tar xz-utils qrencode openssl lsof; then
        print_err "依赖安装失败。"
        return 1
    fi

    print_ok "依赖安装完成"
}

# --- 内核事务与安装/更新 ---
commit_core_update() {
    rm -f "$CORE_BACKUP_PATH"
    CORE_INSTALLED_THIS_RUN=0
    CORE_HAD_PREVIOUS=0
}

rollback_core_update() {
    if (( ! CORE_INSTALLED_THIS_RUN )); then
        return 0
    fi

    if (( CORE_HAD_PREVIOUS )) && [[ -f "$CORE_BACKUP_PATH" ]]; then
        if ! mv -f "$CORE_BACKUP_PATH" "$BIN_PATH"; then
            print_err "旧内核自动回滚失败：$CORE_BACKUP_PATH"
            return 1
        fi
        print_warn "已自动恢复更新前的 ssserver。"
    else
        rm -f "$BIN_PATH" "$CORE_BACKUP_PATH"
        print_warn "已移除本次未能正常启用的 ssserver。"
    fi

    CORE_INSTALLED_THIS_RUN=0
    CORE_HAD_PREVIOUS=0
}

install_core() {
    local release_json tag asset_name asset_url checksum_url
    local archive checksum_file extract_dir expected_sha actual_version

    check_arch || return 1
    print_info "正在查询 GitHub 最新版本..."

    cleanup
    TMP_DIR=$(mktemp -d /tmp/shadowsocks-rust.XXXXXX) || {
        print_err "无法创建临时目录。"
        return 1
    }
    chmod 700 "$TMP_DIR"
    release_json="$TMP_DIR/release.json"
    archive="$TMP_DIR/shadowsocks-rust.tar.xz"
    checksum_file="$TMP_DIR/shadowsocks-rust.tar.xz.sha256"
    extract_dir="$TMP_DIR/extract"
    mkdir -p "$extract_dir"

    if ! curl --fail --silent --show-error --location \
        --connect-timeout 10 --max-time 60 \
        -o "$release_json" \
        "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"; then
        print_err "无法查询 GitHub 最新版本，请检查网络连接或 API 限流。"
        return 1
    fi

    if ! tag=$(jq -er '.tag_name' "$release_json"); then
        print_err "GitHub 返回的数据中没有有效版本号。"
        return 1
    fi

    asset_name="shadowsocks-${tag}.${RUST_ARCH}.tar.xz"
    if ! asset_url=$(jq -er --arg name "$asset_name" \
        '.assets[] | select(.name == $name) | .browser_download_url' "$release_json"); then
        print_err "最新版本 $tag 没有适用于 $RUST_ARCH 的发布包。"
        return 1
    fi
    if ! checksum_url=$(jq -er --arg name "${asset_name}.sha256" \
        '.assets[] | select(.name == $name) | .browser_download_url' "$release_json"); then
        print_err "最新版本 $tag 缺少 SHA-256 校验文件。"
        return 1
    fi

    print_info "正在下载 Shadowsocks-Rust $tag ($RUST_ARCH)..."
    if ! curl --fail --show-error --location --retry 3 \
        --connect-timeout 10 --max-time 300 -o "$archive" "$asset_url"; then
        print_err "内核下载失败。"
        return 1
    fi
    if ! curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 10 --max-time 60 -o "$checksum_file" "$checksum_url"; then
        print_err "校验文件下载失败。"
        return 1
    fi

    expected_sha=$(awk 'NR == 1 {print $1}' "$checksum_file")
    if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] || \
        ! printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum --check --status; then
        print_err "下载文件的 SHA-256 校验失败，已拒绝安装。"
        return 1
    fi

    # --no-same-owner 同时兼容普通 VPS 和限制 chown 的非特权 LXC 容器。
    if ! tar --extract --xz --file="$archive" --directory="$extract_dir" \
        --no-same-owner ssserver; then
        print_err "发布包解压失败，请确认 xz-utils 已正确安装。"
        return 1
    fi
    if [[ ! -x "$extract_dir/ssserver" ]]; then
        print_err "发布包中未找到可执行的 ssserver。"
        return 1
    fi
    if ! actual_version=$("$extract_dir/ssserver" --version 2>&1); then
        print_err "下载的 ssserver 无法在当前系统运行。"
        return 1
    fi

    # 在目标目录内原子替换，并保留可自动回滚的上一个版本。
    if ! install -d -m 0755 "$(dirname "$BIN_PATH")"; then
        print_err "无法创建内核安装目录。"
        return 1
    fi
    rm -f "$CORE_BACKUP_PATH"
    CORE_HAD_PREVIOUS=0
    if [[ -f "$BIN_PATH" ]]; then
        if ! cp -p "$BIN_PATH" "$CORE_BACKUP_PATH"; then
            print_err "无法备份当前 ssserver，已取消更新。"
            return 1
        fi
        CORE_HAD_PREVIOUS=1
    fi
    if ! install -m 0755 "$extract_dir/ssserver" "${BIN_PATH}.new" || \
        ! mv -f "${BIN_PATH}.new" "$BIN_PATH"; then
        rm -f "${BIN_PATH}.new"
        print_err "无法安装 ssserver 到 $BIN_PATH。"
        if (( CORE_HAD_PREVIOUS )); then
            mv -f "$CORE_BACKUP_PATH" "$BIN_PATH" || true
        fi
        CORE_HAD_PREVIOUS=0
        return 1
    fi
    CORE_INSTALLED_THIS_RUN=1

    cleanup
    TMP_DIR=""
    print_ok "内核安装成功：$actual_version"
}

# --- 服务账户与配置校验 ---
ensure_service_user() {
    local nologin_shell

    if ! command -v getent >/dev/null 2>&1 || \
        ! command -v groupadd >/dev/null 2>&1 || \
        ! command -v useradd >/dev/null 2>&1; then
        print_err "系统缺少 getent、groupadd 或 useradd，无法创建服务账户。"
        return 1
    fi
    if ! install -d -m 0700 -o root -g root "$STATE_DIR"; then
        print_err "无法创建状态目录：$STATE_DIR"
        return 1
    fi

    if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        if ! groupadd --system "$SERVICE_GROUP"; then
            print_err "无法创建低权限服务组 $SERVICE_GROUP。"
            return 1
        fi
        if ! install -m 0600 /dev/null "$MANAGED_GROUP_MARKER"; then
            groupdel "$SERVICE_GROUP" 2>/dev/null || true
            print_err "无法记录服务组的创建状态。"
            return 1
        fi
    fi

    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        nologin_shell=$(command -v nologin || true)
        [[ -z "$nologin_shell" ]] && nologin_shell="/usr/sbin/nologin"
        if ! useradd --system --gid "$SERVICE_GROUP" --no-create-home \
            --home-dir /nonexistent --shell "$nologin_shell" "$SERVICE_USER"; then
            print_err "无法创建低权限服务账户 $SERVICE_USER。"
            return 1
        fi
        if ! install -m 0600 /dev/null "$MANAGED_USER_MARKER"; then
            userdel "$SERVICE_USER" 2>/dev/null || true
            print_err "无法记录服务账户的创建状态。"
            return 1
        fi
    fi
}

remove_managed_service_identity() {
    local failed=0

    if [[ -f "$MANAGED_USER_MARKER" ]] && id "$SERVICE_USER" >/dev/null 2>&1; then
        if ! userdel "$SERVICE_USER" 2>/dev/null; then
            print_warn "服务账户 $SERVICE_USER 删除失败，已保留状态标记。"
            failed=1
        fi
    fi
    if [[ -f "$MANAGED_GROUP_MARKER" ]] && getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        if ! groupdel "$SERVICE_GROUP" 2>/dev/null; then
            print_warn "服务组 $SERVICE_GROUP 删除失败，已保留状态标记。"
            failed=1
        fi
    fi
    if (( ! failed )); then
        rm -rf "$STATE_DIR"
    fi
    return "$failed"
}

validate_2022_password() {
    local password=$1 decoded_bytes

    if ! printf '%s' "$password" | base64 --decode >/dev/null 2>&1; then
        return 1
    fi
    decoded_bytes=$(printf '%s' "$password" | base64 --decode 2>/dev/null | wc -c)
    [[ "$decoded_bytes" -eq 32 ]]
}

write_service_file() {
    local service_tmp
    service_tmp=$(mktemp) || return 1

    cat > "$service_tmp" <<EOF
[Unit]
Description=Shadowsocks-Rust Service
Documentation=https://github.com/shadowsocks/shadowsocks-rust
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
ExecStartPre=/usr/bin/test -x $BIN_PATH
ExecStartPre=/usr/bin/test -r $CONFIG_FILE
ExecStart=$BIN_PATH -c $CONFIG_FILE
Restart=on-failure
RestartSec=3s
LimitNOFILE=51200
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

    if ! install -m 0644 "$service_tmp" "$SERVICE_FILE"; then
        rm -f "$service_tmp"
        return 1
    fi
    rm -f "$service_tmp"
}

begin_config_transaction() {
    local snapshot_failed=0

    CONFIG_TXN_DIR=$(mktemp -d /tmp/shadowsocks-rust-config.XXXXXX) || {
        print_err "无法创建配置事务目录。"
        return 1
    }
    chmod 700 "$CONFIG_TXN_DIR" || snapshot_failed=1
    CONFIG_SERVICE_WAS_ACTIVE=0
    CONFIG_SERVICE_WAS_ENABLED=0
    systemctl is-active --quiet shadowsocks-rust && CONFIG_SERVICE_WAS_ACTIVE=1
    systemctl is-enabled --quiet shadowsocks-rust && CONFIG_SERVICE_WAS_ENABLED=1

    if [[ -d "$CONFIG_DIR" ]]; then
        install -m 0600 /dev/null "$CONFIG_TXN_DIR/config-dir-existed" || snapshot_failed=1
        stat -c '%u %g %a' "$CONFIG_DIR" > "$CONFIG_TXN_DIR/config-dir.meta" || snapshot_failed=1
    fi
    if [[ -e "$CONFIG_FILE" ]]; then
        cp -a "$CONFIG_FILE" "$CONFIG_TXN_DIR/config.json" || snapshot_failed=1
        install -m 0600 /dev/null "$CONFIG_TXN_DIR/config-existed" || snapshot_failed=1
    fi
    if [[ -e "$REMARKS_FILE" ]]; then
        cp -a "$REMARKS_FILE" "$CONFIG_TXN_DIR/remarks" || snapshot_failed=1
        install -m 0600 /dev/null "$CONFIG_TXN_DIR/remarks-existed" || snapshot_failed=1
    fi
    if [[ -e "$SERVICE_FILE" ]]; then
        cp -a "$SERVICE_FILE" "$CONFIG_TXN_DIR/service" || snapshot_failed=1
        install -m 0600 /dev/null "$CONFIG_TXN_DIR/service-existed" || snapshot_failed=1
    fi
    if (( snapshot_failed )); then
        rm -rf -- "$CONFIG_TXN_DIR"
        CONFIG_TXN_DIR=""
        print_err "无法完整备份当前配置，已取消操作。"
        return 1
    fi
    CONFIG_TXN_ACTIVE=1
}

restore_transaction_file() {
    local existed_marker=$1 backup=$2 destination=$3

    if [[ -f "$existed_marker" ]]; then
        cp -a "$backup" "$destination"
    else
        rm -f "$destination"
    fi
}

commit_config_transaction() {
    if [[ -n "$CONFIG_TXN_DIR" && -d "$CONFIG_TXN_DIR" ]]; then
        rm -rf -- "$CONFIG_TXN_DIR"
    fi
    CONFIG_TXN_DIR=""
    CONFIG_TXN_ACTIVE=0
}

rollback_config_transaction() {
    local restore_failed=0 dir_uid dir_gid dir_mode

    (( CONFIG_TXN_ACTIVE )) || return 0
    rollback_core_update || restore_failed=1
    restore_transaction_file "$CONFIG_TXN_DIR/config-existed" \
        "$CONFIG_TXN_DIR/config.json" "$CONFIG_FILE" || restore_failed=1
    restore_transaction_file "$CONFIG_TXN_DIR/remarks-existed" \
        "$CONFIG_TXN_DIR/remarks" "$REMARKS_FILE" || restore_failed=1
    restore_transaction_file "$CONFIG_TXN_DIR/service-existed" \
        "$CONFIG_TXN_DIR/service" "$SERVICE_FILE" || restore_failed=1

    if [[ ! -f "$CONFIG_TXN_DIR/config-dir-existed" ]]; then
        rmdir "$CONFIG_DIR" 2>/dev/null || true
    elif read -r dir_uid dir_gid dir_mode < "$CONFIG_TXN_DIR/config-dir.meta"; then
        chown "$dir_uid:$dir_gid" "$CONFIG_DIR" || restore_failed=1
        chmod "$dir_mode" "$CONFIG_DIR" || restore_failed=1
    else
        restore_failed=1
    fi

    CONFIG_TXN_ACTIVE=0
    systemctl daemon-reload >/dev/null 2>&1 || restore_failed=1
    if (( CONFIG_SERVICE_WAS_ENABLED )); then
        systemctl enable shadowsocks-rust >/dev/null 2>&1 || restore_failed=1
    else
        systemctl disable shadowsocks-rust >/dev/null 2>&1 || true
    fi
    systemctl reset-failed shadowsocks-rust 2>/dev/null || true
    if (( CONFIG_SERVICE_WAS_ACTIVE )); then
        systemctl restart shadowsocks-rust >/dev/null 2>&1 || restore_failed=1
    else
        systemctl stop shadowsocks-rust >/dev/null 2>&1 || true
    fi

    commit_config_transaction
    if (( restore_failed )); then
        print_err "自动回滚未完全成功，请检查服务和备份状态。"
        return 1
    fi
    print_warn "配置、服务文件和内核已恢复到操作前状态。"
}

check_service_health() {
    local port mode main_pid

    for _ in 1 2; do
        sleep 1
        if ! systemctl is-active --quiet shadowsocks-rust; then
            print_err "服务在启动后退出。"
            return 1
        fi
    done

    if ! command -v lsof >/dev/null 2>&1 || [[ ! -f "$CONFIG_FILE" ]]; then
        print_warn "无法进行端口级健康检查，仅确认了 systemd 活跃状态。"
        return 0
    fi
    if ! port=$(jq -er '.server_port' "$CONFIG_FILE" 2>/dev/null); then
        print_warn "检测到扩展或自定义配置，已跳过单端口监听检查。"
        return 0
    fi
    mode=$(jq -r '.mode // "tcp_only"' "$CONFIG_FILE" 2>/dev/null)
    main_pid=$(systemctl show --property=MainPID --value shadowsocks-rust 2>/dev/null)
    if [[ ! "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
        print_err "无法取得 ssserver 的 MainPID。"
        return 1
    fi

    if [[ "$mode" != "udp_only" ]] && \
        ! lsof -nP -a -p "$main_pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        print_err "ssserver 未监听 TCP 端口 $port。"
        return 1
    fi
    if [[ "$mode" != "tcp_only" ]] && \
        ! lsof -nP -a -p "$main_pid" -iUDP:"$port" >/dev/null 2>&1; then
        print_err "ssserver 未监听 UDP 端口 $port。"
        return 1
    fi
    print_ok "健康检查通过：systemd 稳定，端口 $port 与配置一致。"
}

# --- 终端信息框渲染 ---
terminal_display_width() {
    local text=$1 width

    if width=$(printf '%s\n' "$text" | LC_ALL=C.UTF-8 wc -L 2>/dev/null); then
        printf '%s' "$width"
    else
        # Debian/Ubuntu 通常自带 C.UTF-8；极少数精简系统缺失时退回字符数。
        printf '%s' "${#text}"
    fi
}

sanitize_terminal_text() {
    local text=$1

    text=${text//$'\e'/\\e}
    text=${text//$'\n'/\\n}
    text=${text//$'\r'/\\r}
    text=${text//$'\t'/\\t}
    printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

print_connection_box_border() {
    local position=$1 left middle right

    printf -v middle '%*s' "$((INFO_BOX_CONTENT_WIDTH + 2))" ''
    middle=${middle// /═}
    case "$position" in
        top) left="╔"; right="╗" ;;
        middle) left="╠"; right="╣" ;;
        bottom) left="╚"; right="╝" ;;
        *) return 1 ;;
    esac
    printf '%b%s%s%s%b\n' "$BLUE" "$left" "$middle" "$right" "$PLAIN"
}

print_connection_box_line() {
    local text=$1 alignment=${2:-left} color=${3:-$GREEN}
    local text_width left_padding=0 right_padding

    text_width=$(terminal_display_width "$text")
    (( text_width > INFO_BOX_CONTENT_WIDTH )) && return 1
    right_padding=$((INFO_BOX_CONTENT_WIDTH - text_width))
    if [[ "$alignment" == "center" ]]; then
        left_padding=$((right_padding / 2))
        right_padding=$((right_padding - left_padding))
    fi

    printf '%b║%b %*s%b%s%b%*s %b║%b\n' \
        "$BLUE" "$PLAIN" "$left_padding" '' "$color" "$text" "$PLAIN" \
        "$right_padding" '' "$BLUE" "$PLAIN"
}

print_connection_box_field() {
    local label value prefix continuation current char
    local prefix_width current_width char_width

    label=$(sanitize_terminal_text "$1")
    value=$(sanitize_terminal_text "$2")
    prefix="$label: "
    prefix_width=$(terminal_display_width "$prefix")
    if (( prefix_width >= INFO_BOX_CONTENT_WIDTH )); then
        print_connection_box_line "$label" || return 1
        prefix=""
        prefix_width=0
    fi
    printf -v continuation '%*s' "$prefix_width" ''
    current=$prefix
    current_width=$prefix_width

    while IFS= read -r char; do
        char_width=$(terminal_display_width "$char")
        if (( current_width + char_width > INFO_BOX_CONTENT_WIDTH )); then
            print_connection_box_line "$current" || return 1
            current="$continuation$char"
            current_width=$((prefix_width + char_width))
        else
            current+=$char
            current_width=$((current_width + char_width))
        fi
    done < <(jq -nr --arg value "$value" '$value | explode[] | [.] | implode')

    print_connection_box_line "$current"
}

get_status_plain() {
    if [[ ! -x "$BIN_PATH" ]]; then
        printf '内核未安装 (Not installed)'
    elif systemctl is-active --quiet shadowsocks-rust; then
        printf '运行中 (Running)'
    else
        printf '未运行 (Stopped)'
    fi
}

render_connection_box() {
    local ip=$1 port=$2 password=$3 method=$4 status=$5
    local terminal_cols=${COLUMNS:-}

    if [[ ! "$terminal_cols" =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1; then
        terminal_cols=$(tput cols 2>/dev/null || true)
    fi
    [[ "$terminal_cols" =~ ^[0-9]+$ ]] || terminal_cols=80

    INFO_BOX_CONTENT_WIDTH=68
    if (( terminal_cols - 4 < INFO_BOX_CONTENT_WIDTH )); then
        INFO_BOX_CONTENT_WIDTH=$((terminal_cols - 4))
    fi
    # 再窄的终端无法完整显示标题，保持一个仍可阅读的最小宽度。
    (( INFO_BOX_CONTENT_WIDTH < 30 )) && INFO_BOX_CONTENT_WIDTH=30

    print_connection_box_border top
    print_connection_box_line "Shadowsocks-Rust 连接信息" center "$PURPLE"
    print_connection_box_border middle
    print_connection_box_field "地址 (IP)" "$ip"
    print_connection_box_field "端口 (Port)" "$port"
    print_connection_box_field "密码 (Pass)" "$password"
    print_connection_box_field "加密 (Method)" "$method"
    print_connection_box_field "状态 (Status)" "$status"
    print_connection_box_border bottom
}

# --- 配置 SS ---
configure_ss() {
    local current_port="" config_tmp listen_addr="::"

    if [[ ! -x "$BIN_PATH" ]]; then
        print_err "未找到 $BIN_PATH，请先成功安装内核。"
        return 1
    fi
    ensure_service_user || return 1

    print_line
    echo -e "${PURPLE}开始配置 Shadowsocks-Rust${PLAIN}"

    if [[ -f "$CONFIG_FILE" ]]; then
        current_port=$(jq -r '.server_port // empty' "$CONFIG_FILE" 2>/dev/null)
    fi
    if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && \
        [[ "$(< /proc/sys/net/ipv6/conf/all/disable_ipv6)" == "1" ]]; then
        listen_addr="0.0.0.0"
    fi
    
    # 1. 端口设置与检测
    while true; do
        prompt_input PORT "请输入端口 [留空随机 10000-65535]: " || return 130
        [[ -z "$PORT" ]] && PORT=$(shuf -i 10000-65535 -n 1)

        if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
            print_err "端口范围必须是 1-65535"
            continue
        fi
        PORT=$((10#$PORT))
        if (( PORT < 1 || PORT > 65535 )); then
            print_err "端口范围必须是 1-65535"
            continue
        fi

        # 检查端口占用
        if lsof -nP -i:"$PORT" >/dev/null 2>&1 && \
            ! { [[ "$PORT" == "$current_port" ]] && systemctl is-active --quiet shadowsocks-rust; }; then
            print_err "端口 $PORT 已被占用，请重新输入！"
        else
            echo -e "端口: ${GREEN}$PORT${PLAIN}"
            break
        fi
    done

    # 2. 加密方式选择
    echo -e "\n${YELLOW}加密方式选择:${PLAIN}"
    echo " 1) aes-256-gcm (经典/兼容性好/推荐)"
    echo " 2) chacha20-ietf-poly1305 (移动端/ARM友好)"
    echo " 3) 2022-blake3-aes-256-gcm (新协议/防探测)"
    echo " 4) 2022-blake3-chacha20-poly1305 (新协议/高性能)"
    prompt_input METHOD_OPT "请选择 [默认 1]: " || return 130
    
    case $METHOD_OPT in
        2) METHOD="chacha20-ietf-poly1305"; PW_LEN=32 ;;
        3) METHOD="2022-blake3-aes-256-gcm"; PW_LEN=32 ;;
        4) METHOD="2022-blake3-chacha20-poly1305"; PW_LEN=32 ;;
        *) METHOD="aes-256-gcm"; PW_LEN=32 ;;
    esac
    echo -e "加密: ${GREEN}$METHOD${PLAIN}"

    # 3. 密码生成 (智能适配)
    prompt_input PASSWORD "请输入密码 [留空自动生成强密码]: " || return 130
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(openssl rand -base64 "$PW_LEN" | tr -d '\n')
        echo -e "密码: ${GREEN}已自动生成符合协议要求的密钥${PLAIN}"
    elif [[ "$METHOD" == 2022-* ]] && ! validate_2022_password "$PASSWORD"; then
        print_err "SS2022 密钥必须是 Base64 编码的 32 字节随机值。"
        print_info "建议将密码留空，由脚本自动生成。"
        return 1
    fi

    # 4. 备注
    prompt_input REMARKS "请输入备注名 [默认 SS-Rust]: " || return 130
    [[ -z "$REMARKS" ]] && REMARKS="SS-Rust"

    # 5. 写入配置
    begin_config_transaction || return 1
    if ! install -d -m 0750 -o root -g "$SERVICE_GROUP" "$CONFIG_DIR"; then
        print_err "无法创建配置目录。"
        rollback_config_transaction || true
        return 1
    fi
    config_tmp=$(mktemp) || {
        print_err "无法创建临时配置文件。"
        rollback_config_transaction || true
        return 1
    }
    if ! jq -n \
        --arg server "$listen_addr" \
        --argjson server_port "$PORT" \
        --arg password "$PASSWORD" \
        --arg method "$METHOD" \
        '{server: $server, server_port: $server_port, password: $password,
          method: $method, mode: "tcp_and_udp", fast_open: true, timeout: 300}' \
        > "$config_tmp" || \
        ! install -m 0640 -o root -g "$SERVICE_GROUP" "$config_tmp" "$CONFIG_FILE"; then
        rm -f "$config_tmp"
        print_err "配置文件写入失败。"
        rollback_config_transaction || true
        return 1
    fi
    rm -f "$config_tmp"
    if ! printf '%s\n' "$REMARKS" > "$REMARKS_FILE" || \
        ! chown root:"$SERVICE_GROUP" "$REMARKS_FILE" || \
        ! chmod 0640 "$REMARKS_FILE"; then
        print_err "备注文件写入失败。"
        rollback_config_transaction || true
        return 1
    fi

    # 6. 写入并校验服务文件
    if ! write_service_file; then
        print_err "systemd 服务文件写入失败。"
        rollback_config_transaction || true
        return 1
    fi
    if command -v systemd-analyze >/dev/null 2>&1 && \
        ! systemd-analyze verify "$SERVICE_FILE"; then
        print_err "systemd 服务文件校验失败。"
        rollback_config_transaction || true
        return 1
    fi

    if ! systemctl daemon-reload; then
        print_err "systemd 配置重载失败。"
        rollback_config_transaction || true
        return 1
    fi
    systemctl reset-failed shadowsocks-rust 2>/dev/null || true
    if ! systemctl enable shadowsocks-rust >/dev/null 2>&1 || \
        ! systemctl restart shadowsocks-rust; then
        print_err "服务启动失败，最近日志如下："
        journalctl -u shadowsocks-rust --no-pager -n 20
        rollback_config_transaction || true
        return 1
    fi

    if check_service_health; then
        commit_config_transaction
        commit_core_update
        print_ok "服务启动成功！"
        show_info
    else
        print_err "服务启动失败！请查看日志。"
        journalctl -u shadowsocks-rust --no-pager -n 20
        rollback_config_transaction || true
        return 1
    fi
}

# --- 展示信息 ---
show_info() {
    local port password method remarks ip host user_info remarks_encoded ss_link status

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_err "未找到配置文件！"
        return 1
    fi

    if ! port=$(jq -er '.server_port' "$CONFIG_FILE") || \
        ! password=$(jq -er '.password' "$CONFIG_FILE") || \
        ! method=$(jq -er '.method' "$CONFIG_FILE"); then
        print_err "配置文件格式无效：$CONFIG_FILE"
        return 1
    fi
    remarks="SS-Rust"
    if [[ -s "$REMARKS_FILE" ]]; then
        IFS= read -r remarks < "$REMARKS_FILE"
    fi

    # 获取IP (多重备选)
    ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -6fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://ifconfig.me/ip 2>/dev/null || true)
    fi
    if [[ -z "$ip" ]]; then
        print_err "无法获取服务器公网 IP，请检查网络连接。"
        return 1
    fi

    # 按 SIP002 生成 URL-safe Base64 链接，并正确处理 IPv6 地址。
    host="$ip"
    [[ "$ip" == *:* ]] && host="[$ip]"
    user_info=$(printf '%s:%s' "$method" "$password" | base64 | tr -d '\n=' | tr '+/' '-_')
    remarks_encoded=$(jq -rn --arg value "$remarks" '$value | @uri')
    ss_link="ss://${user_info}@${host}:${port}#${remarks_encoded}"
    status=$(get_status_plain)

    echo ""
    render_connection_box "$ip" "$port" "$password" "$method" "$status"
    echo ""
    echo -e "SS 链接 (点击复制):"
    echo -e "${PURPLE}$ss_link${PLAIN}"
    echo ""
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "二维码:"
        qrencode -t ANSIUTF8 "$ss_link"
    else
        print_warn "未安装 qrencode，已跳过二维码。"
    fi
    echo ""
}

# --- 辅助功能 ---
check_bbr() {
    local current_algo enable_bbr bbr_config

    print_line
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    echo -e "当前 TCP 拥塞控制: ${GREEN}${current_algo}${PLAIN}"

    if [[ "$current_algo" != "bbr" ]]; then
        prompt_input enable_bbr "检测到未开启 BBR，是否尝试自动开启? (y/n): " || return 130
        if [[ "$enable_bbr" =~ ^[Yy]$ ]]; then
            modprobe tcp_bbr 2>/dev/null || true
            if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
                print_err "当前内核不支持 BBR。"
                return 1
            fi

            bbr_config="/etc/sysctl.d/99-shadowsocks-rust-bbr.conf"
            if ! cat > "$bbr_config" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
            then
                print_err "无法写入 BBR 配置文件。"
                return 1
            fi
            if sysctl -p "$bbr_config" >/dev/null && \
                [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
                print_ok "BBR 已开启。"
            else
                print_err "BBR 配置未能生效，请检查内核和 sysctl 日志。"
                return 1
            fi
        fi
    else
        print_ok "BBR 已开启，无需操作。"
    fi
}

get_status() {
    if [[ ! -x "$BIN_PATH" ]]; then
        echo -e "${RED}内核未安装 (Not installed)${PLAIN}"
    elif systemctl is-active --quiet shadowsocks-rust; then
        echo -e "${GREEN}运行中 (Running)${PLAIN}"
    else
        echo -e "${RED}未运行 (Stopped)${PLAIN}"
    fi
}

# --- 菜单逻辑 ---
menu() {
    clear 2>/dev/null || true
    echo -e "${BLUE}#############################################################${PLAIN}"
    echo -e "${BLUE}#                Shadowsocks-Rust 一键管理脚本              #${PLAIN}"
    echo -e "${BLUE}#                   Version: ${VERSION}                          #${PLAIN}"
    echo -e "${BLUE}#############################################################${PLAIN}"
    echo -e " 当前状态: $(get_status)"
    echo -e "-------------------------------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 安装 / 重置配置 (全新安装)"
    echo -e "  ${GREEN}2.${PLAIN} 更新内核 (保留配置)"
    echo -e "  ${GREEN}3.${PLAIN} 查看连接信息 (链接 & 二维码)"
    echo -e "-------------------------------------------------------------"
    echo -e "  ${GREEN}4.${PLAIN} 启动服务"
    echo -e "  ${GREEN}5.${PLAIN} 停止服务"
    echo -e "  ${GREEN}6.${PLAIN} 重启服务"
    echo -e "  ${GREEN}7.${PLAIN} 查看实时日志"
    echo -e "-------------------------------------------------------------"
    echo -e "  ${GREEN}8.${PLAIN} 查看/开启 BBR 加速"
    echo -e "  ${RED}9. 彻底卸载${PLAIN}"
    echo -e "  ${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${BLUE}#############################################################${PLAIN}"
    
    prompt_input CHOICE " 请选择操作 [0-9]: " || exit 0
    
    case $CHOICE in
        1)
            if install_deps && sync_time && install_core; then
                if ! configure_ss; then
                    rollback_core_update || true
                fi
            else
                print_err "安装已中止；未写入或启动无效的 systemd 服务。"
            fi
            ;;
        2)
            if install_deps && install_core; then
                if [[ -f "$SERVICE_FILE" ]]; then
                    systemctl reset-failed shadowsocks-rust 2>/dev/null || true
                    if systemctl restart shadowsocks-rust && \
                        check_service_health; then
                        commit_core_update
                        print_ok "内核更新完成，服务已重启。"
                    else
                        print_err "新内核健康检查失败，正在自动回滚。"
                        journalctl -u shadowsocks-rust --no-pager -n 20
                        if rollback_core_update; then
                            systemctl reset-failed shadowsocks-rust 2>/dev/null || true
                            if systemctl restart shadowsocks-rust && check_service_health; then
                                print_warn "旧内核已恢复，服务重新运行。"
                            else
                                print_err "旧内核恢复后服务仍未正常运行，请检查日志。"
                                journalctl -u shadowsocks-rust --no-pager -n 20
                            fi
                        fi
                    fi
                else
                    commit_core_update
                    print_ok "内核更新完成；尚未配置 systemd 服务。"
                fi
            else
                print_err "内核更新失败，原有可执行文件未被破坏。"
            fi
            ;;
        3) show_info ;;
        4)
            systemctl reset-failed shadowsocks-rust 2>/dev/null || true
            if systemctl start shadowsocks-rust && check_service_health; then
                print_ok "服务已启动"
            else
                print_err "服务启动失败"
                journalctl -u shadowsocks-rust --no-pager -n 20
            fi
            ;;
        5) systemctl stop shadowsocks-rust && print_ok "服务已停止" ;;
        6)
            systemctl reset-failed shadowsocks-rust 2>/dev/null || true
            if systemctl restart shadowsocks-rust && check_service_health; then
                print_ok "服务已重启"
            else
                print_err "服务重启失败"
                journalctl -u shadowsocks-rust --no-pager -n 20
            fi
            ;;
        7) echo -e "${YELLOW}按 Ctrl+C 退出日志查看${PLAIN}"; journalctl -u shadowsocks-rust -f ;;
        8) check_bbr ;;
        9)
            prompt_input CONFIRM "确认要卸载吗? (y/n): " || return 130
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                systemctl disable --now shadowsocks-rust >/dev/null 2>&1 || true
                rm -f "$SERVICE_FILE" "$BIN_PATH" "${BIN_PATH}.new" "$CORE_BACKUP_PATH"
                rm -rf "$CONFIG_DIR"
                remove_managed_service_identity || true
                systemctl daemon-reload
                systemctl reset-failed shadowsocks-rust 2>/dev/null || true
                print_ok "卸载完成。"
                [[ -f /etc/sysctl.d/99-shadowsocks-rust-bbr.conf ]] && \
                    print_info "已保留系统级 BBR 配置，如不需要可手动删除。"
            fi
            ;;
        0) exit 0 ;;
        *) print_err "输入无效，请重新选择" ;;
    esac
}

# --- 入口 ---
main() {
    preflight || exit 1
    trap handle_exit EXIT
    trap 'exit 130' INT TERM

    while true; do
        menu
        echo -e "\n${YELLOW}按回车键返回主菜单...${PLAIN}"
        IFS= read -r || exit 0
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

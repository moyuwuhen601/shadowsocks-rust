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
VERSION="2.1.0"
CONFIG_FILE="/etc/shadowsocks-rust/config.json"
REMARKS_FILE="/etc/shadowsocks-rust/remarks"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
BIN_PATH="/usr/local/bin/ssserver"
SERVICE_USER="shadowsocks-rust"
TMP_DIR=""

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
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- 检查 Root ---
if [[ $EUID -ne 0 ]]; then
    print_err "必须使用 root 用户运行此脚本！"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    print_err "当前系统未使用 systemd，无法安装本服务。"
    exit 1
fi

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

# --- 安装/更新内核 ---
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

    # 在目标目录内原子替换，更新失败时不会破坏原有可执行文件。
    install -d -m 0755 "$(dirname "$BIN_PATH")"
    if ! install -m 0755 "$extract_dir/ssserver" "${BIN_PATH}.new" || \
        ! mv -f "${BIN_PATH}.new" "$BIN_PATH"; then
        rm -f "${BIN_PATH}.new"
        print_err "无法安装 ssserver 到 $BIN_PATH。"
        return 1
    fi

    cleanup
    TMP_DIR=""
    print_ok "内核安装成功：$actual_version"
}

# --- 服务账户与配置校验 ---
ensure_service_user() {
    local nologin_shell

    if id "$SERVICE_USER" >/dev/null 2>&1; then
        return 0
    fi

    nologin_shell=$(command -v nologin || true)
    [[ -z "$nologin_shell" ]] && nologin_shell="/usr/sbin/nologin"
    if ! useradd --system --user-group --home-dir /nonexistent \
        --shell "$nologin_shell" "$SERVICE_USER"; then
        print_err "无法创建低权限服务账户 $SERVICE_USER。"
        return 1
    fi
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
Group=$SERVICE_USER
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
        IFS= read -r -p "请输入端口 [留空随机 10000-65535]: " PORT
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
    IFS= read -r -p "请选择 [默认 1]: " METHOD_OPT
    
    case $METHOD_OPT in
        2) METHOD="chacha20-ietf-poly1305"; PW_LEN=32 ;;
        3) METHOD="2022-blake3-aes-256-gcm"; PW_LEN=32 ;;
        4) METHOD="2022-blake3-chacha20-poly1305"; PW_LEN=32 ;;
        *) METHOD="aes-256-gcm"; PW_LEN=32 ;;
    esac
    echo -e "加密: ${GREEN}$METHOD${PLAIN}"

    # 3. 密码生成 (智能适配)
    IFS= read -r -p "请输入密码 [留空自动生成强密码]: " PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(openssl rand -base64 "$PW_LEN" | tr -d '\n')
        echo -e "密码: ${GREEN}已自动生成符合协议要求的密钥${PLAIN}"
    elif [[ "$METHOD" == 2022-* ]] && ! validate_2022_password "$PASSWORD"; then
        print_err "SS2022 密钥必须是 Base64 编码的 32 字节随机值。"
        print_info "建议将密码留空，由脚本自动生成。"
        return 1
    fi

    # 4. 备注
    IFS= read -r -p "请输入备注名 [默认 SS-Rust]: " REMARKS
    [[ -z "$REMARKS" ]] && REMARKS="SS-Rust"

    # 5. 写入配置
    if ! install -d -m 0750 -o root -g "$SERVICE_USER" /etc/shadowsocks-rust; then
        print_err "无法创建配置目录。"
        return 1
    fi
    config_tmp=$(mktemp) || {
        print_err "无法创建临时配置文件。"
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
        ! install -m 0640 -o root -g "$SERVICE_USER" "$config_tmp" "$CONFIG_FILE"; then
        rm -f "$config_tmp"
        print_err "配置文件写入失败。"
        return 1
    fi
    rm -f "$config_tmp"
    if ! printf '%s\n' "$REMARKS" > "$REMARKS_FILE" || \
        ! chown root:"$SERVICE_USER" "$REMARKS_FILE" || \
        ! chmod 0640 "$REMARKS_FILE"; then
        print_err "备注文件写入失败。"
        return 1
    fi

    # 6. 写入并校验服务文件
    if ! write_service_file; then
        print_err "systemd 服务文件写入失败。"
        return 1
    fi
    if command -v systemd-analyze >/dev/null 2>&1 && \
        ! systemd-analyze verify "$SERVICE_FILE"; then
        print_err "systemd 服务文件校验失败。"
        return 1
    fi

    if ! systemctl daemon-reload; then
        print_err "systemd 配置重载失败。"
        return 1
    fi
    systemctl reset-failed shadowsocks-rust 2>/dev/null || true
    if ! systemctl enable shadowsocks-rust >/dev/null 2>&1 || \
        ! systemctl restart shadowsocks-rust; then
        print_err "服务启动失败，最近日志如下："
        journalctl -u shadowsocks-rust --no-pager -n 20
        return 1
    fi

    if systemctl is-active --quiet shadowsocks-rust; then
        print_ok "服务启动成功！"
        show_info
    else
        print_err "服务启动失败！请查看日志。"
        journalctl -u shadowsocks-rust --no-pager -n 20
        return 1
    fi
}

# --- 展示信息 ---
show_info() {
    local port password method remarks ip host user_info remarks_encoded ss_link

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

    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║                 Shadowsocks-Rust 连接信息                 ║${PLAIN}"
    echo -e "${BLUE}╠═══════════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  地址 (IP)     : ${GREEN}${ip}${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  端口 (Port)   : ${GREEN}${port}${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  密码 (Pass)   : ${GREEN}${password}${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  加密 (Method) : ${GREEN}${method}${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  状态 (Status) : $(get_status)"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${PLAIN}"
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
        IFS= read -r -p "检测到未开启 BBR，是否尝试自动开启? (y/n): " enable_bbr
        if [[ "$enable_bbr" =~ ^[Yy]$ ]]; then
            modprobe tcp_bbr 2>/dev/null || true
            if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
                print_err "当前内核不支持 BBR。"
                return 1
            fi

            bbr_config="/etc/sysctl.d/99-shadowsocks-rust-bbr.conf"
            cat > "$bbr_config" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
            if sysctl --system >/dev/null && \
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
    
    IFS= read -r -p " 请选择操作 [0-9]: " CHOICE || exit 0
    
    case $CHOICE in
        1)
            if install_deps && sync_time && install_core; then
                configure_ss
            else
                print_err "安装已中止；未写入或启动无效的 systemd 服务。"
            fi
            ;;
        2)
            if install_deps && install_core; then
                if [[ -f "$SERVICE_FILE" ]]; then
                    if systemctl restart shadowsocks-rust && \
                        systemctl is-active --quiet shadowsocks-rust; then
                        print_ok "内核更新完成，服务已重启。"
                    else
                        print_err "内核已更新，但服务重启失败。"
                        journalctl -u shadowsocks-rust --no-pager -n 20
                    fi
                else
                    print_ok "内核更新完成；尚未配置 systemd 服务。"
                fi
            else
                print_err "内核更新失败，原有可执行文件未被破坏。"
            fi
            ;;
        3) show_info ;;
        4)
            if systemctl start shadowsocks-rust && systemctl is-active --quiet shadowsocks-rust; then
                print_ok "服务已启动"
            else
                print_err "服务启动失败"
                journalctl -u shadowsocks-rust --no-pager -n 20
            fi
            ;;
        5) systemctl stop shadowsocks-rust && print_ok "服务已停止" ;;
        6)
            if systemctl restart shadowsocks-rust && systemctl is-active --quiet shadowsocks-rust; then
                print_ok "服务已重启"
            else
                print_err "服务重启失败"
                journalctl -u shadowsocks-rust --no-pager -n 20
            fi
            ;;
        7) echo -e "${YELLOW}按 Ctrl+C 退出日志查看${PLAIN}"; journalctl -u shadowsocks-rust -f ;;
        8) check_bbr ;;
        9)
            IFS= read -r -p "确认要卸载吗? (y/n): " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                systemctl disable --now shadowsocks-rust >/dev/null 2>&1 || true
                rm -f "$SERVICE_FILE" "$BIN_PATH"
                rm -rf /etc/shadowsocks-rust
                id "$SERVICE_USER" >/dev/null 2>&1 && userdel "$SERVICE_USER" 2>/dev/null || true
                systemctl daemon-reload
                systemctl reset-failed shadowsocks-rust 2>/dev/null || true
                print_ok "卸载完成。"
            fi
            ;;
        0) exit 0 ;;
        *) print_err "输入无效，请重新选择" ;;
    esac
}

# --- 入口 ---
while true; do
    menu
    echo -e "\n${YELLOW}按回车键返回主菜单...${PLAIN}"
    IFS= read -r || exit 0
done

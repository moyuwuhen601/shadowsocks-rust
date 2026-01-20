#!/bin/bash

# ==================================================
# Shadowsocks-Rust 一键管理脚本 (Ultimate Edition)
# Author: MoyuWuhen & Gemini
# Github: https://github.com/moyuwuhen601/shadowsocks-rust
# ==================================================

# --- 基础设置 ---
VERSION="2.0.0"
CONFIG_FILE="/etc/shadowsocks-rust/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
BIN_PATH="/usr/local/bin/ssserver"

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

# --- 退出清理 ---
trap 'rm -f /tmp/ss-rust.tar.xz /tmp/ss-rust-ip.txt' EXIT

# --- 检查 Root ---
if [[ $EUID -ne 0 ]]; then
    print_err "必须使用 root 用户运行此脚本！"
    exit 1
fi

# --- 获取系统架构 ---
check_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) RUST_ARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) RUST_ARCH="aarch64-unknown-linux-gnu" ;;
        *) print_err "不支持的架构: $ARCH"; exit 1 ;;
    esac
}

# --- 时间同步 (核心功能) ---
sync_time() {
    print_info "正在配置时区与时间同步 (2022协议必需)..."
    timedatectl set-timezone Asia/Shanghai
    
    if ! systemctl is-active --quiet systemd-timesyncd; then
        apt-get install -y systemd-timesyncd >/dev/null 2>&1
        systemctl enable systemd-timesyncd
        systemctl restart systemd-timesyncd
    fi
    
    timedatectl set-ntp true
    print_ok "时间同步完成，当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

# --- 安装依赖 ---
install_deps() {
    print_info "正在检查并安装依赖..."
    apt-get update -y -q
    apt-get install -y -q wget curl jq tar qrencode openssl lsof
    print_ok "依赖安装完成"
}

# --- 安装/更新内核 ---
install_core() {
    check_arch
    print_info "正在查询 GitHub 最新版本..."
    
    LATEST_URL=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -r ".assets[] | select(.name | contains(\"$RUST_ARCH\")) | .browser_download_url" | grep -v "sha256")
    
    if [[ -z "$LATEST_URL" ]]; then
        print_err "无法获取下载链接，请检查网络连接。"
        return 1
    fi
    
    print_info "下载地址: $LATEST_URL"
    wget -q --show-progress -O /tmp/ss-rust.tar.xz "$LATEST_URL"
    
    if [[ $? -ne 0 ]]; then
        print_err "下载失败！"
        return 1
    fi

    # 停止服务防止文件占用
    systemctl stop shadowsocks-rust 2>/dev/null
    
    tar -xf /tmp/ss-rust.tar.xz -C /tmp/
    mv /tmp/ssserver "$BIN_PATH"
    chmod +x "$BIN_PATH"
    
    # 清理旧文件
    rm -f /tmp/sslocal /tmp/ssurl /tmp/ssservice /tmp/ssmanager
    
    print_ok "Shadowsocks-Rust 内核安装成功！"
}

# --- 配置 SS ---
configure_ss() {
    print_line
    echo -e "${PURPLE}开始配置 Shadowsocks-Rust${PLAIN}"
    
    # 1. 端口设置与检测
    while true; do
        read -p "请输入端口 [留空随机 10000-65535]: " PORT
        [[ -z "$PORT" ]] && PORT=$(shuf -i 10000-65535 -n 1)
        
        if [[ $PORT -lt 1 || $PORT -gt 65535 ]]; then
            print_err "端口范围必须是 1-65535"
            continue
        fi
        
        # 检查端口占用
        if lsof -i:"$PORT" >/dev/null 2>&1; then
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
    read -p "请选择 [默认 1]: " METHOD_OPT
    
    case $METHOD_OPT in
        2) METHOD="chacha20-ietf-poly1305"; PW_LEN=32 ;;
        3) METHOD="2022-blake3-aes-256-gcm"; PW_LEN=32 ;;
        4) METHOD="2022-blake3-chacha20-poly1305"; PW_LEN=32 ;;
        *) METHOD="aes-256-gcm"; PW_LEN=32 ;;
    esac
    echo -e "加密: ${GREEN}$METHOD${PLAIN}"

    # 3. 密码生成 (智能适配)
    read -p "请输入密码 [留空自动生成强密码]: " PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        # 针对 2022 协议，必须保证密钥长度足够
        PASSWORD=$(openssl rand -base64 $PW_LEN)
        echo -e "密码: ${GREEN}已自动生成符合协议要求的密钥${PLAIN}"
    fi

    # 4. 备注
    read -p "请输入备注名 [默认 SS-Rust]: " REMARKS
    [[ -z "$REMARKS" ]] && REMARKS="SS-Rust"

    # 5. 写入配置
    mkdir -p /etc/shadowsocks-rust
    cat > $CONFIG_FILE <<EOF
{
    "server": "::",
    "server_port": $PORT,
    "password": "$PASSWORD",
    "method": "$METHOD",
    "mode": "tcp_and_udp",
    "fast_open": true,
    "timeout": 300
}
EOF

    # 6. 写入服务文件
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Shadowsocks-Rust Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$BIN_PATH -c $CONFIG_FILE
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadowsocks-rust
    systemctl restart shadowsocks-rust
    
    if systemctl is-active --quiet shadowsocks-rust; then
        print_ok "服务启动成功！"
        show_info
    else
        print_err "服务启动失败！请查看日志。"
        journalctl -u shadowsocks-rust --no-pager -n 10
    fi
}

# --- 展示信息 ---
show_info() {
    if [[ ! -f $CONFIG_FILE ]]; then
        print_err "未找到配置文件！"
        return
    fi

    PORT=$(jq -r .server_port $CONFIG_FILE)
    PASSWORD=$(jq -r .password $CONFIG_FILE)
    METHOD=$(jq -r .method $CONFIG_FILE)
    
    # 获取IP (多重备选)
    IP=$(curl -s4 ip.sb)
    if [[ -z "$IP" ]]; then
        IP=$(curl -s6 ip.sb)
    fi
    if [[ -z "$IP" ]]; then
        IP=$(curl -s -4 ifconfig.me)
    fi

    # 构建链接
    SS_STRING="${METHOD}:${PASSWORD}@${IP}:${PORT}"
    SS_BASE64=$(echo -n "$SS_STRING" | base64 | tr -d '\n')
    SS_LINK="ss://${SS_BASE64}#${REMARKS:-SS-Rust}"

    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║                 Shadowsocks-Rust 连接信息                 ║${PLAIN}"
    echo -e "${BLUE}╠═══════════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  地址 (IP)     : ${GREEN}${IP}${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  端口 (Port)   : ${GREEN}${PORT}${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  密码 (Pass)   : ${GREEN}${PASSWORD}${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  加密 (Method) : ${GREEN}${METHOD}${PLAIN}"
    echo -e "${BLUE}║${PLAIN}  状态 (Status) : $(get_status)"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${PLAIN}"
    echo ""
    echo -e "SS 链接 (点击复制):"
    echo -e "${PURPLE}$SS_LINK${PLAIN}"
    echo ""
    echo -e "二维码:"
    qrencode -t ANSIUTF8 "$SS_LINK"
    echo ""
}

# --- 辅助功能 ---
check_bbr() {
    print_line
    CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    echo -e "当前 TCP 拥塞控制: ${GREEN}$CURRENT_ALGO${PLAIN}"
    
    if [[ "$CURRENT_ALGO" != "bbr" ]]; then
        read -p "检测到未开启 BBR，是否尝试自动开启? (y/n): " ENABLE_BBR
        if [[ "$ENABLE_BBR" == "y" ]]; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p
            print_ok "BBR 开启指令已发送。"
        fi
    else
        print_ok "BBR 已开启，无需操作。"
    fi
}

get_status() {
    if systemctl is-active --quiet shadowsocks-rust; then
        echo -e "${GREEN}运行中 (Running)${PLAIN}"
    else
        echo -e "${RED}未运行 (Stopped)${PLAIN}"
    fi
}

# --- 菜单逻辑 ---
menu() {
    clear
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
    
    read -p " 请选择操作 [0-9]: " CHOICE
    
    case $CHOICE in
        1)
            sync_time
            install_deps
            install_core
            configure_ss
            ;;
        2)
            install_core
            systemctl restart shadowsocks-rust
            print_ok "内核更新完成，服务已重启。"
            ;;
        3) show_info ;;
        4) systemctl start shadowsocks-rust && print_ok "服务已启动" ;;
        5) systemctl stop shadowsocks-rust && print_ok "服务已停止" ;;
        6) systemctl restart shadowsocks-rust && print_ok "服务已重启" ;;
        7) echo -e "${YELLOW}按 Ctrl+C 退出日志查看${PLAIN}"; journalctl -u shadowsocks-rust -f ;;
        8) check_bbr ;;
        9)
            read -p "确认要卸载吗? (y/n): " CONFIRM
            if [[ "$CONFIRM" == "y" ]]; then
                systemctl stop shadowsocks-rust
                systemctl disable shadowsocks-rust
                rm -f "$SERVICE_FILE" "$BIN_PATH"
                rm -rf /etc/shadowsocks-rust
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
    read
done

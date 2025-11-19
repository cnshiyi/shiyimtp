#!/bin/bash
###
# MTG 多实例独立目录终极脚本（v5）
# 完美兼容 bash <(curl …) 在线执行
# 每个目录 = 一个独立实例（全隔离）
###

set -e

# -----------------------------------------------------------
# 解决：bash <(curl) 时 $0 为 /proc/self/fd/xx 导致路径错误
# -----------------------------------------------------------
if [[ "$0" == "/proc/"* ]] || [[ "$0" == *"/fd/"* ]]; then
    # 在线执行时，使用当前目录作为 BASE_DIR
    SCRIPT_PATH="$(pwd)/mtproxy.sh"
else
    # 直接执行或本地执行时，正常取脚本路径
    SCRIPT_PATH="$0"
fi

BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")"; pwd)"
MTG_BIN="${BASE_DIR}/mtg"
CONF="${BASE_DIR}/mtg.toml"
SERVICE="mtg_$(basename "$BASE_DIR").service"

green="\033[32m"; red="\033[31m"; yellow="\033[33m"; plain="\033[0m"


# -----------------------------------------------------------
# 工具
# -----------------------------------------------------------
public_ip() {
    curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "0.0.0.0"
}

arch() {
    m=$(uname -m)
    [[ $m == "x86_64" ]]  && echo "amd64"
    [[ $m == "aarch64" ]] && echo "arm64"
}

install_mtg_binary() {
    echo -e "${yellow}正在获取 MTG 最新版本...${plain}"

    A=$(arch)
    VER=$(curl -Ls https://api.github.com/repos/9seconds/mtg/releases/latest \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

    FILE="mtg-${VER#v}-linux-${A}.tar.gz"

    wget -q -O "$FILE" \
        "https://github.com/9seconds/mtg/releases/download/${VER}/${FILE}"

    tar -xzf "$FILE"
    mv mtg-*/* "$MTG_BIN"
    chmod +x "$MTG_BIN"
    rm -rf mtg-* "$FILE"

    echo -e "${green}MTG 安装成功！${plain}"
}

ensure_mtg() {
    [[ -f "$MTG_BIN" ]] || install_mtg_binary
}


# -----------------------------------------------------------
# 安装实例（当前目录）
# -----------------------------------------------------------
install_instance() {
    ensure_mtg

    read -p "请输入端口：" PORT
    read -p "请输入伪装域名（默认 itunes.apple.com）：" DOMAIN
    [[ -z "$DOMAIN" ]] && DOMAIN="itunes.apple.com"

    SECRET=$("$MTG_BIN" generate-secret --hex "$DOMAIN")

cat > "$CONF" <<EOF
secret = "$SECRET"
bind-to = "0.0.0.0:${PORT}"
EOF

cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=MTG Instance at $BASE_DIR
After=network.target

[Service]
ExecStart=$MTG_BIN run $CONF
WorkingDirectory=$BASE_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"

    echo -e "${green}实例安装成功！${plain}"
    show_info
}

# -----------------------------------------------------------
# 显示连接信息
# -----------------------------------------------------------
show_info() {
    [[ -f "$CONF" ]] || { echo -e "${red}配置文件不存在！${plain}"; return; }

    SECRET=$(grep '^secret' "$CONF" | sed -E 's/.*"([^"]+)".*/\1/')
    PORT=$(grep '^bind-to' "$CONF"  | sed -E 's/.*:(.*)".*/\1/')
    IP=$(public_ip)

    LINK1="tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
    LINK2="https://t.me/proxy?server=${IP}&port=${PORT}&secret=${SECRET}"

    echo -e "${green}========= MTG 实例信息（当前目录） =========${plain}"
    echo "$LINK1"
    echo "$LINK2"
    echo -e "${green}============================================${plain}"
}

# -----------------------------------------------------------
# 控制
# -----------------------------------------------------------
start_instance()   { systemctl start "$SERVICE";   echo -e "${green}已启动${plain}"; show_info; }
stop_instance()    { systemctl stop "$SERVICE";    echo -e "${yellow}已停止${plain}"; }
restart_instance() { systemctl restart "$SERVICE"; echo -e "${green}已重启${plain}"; show_info; }

uninstall_instance() {
    stop_instance
    systemctl disable "$SERVICE"
    rm -f "/etc/systemd/system/$SERVICE"
    rm -f "$CONF" "$MTG_BIN"
    systemctl daemon-reload
    echo -e "${red}实例卸载完成！${plain}"
}

# -----------------------------------------------------------
# 菜单模式
# -----------------------------------------------------------
menu() {
clear
echo -e "
${green}MTG 独立目录实例管理（v5）${plain}
当前目录：${yellow}$BASE_DIR${plain}

1. 安装实例
2. 卸载实例
3. 启动实例
4. 停止实例
5. 重启实例
6. 查看实例链接
0. 退出
---------------------------------------
"
read -p "请选择：" N

case "$N" in
    1) install_instance ;;
    2) uninstall_instance ;;
    3) start_instance ;;
    4) stop_instance ;;
    5) restart_instance ;;
    6) show_info ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac
}


# -----------------------------------------------------------
# 命令模式入口
# -----------------------------------------------------------
if [[ $# -eq 0 ]]; then
    menu
    exit 0
fi

case "$1" in
    install)   install_instance ;;
    uninstall) uninstall_instance ;;
    start)     start_instance ;;
    stop)      stop_instance ;;
    restart)   restart_instance ;;
    show|info) show_info ;;
    *)
        echo "未知命令：$1"
        echo
        echo "示例："
        echo "  bash mtproxy.sh install"
        echo "  bash mtproxy.sh start"
        echo "  bash mtproxy.sh restart"
        ;;
esac

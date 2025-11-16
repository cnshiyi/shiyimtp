#!/bin/bash

# ==========================================
# 基本变量：以脚本所在目录为根目录
# ==========================================
ABSOLUTE_FILENAME=$(readlink -f "$0")
BASE_DIR=$(dirname "$ABSOLUTE_FILENAME")
INSTALL_ROOT="$BASE_DIR/mtprotoproxy"

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok()   { echo -e "${GREEN}[OK] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err()  { echo -e "${RED}[ERROR] $1${RESET}"; }

# ==========================================
# 安装依赖
# ==========================================
echo -e "${YELLOW}>> 检查依赖...${RESET}"
apt update -y
apt install -y git wget xxd python3 python3-pip htop

# ==========================================
# 用户选择端口
# ==========================================
read -p "请输入 MTProxy 端口（默认 10086）: " PORT
PORT=${PORT:-10086}
ok "选择端口：$PORT"

# ==========================================
# 获取公网 IP & 生成 SECRET
# ==========================================
IP=$(wget -qO- ipv4.icanhazip.com)
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
ok "公网 IP：$IP"
ok "生成 SECRET：$SECRET"

# ==========================================
# clone / 更新 MTProtoProxy 到当前目录
# ==========================================
echo -e "${GREEN}>> 安装 MTProtoProxy 到 $INSTALL_ROOT ...${RESET}"

rm -rf "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT"
cd "$BASE_DIR"

git clone https://github.com/alexbers/mtprotoproxy.git mtprotoproxy

# 写入 config.py 到当前目录的 mtprotoproxy
cat > "$INSTALL_ROOT/config.py" <<EOF
PORT = $PORT
USERS = {"user1": "$SECRET"}
EOF

ok "config.py 已写入：$INSTALL_ROOT/config.py"

# ==========================================
# 写 systemd 服务（指向当前目录）
# ==========================================
SERVICE_FILE="/etc/systemd/system/MTProxy.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MTProto Proxy Daemon (local dir)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_ROOT/mtprotoproxy.py $INSTALL_ROOT/config.py
WorkingDirectory=$INSTALL_ROOT
Restart=always
RestartSec=2
StartLimitBurst=100
LimitNOFILE=100000
LimitNPROC=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart MTProxy
systemctl enable MTProxy

ok "MTProxy 已启动（使用目录：$INSTALL_ROOT）"

# ==========================================
# watchdog 守护脚本（同样基于当前目录）
# ==========================================
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"
LOG="/var/log/mtproxy_watchdog.log"

cat > "$WATCHDOG" <<EOF
#!/bin/bash

INSTALL_ROOT="$INSTALL_ROOT"
CONF="\$INSTALL_ROOT/config.py"
SERVICE="MTProxy.service"
LOG="/var/log/mtproxy_watchdog.log"
PORT=\$(grep PORT "\$CONF" | grep -oE '[0-9]+')

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

if ! systemctl is-active --quiet "\$SERVICE"; then
    echo "\$(timestamp) systemd 服务停止，正在重启..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi

if ! pgrep -f "mtprotoproxy.py" >/dev/null; then
    echo "\$(timestamp) 进程丢失，正在重启..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi

if ! ss -tuln | grep -q "\$PORT"; then
    echo "\$(timestamp) 端口 \$PORT 未监听，正在重启..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi
EOF

chmod +x "$WATCHDOG"

# 加入 crontab 守护
(crontab -l 2>/dev/null | grep -v "$WATCHDOG"; echo "* * * * * $WATCHDOG >/dev/null 2>&1") | crontab -

ok "Watchdog 已安装并加入 crontab"

# ==========================================
# 安装 mtp 管理命令（指向当前目录）
# ==========================================
cat > /usr/local/bin/mtp <<EOF
#!/bin/bash

INSTALL_ROOT="$INSTALL_ROOT"
CONF="\$INSTALL_ROOT/config.py"
IP=\$(wget -qO- ipv4.icanhazip.com)
SERVICE="MTProxy.service"
LOG="/var/log/mtproxy_watchdog.log"
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"

GREEN="\\e[32m"; YELLOW="\\e[33m"; RED="\\e[31m"; RESET="\\e[0m"

menu() {
echo -e "\${GREEN}
=============== MTProxy 管理菜单 ===============
1) 查看状态
2) 重启服务
3) 修改端口
4) 生成新的 SECRET
5) 添加额外 SECRET
6) 输出代理连接
7) 卸载 MTProxy
--------------------------------------------
8) 查看 watchdog 日志
9) 手动执行 watchdog
10) 安装 watchdog 守护
11) 卸载 watchdog
0) 退出
==============================================\${RESET}"
}

show_status() {
    echo -e "\${GREEN}>>> 服务状态:\${RESET}"
    systemctl status "\$SERVICE" --no-pager
    echo ""
    echo -e "\${GREEN}>>> 当前配置:\${RESET}"
    cat "\$CONF"
}

restart_service() {
    systemctl restart "\$SERVICE"
    echo -e "\${GREEN}已重启 MTProxy\${RESET}"
}

change_port() {
    read -p "输入新端口: " NEW
    sed -i "s/^PORT.*/PORT = \$NEW/" "\$CONF"
    restart_service
}

new_secret() {
    NEW=\$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/user1\": \".*\"/user1\": \"\$NEW\"/" "\$CONF"
    restart_service
    echo "新的 SECRET: \$NEW"
}

add_secret() {
    read -p "新用户名: " NAME
    NEW=\$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/}/,\"\$NAME\": \"\$NEW\"}/" "\$CONF"
    restart_service
    echo "添加 \$NAME = \$NEW"
}

show_links() {
    PORT=\$(grep PORT "\$CONF" | grep -oE '[0-9]+')
    SECRETS=\$(grep -oP '"\\w+": "\\K[a-f0-9]+' "\$CONF")
    echo -e "\${GREEN}连接信息:\${RESET}"

    for S in \$SECRETS; do
        echo "tg://proxy?server=\$IP&port=\$PORT&secret=dd\$S"
        echo "https://t.me/proxy?server=\$IP&port=\$PORT&secret=dd\$S"
        echo "server=\$IP port=\$PORT secret=dd\$S"
        echo ""
    done
}

uninstall_mtproxy() {
    systemctl stop "\$SERVICE"
    systemctl disable "\$SERVICE"
    rm -rf "\$INSTALL_ROOT"
    rm -f "/etc/systemd/system/\$SERVICE"
    echo -e "\${RED}MTProxy 已卸载\${RESET}"
}

install_watchdog() {
    (crontab -l 2>/dev/null | grep -v "\$WATCHDOG"; echo "* * * * * \$WATCHDOG >/dev/null 2>&1") | crontab -
    echo -e "\${GREEN}watchdog 已启用\${RESET}"
}

uninstall_watchdog() {
    crontab -l | grep -v "\$WATCHDOG" | crontab - || true
    echo -e "\${YELLOW}watchdog 已卸载\${RESET}"
}

show_watchdog_log() {
    if [ -f "\$LOG" ]; then
        tail -n 50 "\$LOG"
    else
        echo "日志不存在：\$LOG"
    fi
}

run_watchdog_once() {
    bash "\$WATCHDOG"
    echo -e "\${GREEN}watchdog 已执行一次\${RESET}"
}

while true; do
    menu
    read -p "选择功能: " CH
    case "\$CH" in
        1) show_status ;;
        2) restart_service ;;
        3) change_port ;;
        4) new_secret ;;
        5) add_secret ;;
        6) show_links ;;
        7) uninstall_mtproxy ;;
        8) show_watchdog_log ;;
        9) run_watchdog_once ;;
        10) install_watchdog ;;
        11) uninstall_watchdog ;;
        0) exit 0 ;;
        *) echo -e "\${RED}无效输入\${RESET}" ;;
    esac
done
EOF

chmod +x /usr/local/bin/mtp

ok "管理工具 mtp 已安装（使用目录：$INSTALL_ROOT）"

echo ""
echo -e "${GREEN}✨ 安装成功！现在可以执行： mtp${RESET}"
echo -e "${YELLOW}查看代理连接： mtp 6${RESET}"
echo -e "${YELLOW}当前构建目录： $INSTALL_ROOT${RESET}"

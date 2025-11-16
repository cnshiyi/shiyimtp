#!/bin/bash

# ================================
# 彩色输出
# ================================
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

ok() { echo -e "${GREEN}[OK] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; }

# ================================
# 依赖安装
# ================================
echo -e "${YELLOW}>> 检查依赖...${RESET}"

apt update -y
apt install -y git wget xxd python3 python3-pip htop

# ================================
# 变量
# ================================
INSTALL_ROOT="/opt/mtprotoproxy"
REPO="https://github.com/alexbers/mtprotoproxy.git"
IP=$(wget -qO- ipv4.icanhazip.com)

# ================================
# 获取端口
# ================================
read -p "请输入 MTProxy 端口（默认 10086）: " PORT
PORT=${PORT:-10086}
ok "使用端口：$PORT"

# ================================
# 生成随机 SECRET
# ================================
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
ok "生成 SECRET：$SECRET"

# ================================
# 安装 MTProxy
# ================================
echo -e "${GREEN}>> 安装 MTProxy ...${RESET}"

rm -rf $INSTALL_ROOT
mkdir -p $INSTALL_ROOT
cd /opt
git clone $REPO mtprotoproxy_temp

cp -r mtprotoproxy_temp/* $INSTALL_ROOT
rm -rf mtprotoproxy_temp

# 写入 config.py
cat > $INSTALL_ROOT/config.py <<EOF
PORT = $PORT
USERS = {"user1": "$SECRET"}
EOF

# ================================
# 创建 systemd 服务（守护增强）
# ================================
cat > /etc/systemd/system/MTProxy.service <<EOF
[Unit]
Description=MTProto Proxy Daemon
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/mtprotoproxy/mtprotoproxy.py /opt/mtprotoproxy/config.py
WorkingDirectory=/opt/mtprotoproxy
Restart=always
RestartSec=2
StartLimitBurst=100

LimitNOFILE=100000
LimitNPROC=100000

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart MTProxy
systemctl enable MTProxy

ok "MTProxy 服务已安装并运行"

# ================================
# watchdog 脚本
# ================================
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"
LOG="/var/log/mtproxy_watchdog.log"

cat > $WATCHDOG <<EOF
#!/bin/bash

SERVICE="MTProxy.service"
PORT=\$(grep PORT /opt/mtprotoproxy/config.py | grep -oE '[0-9]+')
LOG="/var/log/mtproxy_watchdog.log"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

# systemd 检查
if ! systemctl is-active --quiet \$SERVICE; then
    echo "\$(timestamp) systemd 服务未运行，正在重启..." >> \$LOG
    systemctl restart \$SERVICE
fi

# 进程检查
if ! pgrep -f "mtprotoproxy.py" > /dev/null; then
    echo "\$(timestamp) 进程丢失，正在恢复..." >> \$LOG
    systemctl restart \$SERVICE
fi

# 端口检查
if ! ss -tuln | grep -q "\$PORT"; then
    echo "\$(timestamp) 端口 \$PORT 未监听，正在修复..." >> \$LOG
    systemctl restart \$SERVICE
fi
EOF

chmod +x $WATCHDOG

# 加入 crontab 自动守护
(crontab -l 2>/dev/null | grep -v "$WATCHDOG"; echo "* * * * * $WATCHDOG >/dev/null 2>&1") | crontab -

ok "Watchdog 已安装并启动守护"

# ================================
# 安装 mtp 管理工具
# ================================
cat > /usr/local/bin/mtp <<'EOF'
#!/bin/bash

INSTALL_ROOT="/opt/mtprotoproxy"
CONF="$INSTALL_ROOT/config.py"
IP=$(wget -qO- ipv4.icanhazip.com)
SERVICE="MTProxy.service"
LOG="/var/log/mtproxy_watchdog.log"
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

menu() {
    echo -e "${GREEN}
================ MTProxy 管理菜单 ================
1) 查看状态
2) 重启服务
3) 修改端口
4) 生成新的 SECRET
5) 添加额外 SECRET
6) 输出代理连接
7) 卸载 MTProxy
-----------------------------------------------
8) 查看 watchdog 日志
9) 手动执行 watchdog 自愈
10) 安装 watchdog（自动守护）
11) 卸载 watchdog
0) 退出
=================================================${RESET}"
}

show_status() {
    echo -e "${GREEN}>>> 服务状态:${RESET}"
    systemctl status MTProxy --no-pager
    echo -e "\n${GREEN}>>> 当前配置:${RESET}"
    cat "$CONF"
}

restart_service() {
    systemctl restart MTProxy
    echo -e "${GREEN}已重启 MTProxy${RESET}"
}

change_port() {
    read -p "请输入新端口: " NEWPORT
    sed -i "s/^PORT.*/PORT = $NEWPORT/" "$CONF"
    restart_service
}

new_secret() {
    NEW=$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/user1\": \".*\"/user1\": \"$NEW\"/" "$CONF"
    restart_service
    echo -e "${GREEN}新 SECRET: $NEW${RESET}"
}

add_secret() {
    read -p "输入新用户名: " NAME
    NEW=$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/}/,\"$NAME\": \"$NEW\"}/" "$CONF"
    restart_service
}

show_links() {
    PORT=$(grep PORT "$CONF" | grep -oE '[0-9]+')
    SECRETS=$(grep -oP '"\w+": "\K[a-f0-9]+' "$CONF")

    echo -e "${YELLOW}>>> 连接信息:${RESET}"
    for S in $SECRETS; do
        echo -e "${GREEN}tg://proxy?server=$IP&port=$PORT&secret=dd$S${RESET}"
        echo "https://t.me/proxy?server=$IP&port=$PORT&secret=dd$S"
        echo "server=$IP  port=$PORT  secret=dd$S"
        echo ""
    done
}

uninstall_mtproxy() {
    systemctl stop MTProxy
    systemctl disable MTProxy
    rm -f /etc/systemd/system/MTProxy.service
    rm -rf /opt/mtprotoproxy
    echo -e "${RED}MTProxy 已卸载${RESET}"
}

install_watchdog() {
    (crontab -l 2>/dev/null | grep -v "$WATCHDOG"; echo "* * * * * $WATCHDOG >/dev/null 2>&1") | crontab -
    echo -e "${GREEN}Watchdog 已启用${RESET}"
}

uninstall_watchdog() {
    crontab -l | grep -v "$WATCHDOG" | crontab - || true
    echo -e "${YELLOW}Watchdog 已卸载${RESET}"
}

show_watchdog_log() {
    tail -n 50 "$LOG"
}

run_watchdog_once() {
    bash "$WATCHDOG"
}

while true; do
    menu
    read -p "选择功能: " CH
    case "$CH" in
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
        0) exit ;;
        *) echo -e "${RED}无效输入${RESET}" ;;
    esac
done
EOF

chmod +x /usr/local/bin/mtp
ok "管理工具 mtp 已安装"

# ================================
# 最终提示
# ================================
echo ""
echo -e "${GREEN}安装成功！使用命令： mtp${RESET}"
echo -e "${YELLOW}查看代理连接： mtp 6${RESET}"


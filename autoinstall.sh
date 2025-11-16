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
    echo -e "${GREEN}端口已修改为 $NEWPORT${RESET}"
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
    echo -e "${GREEN}已添加用户 $NAME，SECRET=$NEW${RESET}"
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

# ========== WATCHDOG 相关功能 ==========

install_watchdog() {
    cat > "$WATCHDOG" <<EOF
#!/bin/bash

SERVICE="MTProxy.service"
PORT=\$(grep PORT /opt/mtprotoproxy/config.py | grep -oE '[0-9]+')
LOG="/var/log/mtproxy_watchdog.log"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

# 检查 systemd 服务
if ! systemctl is-active --quiet \$SERVICE; then
    echo "\$(timestamp) systemd 服务未运行，正在重启..." >> \$LOG
    systemctl restart \$SERVICE
fi

# 检查进程
if ! pgrep -f "mtprotoproxy.py" > /dev/null; then
    echo "\$(timestamp) 进程丢失，正在恢复..." >> \$LOG
    systemctl restart \$SERVICE
fi

# 检查端口
if ! ss -tuln | grep -q "\$PORT"; then
    echo "\$(timestamp) 端口 \$PORT 未监听，正在修复..." >> \$LOG
    systemctl restart \$SERVICE
fi
EOF

    chmod +x "$WATCHDOG"

    (crontab -l 2>/dev/null | grep -v "$WATCHDOG"; echo "* * * * * $WATCHDOG >/dev/null 2>&1") | crontab -

    echo -e "${GREEN}Watchdog 已安装并加入 crontab 守护！${RESET}"
}

uninstall_watchdog() {
    crontab -l | grep -v "$WATCHDOG" | crontab - || true
    rm -f "$WATCHDOG"
    echo -e "${YELLOW}Watchdog 已卸载${RESET}"
}

show_watchdog_log() {
    echo -e "${GREEN}>>> Watchdog 日志:${RESET}"
    if [ -f "$LOG" ]; then
        tail -n 50 "$LOG"
    else
        echo -e "${YELLOW}日志不存在${RESET}"
    fi
}

run_watchdog_once() {
    echo -e "${GREEN}执行 watchdog 检查...${RESET}"
    bash "$WATCHDOG"
    echo -e "${GREEN}完成${RESET}"
}

# ========== 主菜单循环 ==========

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

#!/bin/bash

# ==========================================
# 彩色
# ==========================================
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK] $1${RESET}"; }
warn(){ echo -e "${YELLOW}[WARN] $1${RESET}"; }
err(){ echo -e "${RED}[ERROR] $1${RESET}"; }

# ==========================================
# 基准目录（当前目录）
# ==========================================
ABS=$(readlink -f "$0")
BASE_DIR=$(dirname "$ABS")
INSTALL_ROOT="$BASE_DIR/mtprotoproxy"

# ==========================================
# 安装依赖
# ==========================================
ok "更新软件源..."
apt update -y
apt install -y git wget xxd python3 python3-pip htop

# ==========================================
# 输入端口
# ==========================================
read -p "请输入 MTProxy 端口（默认 10086）: " PORT
PORT=${PORT:-10086}
ok "端口：$PORT"

# ==========================================
# 获取公网 IP + secret
# ==========================================
IP=$(wget -qO- ipv4.icanhazip.com)
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
ok "公网IP：$IP"
ok "生成SECRET：$SECRET"

# ==========================================
# 下载 MTProtoProxy 到当前目录
# ==========================================
ok "下载 MTProtoProxy 到：$INSTALL_ROOT ..."
rm -rf "$INSTALL_ROOT"
git clone https://github.com/alexbers/mtprotoproxy.git "$INSTALL_ROOT"

# 生成 config.py
cat > "$INSTALL_ROOT/config.py" <<EOF
PORT = $PORT
USERS = {"user1": "$SECRET"}
EOF
ok "写入配置：$INSTALL_ROOT/config.py"

# ==========================================
# systemd 服务文件（基于当前目录）
# ==========================================
SERVICE="/etc/systemd/system/MTProxy.service"

cat > "$SERVICE" <<EOF
[Unit]
Description=MTProto Proxy (local dir)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_ROOT/mtprotoproxy.py $INSTALL_ROOT/config.py
WorkingDirectory=$INSTALL_ROOT
Restart=always
RestartSec=2
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart MTProxy
systemctl enable MTProxy
ok "systemd 服务启动完成"

# ==========================================
# watchdog 自愈脚本
# ==========================================
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"
LOG="/var/log/mtproxy_watchdog.log"

cat > "$WATCHDOG" <<EOF
#!/bin/bash
CONF="$INSTALL_ROOT/config.py"
SERVICE="MTProxy.service"
LOG="/var/log/mtproxy_watchdog.log"

timestamp(){ date "+%Y-%m-%d %H:%M:%S"; }

PORT=\$(grep PORT "\$CONF" | grep -oE '[0-9]+')

# systemd 状态
if ! systemctl is-active --quiet "\$SERVICE"; then
    echo "\$(timestamp) systemd 停止，修复中..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi

# 进程是否存在
if ! pgrep -f "mtprotoproxy.py" >/dev/null; then
    echo "\$(timestamp) 进程丢失，修复中..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi

# 端口是否监听
if ! ss -tuln | grep -q "\$PORT"; then
    echo "\$(timestamp) 端口 \$PORT 未监听，修复中..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi
EOF

chmod +x "$WATCHDOG"

(crontab -l 2>/dev/null | grep -v "$WATCHDOG"; echo "* * * * * $WATCHDOG >/dev/null 2>&1") | crontab -
ok "安装 watchdog 完成"

# ==========================================
# 安装 mtp 管理命令
# ==========================================
cat > /usr/local/bin/mtp <<EOF
#!/bin/bash

INSTALL_ROOT="$INSTALL_ROOT"
CONF="\$INSTALL_ROOT/config.py"
IP=\$(wget -qO- ipv4.icanhazip.com)
SERVICE="MTProxy.service"
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"
LOG="/var/log/mtproxy_watchdog.log"

GREEN="\\e[32m"; YELLOW="\\e[33m"; RED="\\e[31m"; RESET="\\e[0m"

menu(){
echo -e "\${GREEN}
=============== MTProxy 管理菜单 ===============
1) 查看状态
2) 重启 MTProxy
3) 修改端口
4) 生成新的 SECRET
5) 添加额外 SECRET
6) 输出代理连接
7) 卸载 MTProxy
--------------------------------------------
8) 查看 watchdog 日志
9) 手动执行 watchdog
0) 退出
==============================================\${RESET}"
}

show_status(){
    systemctl status "\$SERVICE" --no-pager
    echo ""
    cat "\$CONF"
}

restart_service(){
    systemctl restart "\$SERVICE"
    echo -e "\${GREEN}已重启\${RESET}"
}

change_port(){
    read -p "新端口: " NEW
    sed -i "s/^PORT.*/PORT = \$NEW/" "\$CONF"
    restart_service
}

new_secret(){
    NEW=\$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/user1\": \".*\"/user1\": \"\$NEW\"/" "\$CONF"
    restart_service
    echo "新的 secret: \$NEW"
}

add_secret(){
    read -p "新用户名: " NAME
    NEW=\$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/}/,\"\$NAME\": \"\$NEW\"}/" "\$CONF"
    restart_service
    echo "添加 \$NAME = \$NEW"
}

show_links(){
    PORT=\$(grep PORT "\$CONF" | grep -oE '[0-9]+')
    SECRETS=\$(grep -oP '"\\w+": "\\K[a-f0-9]+' "\$CONF")

    for S in \$SECRETS; do
        echo "tg://proxy?server=\$IP&port=\$PORT&secret=dd\$S"
        echo "https://t.me/proxy?server=\$IP&port=\$PORT&secret=dd\$S"
        echo ""
    done
}

show_watchdog_log(){
    tail -n 50 "\$LOG"
}

run_watchdog_once(){
    bash "\$WATCHDOG"
}

uninstall_mtproxy(){
    systemctl stop "\$SERVICE"
    systemctl disable "\$SERVICE"
    rm -rf "\$INSTALL_ROOT"
    rm -f "/etc/systemd/system/\$SERVICE"
    echo -e "\${RED}已卸载 MTProxy\${RESET}"
}

# ===== 主菜单循环 =====
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
        0) exit 0 ;;
        *) echo -e "\${RED}无效输入\${RESET}" ;;
    esac
done
EOF

chmod +x /usr/local/bin/mtp
ok "管理工具已安装（执行：mtp）"

echo ""
ok "✨ 安装完成！"
echo -e "${GREEN}➡ 运行：  mtp${RESET}"
echo -e "${YELLOW}➡ 查看代理链接： 在菜单中选择 6${RESET}"

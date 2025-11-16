#!/bin/bash

# ======================================================
# 彩色输出
# ======================================================
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK] $1${RESET}"; }
err(){ echo -e "${RED}[ERROR] $1${RESET}"; }

# ======================================================
# 基准路径（以当前目录为根目录）
# ======================================================
ABS=$(readlink -f "$0")
BASE_DIR=$(dirname "$ABS")
INSTALL_ROOT="$BASE_DIR/mtprotoproxy"

# ======================================================
# 安装依赖
# ======================================================
ok "安装依赖中..."
apt update -y
apt install -y git wget xxd python3 python3-pip htop >/dev/null 2>&1

# ======================================================
# 输入端口
# ======================================================
read -p "请输入 MTProxy 端口（默认 10086）: " PORT
PORT=${PORT:-10086}
ok "端口：$PORT"

# ======================================================
# 生成 32 / 64 bit secret
# ======================================================
SECRET32=$(head -c 16 /dev/urandom | xxd -ps)
SECRET64=$(head -c 32 /dev/urandom | xxd -ps)

ok "生成 32 位 Secret：$SECRET32"
ok "生成 64 位 Secret：$SECRET64"

# ======================================================
# 获取公网 IP
# ======================================================
IP=$(wget -qO- ipv4.icanhazip.com)
ok "公网 IP：$IP"

# ======================================================
# 下载 MTProxy 到当前目录
# ======================================================
rm -rf "$INSTALL_ROOT"
git clone https://github.com/alexbers/mtprotoproxy.git "$INSTALL_ROOT"

# ======================================================
# 写入 config.py （两个 secret）
# ======================================================
cat > "$INSTALL_ROOT/config.py" <<EOF
PORT = $PORT
USERS = {
    "user32": "$SECRET32",
    "user64": "$SECRET64"
}
EOF

ok "配置文件已写入：$INSTALL_ROOT/config.py"

# ======================================================
# systemd 服务（基于当前目录）
# ======================================================
SERVICE="/etc/systemd/system/MTProxy.service"

cat > "$SERVICE" <<EOF
[Unit]
Description=MTProto Proxy (Local)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_ROOT/mtprotoproxy.py $INSTALL_ROOT/config.py
Restart=always
RestartSec=2
WorkingDirectory=$INSTALL_ROOT
LimitNOFILE=200000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart MTProxy
systemctl enable MTProxy
ok "systemd 服务已启动"

# ======================================================
# watchdog（基于当前目录）
# ======================================================
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"
LOG="/var/log/mtproxy_watchdog.log"

cat > "$WATCHDOG" <<EOF
#!/bin/bash
CONF="$INSTALL_ROOT/config.py"
SERVICE="MTProxy.service"
LOG="/var/log/mtproxy_watchdog.log"

timestamp(){ date "+%Y-%m-%d %H:%M:%S"; }
PORT=\$(grep PORT "\$CONF" | grep -oE '[0-9]+')

if ! systemctl is-active --quiet "\$SERVICE"; then
    echo "\$(timestamp) systemd 服务停止，修复中..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi

if ! pgrep -f "mtprotoproxy.py" >/dev/null; then
    echo "\$(timestamp) 进程丢失，修复中..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi

if ! ss -tuln | grep -q "\$PORT"; then
    echo "\$(timestamp) 端口 \$PORT 未监听，修复中..." >> "\$LOG"
    systemctl restart "\$SERVICE"
fi
EOF

chmod +x "$WATCHDOG"
(
    crontab -l 2>/dev/null | grep -v "$WATCHDOG"
    echo "* * * * * $WATCHDOG >/dev/null 2>&1"
) | crontab -

ok "watchdog 已安装并启用"

# ======================================================
# 安装 mtp 管理工具
# ======================================================
cat > /usr/local/bin/mtp <<EOF
#!/bin/bash

INSTALL_ROOT="$INSTALL_ROOT"
CONF="\$INSTALL_ROOT/config.py"
IP=\$(wget -qO- ipv4.icanhazip.com)
SERVICE="MTProxy.service"
LOG="/var/log/mtproxy_watchdog.log"
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"

GREEN="\\e[32m"; RESET="\\e[0m"

menu(){
echo -e "\${GREEN}
=============== MTProxy 管理菜单 ===============
1) 查看状态
2) 输出连接（含 32/64 位 secret）
3) 重启服务
4) 修改端口
5) 新建 Secret（重置 32 位）
6) 添加 Secret（追加用户）
7) 卸载 MTProxy
----------------------------------------------
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

show_links(){
    PORT=\$(grep PORT "\$CONF" | grep -oE '[0-9]+')
    SECRETS=\$(grep -oP '"\\w+": "\\K[a-f0-9]+' "\$CONF")

    for S in \$SECRETS; do
        echo "tg://proxy?server=\$IP&port=\$PORT&secret=dd\$S"
        echo "https://t.me/proxy?server=\$IP&port=\$PORT&secret=dd\$S"
        echo ""
    done
}

restart_service(){
    systemctl restart "\$SERVICE"
}

change_port(){
    read -p "新端口: " NEW
    sed -i "s/^PORT.*/PORT = \$NEW/" "\$CONF"
    restart_service
}

new_secret(){
    NEW=\$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/user32\": \".*\"/user32\": \"\$NEW\"/" "\$CONF"
    restart_service
    echo "新的 SECRET32：\$NEW"
}

add_secret(){
    read -p "新用户名: " NAME
    NEW=\$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/}/,\"\$NAME\": \"\$NEW\"}/" "\$CONF"
    restart_service
    echo "已添加：\$NAME=\$NEW"
}

show_log(){
    tail -n 50 "\$LOG"
}

run_watchdog(){
    bash "\$WATCHDOG"
}

uninstall_mtproxy(){
    systemctl stop "\$SERVICE"
    systemctl disable "\$SERVICE"
    rm -rf "\$INSTALL_ROOT"
    rm -f "/etc/systemd/system/\$SERVICE"
    echo "MTProxy 已卸载"
}

while true; do
    menu
    read -p "选择功能：" CH
    case "\$CH" in
        1) show_status ;;
        2) show_links ;;
        3) restart_service ;;
        4) change_port ;;
        5) new_secret ;;
        6) add_secret ;;
        7) uninstall_mtproxy ;;
        8) show_log ;;
        9) run_watchdog ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done
EOF

chmod +x /usr/local/bin/mtp
ok "管理工具 mtp 已安装"

# ======================================================
# 安装完成后自动显示连接（含 JSON 输出）
# ======================================================

echo ""
echo -e "${GREEN}================= MTProxy 安装完成 =================${RESET}"
echo ""
echo -e "${YELLOW}>>> 公网 IP：${RESET} $IP"
echo -e "${YELLOW}>>> 端口：${RESET} $PORT"
echo ""

# ------------------ 32 位 ------------------
echo -e "${GREEN}------ 32 位 Secret ------${RESET}"
echo "Secret32: $SECRET32"
LINK32_TG="tg://proxy?server=$IP&port=$PORT&secret=dd$SECRET32"
LINK32_HTTP="https://t.me/proxy?server=$IP&port=$PORT&secret=dd$SECRET32"
echo "$LINK32_TG"
echo "$LINK32_HTTP"
echo ""

# ------------------ 64 位 ------------------
echo -e "${GREEN}------ 64 位 Secret ------${RESET}"
echo "Secret64: $SECRET64"
LINK64_TG="tg://proxy?server=$IP&port=$PORT&secret=dd$SECRET64"
LINK64_HTTP="https://t.me/proxy?server=$IP&port=$PORT&secret=dd$SECRET64"
echo "$LINK64_TG"
echo "$LINK64_HTTP"
echo ""

echo -e "${GREEN}=======================================================${RESET}"

# ------------------ JSON 输出 ------------------
cat <<EOF

JSON 输出（可供程序读取）：

{
  "ip": "$IP",
  "port": $PORT,
  "secret32": "$SECRET32",
  "secret64": "$SECRET64",
  "links": {
    "tg32": "$LINK32_TG",
    "tg64": "$LINK64_TG",
    "http32": "$LINK32_HTTP",
    "http64": "$LINK64_HTTP"
  }
}

EOF

# 等待回车进入 mtp
read -p "按 Enter 键进入 MTProxy 管理菜单（mtp）..." _

mtp

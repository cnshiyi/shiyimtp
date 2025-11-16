#!/bin/bash
# ================================================
#   MTProxy 一键自动安装脚本  autoinstall.sh
# ================================================

set -e

INSTALL_ROOT="/opt/mtprotoproxy"
GIT_REPO="https://github.com/alexbers/mtprotoproxy.git"
CHECK_FILE="/etc/mtproxy_installed.flag"

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK] $1${RESET}"; }
err(){ echo -e "${RED}[ERROR] $1${RESET}"; }

IP=$(wget -qO- ipv4.icanhazip.com)

if [ -f "$CHECK_FILE" ]; then
    err "MTProxy 已安装。如需重装请执行： rm $CHECK_FILE"
    exit 1
fi

read -p "请输入 MTProxy 端口（默认 10086）： " PORT
PORT=${PORT:-10086}

SECRET=$(head -c 16 /dev/urandom | xxd -ps)

echo "----------------------------------------------"
echo "IP: $IP"
echo "端口: $PORT"
echo "密钥: $SECRET"
echo "----------------------------------------------"

apt update -y
apt install -y git wget python3 python3-pip xxd

rm -rf "$INSTALL_ROOT"
git clone -b master "$GIT_REPO" "$INSTALL_ROOT"

cat > "$INSTALL_ROOT/config.py" <<EOF
PORT = ${PORT}
USERS = {"tg": "${SECRET}"}
EOF

cat >/etc/systemd/system/MTProxy.service <<EOF
[Unit]
Description=MTProxy Server
After=network.target

[Service]
WorkingDirectory=$INSTALL_ROOT
ExecStart=/usr/bin/python3 mtprotoproxy.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/usr/local/bin/mtproxy_watchdog.sh <<EOF
#!/bin/bash
if ! systemctl is-active --quiet MTProxy; then
    systemctl restart MTProxy
fi
EOF
chmod +x /usr/local/bin/mtproxy_watchdog.sh

cat >/etc/systemd/system/mtproxy-watchdog.service <<EOF
[Unit]
Description=MTProxy Auto Restart Watchdog
After=MTProxy.service

[Service]
ExecStart=/usr/local/bin/mtproxy_watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now MTProxy
systemctl enable --now mtproxy-watchdog.service

# ================================
# 生成 MTProxy 管理工具 MTP
# ================================
cat >/usr/local/bin/mtp <<'EOF'
#!/bin/bash

CONF=/opt/mtprotoproxy/config.py
IP=$(wget -qO- ipv4.icanhazip.com)

PORT=$(grep -oP "^PORT\s*=\s*\K[0-9]+" "$CONF")
SECRET=$(grep 'USERS' "$CONF" | sed -E 's/.*"tg":\s*"([0-9a-f]+)".*/\1/')
TG_LINK="https://t.me/proxy?server=${IP}&port=${PORT}&secret=dd${SECRET}"

menu() {
  clear
  echo "============== MTProxy 管理工具 =============="
  echo "1) 查看状态"
  echo "2) 启动 MTProxy"
  echo "3) 停止 MTProxy"
  echo "4) 重启 MTProxy"
  echo "5) 查看日志"
  echo "6) 查看连接信息"
  echo "0) 退出"
  echo "=============================================="
  echo -n "请选择操作: "
}

while true; do
    menu
    read -r CH

    case "$CH" in
        1) systemctl status MTProxy --no-pager;;
        2) systemctl start MTProxy;;
        3) systemctl stop MTProxy;;
        4) systemctl restart MTProxy;;
        5) journalctl -u MTProxy -f;;
        6)
            echo "======== MTProxy 连接信息 ========"
            echo "IP: $IP"
            echo "Port: $PORT"
            echo "Secret: $SECRET"
            echo ""
            echo "Telegram 代理链接："
            echo "$TG_LINK"
            echo "================================="
            ;;
        0) exit 0;;
        *) echo "无效选项";;
    esac
    echo ""
    read -p "按回车继续..."
done
EOF

chmod +x /usr/local/bin/mtp

echo "installed" > $CHECK_FILE

TG_LINK="https://t.me/proxy?server=${IP}&port=${PORT}&secret=dd${SECRET}"

echo ""
echo "==============================================="
echo "  🎉 MTProxy 安装成功！"
echo "==============================================="
echo "公网 IP:     $IP"
echo "端口:        $PORT"
echo "Secret32:    $SECRET"
echo ""
echo "👉 Telegram 代理链接："
echo "$TG_LINK"
echo ""
echo "👉 管理工具： mtp"
echo "==============================================="
exit 0

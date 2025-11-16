#!/bin/bash
set -e

INSTALL_ROOT="/opt/mtprotoproxy"
GIT_REPO="https://github.com/alexbers/mtprotoproxy.git"
CHECK_FILE="/etc/mtproxy_installed.flag"

# ----------------------------------------
# 安装依赖
# ----------------------------------------
install_dependencies() {
    echo "📦 正在安装依赖..."
    PKGS="git wget python3 python3-pip xxd"

    apt update -y
    for pkg in $PKGS; do
        dpkg -s "$pkg" >/dev/null 2>&1 || apt install -y "$pkg"
    done
}
install_dependencies

# ----------------------------------------
# 公网 IP
# ----------------------------------------
IP=$(wget -qO- ipv4.icanhazip.com)

# ----------------------------------------
# 安装检查
# ----------------------------------------
if [ -f "$CHECK_FILE" ]; then
    echo "⚠️  检测到 MTProxy 已安装，如需重新安装： rm $CHECK_FILE"
    exit 1
fi

# ----------------------------------------
# 输入端口
# ----------------------------------------
read -p "请输入 MTProxy 端口（默认 10086）: " PORT
PORT=${PORT:-10086}

# ----------------------------------------
# 自动生成 32 位密钥
# ----------------------------------------
SECRET=$(head -c 16 /dev/urandom | xxd -ps)

# ----------------------------------------
# 下载 MTProxy
# ----------------------------------------
rm -rf "$INSTALL_ROOT"
git clone -b master "$GIT_REPO" "$INSTALL_ROOT"

# ----------------------------------------
# 写入 config.py
# ----------------------------------------
cat > "$INSTALL_ROOT/config.py" <<EOF
PORT = ${PORT}
USERS = {"tg": "${SECRET}"}
EOF

# ----------------------------------------
# 创建 systemd 服务
# ----------------------------------------
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


# ----------------------------------------
# 创建 Watchdog
# ----------------------------------------
cat >/usr/local/bin/mtproxy_watchdog.sh <<'EOF'
#!/bin/bash
if ! systemctl is-active --quiet MTProxy; then
    systemctl restart MTProxy
fi
EOF
chmod +x /usr/local/bin/mtproxy_watchdog.sh

cat >/etc/systemd/system/mtproxy-watchdog.service <<EOF
[Unit]
Description=MTProxy Watchdog
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

# ----------------------------------------
# 管理工具（使用强引用 EOF 避免污染）
# ----------------------------------------
cat >/usr/local/bin/mtp <<'EOF'
#!/bin/bash

CONF=/opt/mtprotoproxy/config.py
IP=$(wget -qO- ipv4.icanhazip.com)

PORT=$(grep -oP "(?<=PORT\s*=\s*)\d+" "$CONF")
SECRET=$(grep -oP '(?<=(\"|'"'"')tg(\"|'"'"')\s*:\s*(\"|'"'"'))[0-9a-f]{32}(?=(\"|'"'"'))' "$CONF")

TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=dd${SECRET}"

clear
echo "============== MTProxy 管理工具 =============="
echo "IP: $IP"
echo "端口: $PORT"
echo "密钥: $SECRET"
echo "链接: $TG_LINK"
echo ""
echo "1) 查看状态"
echo "2) 启动"
echo "3) 停止"
echo "4) 重启"
echo "5) 查看日志"
echo "0) 退出"
echo "=============================================="
read -p "选择操作: " CH

case "$CH" in
1) systemctl status MTProxy --no-pager;;
2) systemctl start MTProxy;;
3) systemctl stop MTProxy;;
4) systemctl restart MTProxy;;
5) journalctl -u MTProxy -f;;
*) exit 0;;
esac
EOF

chmod +x /usr/local/bin/mtp

# 安装标记
echo "installed" > $CHECK_FILE

# ----------------------------------------
# 安装完成，安全输出
# ----------------------------------------
TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=dd${SECRET}"

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

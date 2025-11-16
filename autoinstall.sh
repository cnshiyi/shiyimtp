#!/usr/bin/env bash
set -e

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

INSTALL_ROOT="/opt/mtprotoproxy"
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"
MTP_CLI="/usr/local/bin/mtp"

apt update -y
apt install -y git wget curl xxd python3 python3-pip systemctl || true

# --------------------------
# 获取公网 IP
# --------------------------
IP=$(wget -qO- ipv4.icanhazip.com || curl -s ipv4.icanhazip.com)
echo -e "${GREEN}[OK] 公网 IP：$IP${RESET}"

# --------------------------
# 生成 Secret
# --------------------------
SECRET32=$(head -c 32 /dev/urandom | xxd -ps)
SECRET64=$(head -c 64 /dev/urandom | xxd -ps)

echo -e "${GREEN}[OK] 32 位 Secret：$SECRET32${RESET}"
echo -e "${GREEN}[OK] 64 位 Secret：$SECRET64${RESET}"

# --------------------------
# 下载 MTProxy 源码
# --------------------------
rm -rf "$INSTALL_ROOT"
git clone https://github.com/alexbers/mtprotoproxy "$INSTALL_ROOT"

echo -e "${GREEN}[OK] 配置文件写入：$INSTALL_ROOT/config.py${RESET}"

# --------------------------
# 写入配置文件
# --------------------------
cat > "$INSTALL_ROOT/config.py" <<EOF
PORT = 443
USERS = {
    "user1": "$SECRET32"
}
MODENAME = "MTProxy"
FAKE_TLS_DOMAIN = ""
EOF

# --------------------------
# 创建 systemd 服务
# --------------------------
cat > /etc/systemd/system/MTProxy.service <<EOF
[Unit]
Description=MTProxy Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_ROOT
ExecStart=/usr/bin/python3 $INSTALL_ROOT/mtprotoproxy.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable MTProxy
systemctl restart MTProxy
echo -e "${GREEN}[OK] MTProxy 服务已启动${RESET}"

# --------------------------
# 写 watchdog（自愈）
# --------------------------
cat > "$WATCHDOG" <<EOF
#!/bin/bash
SERVICE="MTProxy.service"
PORT=\$(grep PORT /opt/mtprotoproxy/config.py | grep -oE '[0-9]+')
LOG="/var/log/mtproxy_watchdog.log"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

if ! systemctl is-active --quiet \$SERVICE; then
    echo "\$(timestamp) systemd 未运行 → 正在重启" >> \$LOG
    systemctl restart \$SERVICE
fi

if ! pgrep -f "mtprotoproxy.py" >/dev/null; then
    echo "\$(timestamp) 进程丢失 → 正在恢复" >> \$LOG
    systemctl restart \$SERVICE
fi

if ! ss -tuln | grep -q ":\$PORT "; then
    echo "\$(timestamp) 端口 \$PORT 未监听 → 正在修复" >> \$LOG
    systemctl restart \$SERVICE
fi
EOF

chmod +x "$WATCHDOG"

# 避免未安装 cron 报错
if command -v crontab >/dev/null; then
    (crontab -l 2>/dev/null | grep -v "$WATCHDOG"; echo "* * * * * $WATCHDOG >/dev/null 2>&1") | crontab -
    echo -e "${GREEN}[OK] Watchdog 已加入 crontab${RESET}"
else
    echo -e "${YELLOW}[WARN] 未找到 crontab，watchdog 未启用${RESET}"
fi

# --------------------------
# 写入 mtp 管理工具
# --------------------------
cat > "$MTP_CLI" <<EOF
#!/usr/bin/env bash
/usr/local/bin/mtp_menu_internal
EOF

chmod +x "$MTP_CLI"

# --------------------------
# 内部菜单脚本
# --------------------------
cat > /usr/local/bin/mtp_menu_internal <<'EOF'
#!/usr/bin/env bash
echo -e "\e[32m
================ MTProxy 管理菜单 ================
1) 查看状态
2) 输出代理连接
3) 重启服务
0) 退出
=================================================\e[0m"

read -p "选择功能: " CH
case $CH in
    1) systemctl status MTProxy;;
    2) IP=$(wget -qO- ipv4.icanhazip.com)
       PORT=$(grep PORT /opt/mtprotoproxy/config.py | grep -oE '[0-9]+')
       SECRET=$(grep -oE '"user1": "[a-f0-9]+"' /opt/mtprotoproxy/config.py | awk -F'"' '{print $4}')
       echo "tg://proxy?server=$IP&port=$PORT&secret=dd$SECRET"
       ;;
    3) systemctl restart MTProxy;;
    *) exit;;
esac
EOF

chmod +x /usr/local/bin/mtp_menu_internal

echo -e "${GREEN}[OK] 管理工具 mtp 已安装${RESET}"

# --------------------------
# 输出连接
# --------------------------
echo -e "${GREEN}
========== 安装完成 ==========
IP: $IP
Port: 443

MTProto 链接（32位）：
tg://proxy?server=$IP&port=443&secret=dd$SECRET32

MTProto 链接（64位）：
tg://proxy?server=$IP&port=443&secret=dd$SECRET64
==============================
${RESET}"

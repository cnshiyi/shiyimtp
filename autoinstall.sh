#!/usr/bin/env bash
set -e

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

INSTALL_ROOT="/opt/mtprotoproxy"
WATCHDOG="/usr/local/bin/watchdog_mtp.sh"
MTP_CLI="/usr/local/bin/mtp"

echo -e "${GREEN}[OK] 安装依赖${RESET}"
apt update -y
apt install -y git wget curl xxd python3 python3-pip cron || true

# 获取公网 IP
IP=$(curl -s ipv4.icanhazip.com)
echo -e "${GREEN}[OK] 公网 IP：$IP${RESET}"

# 生成 Secret
SECRET32=$(head -c 32 /dev/urandom | xxd -ps)
SECRET64=$(head -c 64 /dev/urandom | xxd -ps)

echo -e "${GREEN}[OK] 生成 32 位 Secret：$SECRET32${RESET}"
echo -e "${GREEN}[OK] 生成 64 位 Secret：$SECRET64${RESET}"

# 下载源码
rm -rf "$INSTALL_ROOT"
git clone https://github.com/alexbers/mtprotoproxy "$INSTALL_ROOT"

# 写配置
cat > "$INSTALL_ROOT/config.py" <<EOF
PORT = 443
USERS = {
    "user1": "$SECRET32"
}
MODENAME = "MTProxy"
FAKE_TLS_DOMAIN = ""
EOF

echo -e "${GREEN}[OK] 配置文件已写入：$INSTALL_ROOT/config.py${RESET}"

# 写 systemd 服务
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

# 写 watchdog
cat > "$WATCHDOG" <<EOF
#!/bin/bash
SERVICE="MTProxy.service"
PORT=\$(grep -oE "[0-9]+" <<< "\$(grep PORT /opt/mtprotoproxy/config.py)")
LOG="/var/log/mtproxy_watchdog.log"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

if ! systemctl is-active --quiet \$SERVICE; then
    echo "\$(timestamp) systemd 未运行 → 重启" >> \$LOG
    systemctl restart \$SERVICE
fi

if ! pgrep -f "mtprotoproxy.py" >/dev/null; then
    echo "\$(timestamp) 进程丢失 → 恢复" >> \$LOG
    systemctl restart \$SERVICE
fi

if ! ss -tuln | grep -q ":\$PORT "; then
    echo "\$(timestamp) 端口 \$PORT 未监听 → 修复" >> \$LOG
    systemctl restart \$SERVICE
fi
EOF

chmod +x "$WATCHDOG"

# 加入 crontab
if command -v crontab >/dev/null; then
    (crontab -l 2>/dev/null | grep -v "$WATCHDOG"; echo "* * * * * $WATCHDOG >/dev/null 2>&1") | crontab -
    echo -e "${GREEN}[OK] watchdog 已安装${RESET}"
else
    echo -e "${YELLOW}[WARN] crontab 未安装，跳过 watchdog${RESET}"
fi

# 写管理脚本（无颜色、无错乱、无 -e）
cat > "$MTP_CLI" <<EOF
#!/usr/bin/env bash

IP=\$(curl -s ipv4.icanhazip.com)
PORT=\$(grep -oE "[0-9]+" <<< "\$(grep PORT /opt/mtprotoproxy/config.py)")
SECRET=\$(grep -oE '"user1": "[a-f0-9]+"' /opt/mtprotoproxy/config.py | awk -F'"' '{print \$4}')

echo "===== MTProxy 管理菜单 ====="
echo "1) 查看状态"
echo "2) 查看连接"
echo "3) 重启服务"
echo "0) 退出"
echo "==========================="
read -p '选择功能: ' CH

case \$CH in
    1) systemctl status MTProxy;;
    2) 
        echo \"tg://proxy?server=\$IP&port=\$PORT&secret=dd\$SECRET\"
        ;;
    3) systemctl restart MTProxy;;
    0) exit;;
esac
EOF

chmod +x "$MTP_CLI"

# 输出最终信息
echo -e "${GREEN}
=========== 安装完成 ===========
服务器 IP：$IP
端口：443

MTProto 链接（32 位）：
tg://proxy?server=$IP&port=443&secret=dd$SECRET32

MTProto 链接（64 位）：
tg://proxy?server=$IP&port=443&secret=dd$SECRET64
================================
${RESET}"

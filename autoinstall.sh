#!/bin/sh

set -e

sudo apt update && sudo apt install -y git curl wget xxd

echo '\n--------------------------------------'
echo '        CLONING REPOSITORY'
echo '--------------------------------------\n'

if [ ! -d mtproxy_autoinstaller ]; then
    git clone -b stable https://github.com/aire1/mtproxy_autoinstaller
fi

cd mtproxy_autoinstaller || exit 1

sudo chmod ugo+x install.sh socks_install.sh set_AD_TAG.sh

echo '\n--------------------------------------'
echo '        CONFIGURE MTPROXY'
echo '--------------------------------------\n'

###############################################################################
#                              执行原安装脚本
###############################################################################
./install.sh

###############################################################################
#                           创建 systemd 自动守护
###############################################################################
echo '\n--------------------------------------'
echo '      SETUP SYSTEMD AUTO WATCHDOG'
echo '--------------------------------------\n'

cat >/usr/local/bin/mtproxy_watchdog.sh <<EOF
#!/bin/bash
if ! systemctl is-active --quiet MTProxy; then
    systemctl restart MTProxy
fi
EOF

chmod +x /usr/local/bin/mtproxy_watchdog.sh

cat >/etc/systemd/system/mtproxy-watchdog.service <<EOF
[Unit]
Description=MTProxy Auto Watchdog
After=network.target

[Service]
ExecStart=/usr/local/bin/mtproxy_watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtproxy-watchdog.service

###############################################################################
#                           读取连接信息并输出
###############################################################################
CONF=/opt/mtprotoproxy/config.py

IP=$(curl -s ipv4.ip.sb)
PORT=$(grep -oP "(?<=PORT = ).*" $CONF | tr -d "'")
SECRET=$(grep -oP "(?<=SECRET = ).*" $CONF | tr -d "'")

TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=dd${SECRET}"
echo "\n--------------------------------------"
echo "            INSTALL FINISHED "
echo "--------------------------------------"
echo "Public IP:     $IP"
echo "Port:          $PORT"
echo "Secret:        $SECRET"
echo "Telegram Link: $TG_LINK"

###############################################################################
#                           管理工具 mtp
###############################################################################
echo '\n--------------------------------------'
echo '         INSTALL MANAGEMENT TOOL'
echo '--------------------------------------\n'

cat >/usr/local/bin/mtp <<'EOF'
#!/bin/bash

CONF=/opt/mtprotoproxy/config.py
IP=$(curl -s ipv4.ip.sb)
PORT=$(grep -oP "(?<=PORT = ).*" $CONF | tr -d "'")
SECRET=$(grep -oP "(?<=SECRET = ).*" $CONF | tr -d "'")
TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=dd${SECRET}"

menu() {
  clear
  echo "============== MTProxy 管理工具 =============="
  echo "1) 查看状态"
  echo "2) 启动 MTProxy"
  echo "3) 停止 MTProxy"
  echo "4) 重启 MTProxy"
  echo "5) 查看日志"
  echo "6) 查看连接链接"
  echo "0) 退出"
  echo "=============================================="
  echo -n "请选择操作: "
}

while true; do
    menu
    read -r CH

    case "$CH" in
    1)
        systemctl status MTProxy --no-pager
        ;;
    2)
        systemctl start MTProxy
        echo "已启动 MTProxy"
        ;;
    3)
        systemctl stop MTProxy
        echo "已停止 MTProxy"
        ;;
    4)
        systemctl restart MTProxy
        echo "已重启 MTProxy"
        ;;
    5)
        journalctl -u MTProxy -f
        ;;
    6)
        echo "============== MTProxy 连接信息 =============="
        echo "IP: $IP"
        echo "Port: $PORT"
        echo "Secret: $SECRET"
        echo "连接链接:"
        echo "$TG_LINK"
        echo "=============================================="
        ;;
    0)
        exit 0
        ;;
    *)
        echo "输入无效，请重试..."
        ;;
    esac

    echo -e "\n按回车继续..."
    read -r
done
EOF

chmod +x /usr/local/bin/mtp

echo '\n--------------------------------------'
echo '            ALL DONE!'
echo '--------------------------------------'
echo "管理工具：  mtp"
echo "查看链接：  mtp -> 6"
echo "自动守护：  systemctl status mtproxy-watchdog"
echo "MTProxy：   systemctl status MTProxy"

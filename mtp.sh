#!/bin/bash
# ============================================================
# Cloudflare WARP + FakeTLS (ee) + MTG
# 一键安装脚本（带进程守护 + 启动脚本 + 自动检测）
# 无 GitLab 地址版本（彻底修复 403）
# ============================================================

set -e

GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
err(){ echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "请使用 root 用户运行"

# ------------------------------------------------------------
# 安装依赖
# ------------------------------------------------------------
apt update -y >/dev/null 2>&1 || true
apt install -y curl wget sudo xxd tar git make >/dev/null 2>&1 || \
err "无法安装基础依赖"

# ------------------------------------------------------------
# 安装 Cloudflare WARP（使用安全镜像源，彻底替代 GitLab）
# ------------------------------------------------------------
ok "安装 Cloudflare WARP..."

# 主源
wget -N https://cdn.jsdelivr.net/gh/fscarmen/warp/menu.sh -O warp.sh \
|| wget -N https://raw.githubusercontent.com/fscarmen/warp/main/menu.sh -O warp.sh \
|| err "无法下载 WARP 安装脚本，请检查网络"

chmod +x warp.sh

echo "1" | bash warp.sh >/dev/null 2>&1
echo "2" | bash warp.sh >/dev/null 2>&1

warp_status=$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep warp | cut -d= -f2)
[[ "$warp_status" != "on" ]] && err "WARP 启动失败"

ok "WARP 已启用（全局走 Cloudflare 节点）"

# ------------------------------------------------------------
# 端口
# ------------------------------------------------------------
read -p "请输入 MTProto 监听端口（默认 443）: " MTG_PORT
MTG_PORT=${MTG_PORT:-443}

# ------------------------------------------------------------
# FakeTLS 域名池
# ------------------------------------------------------------
DOMAINS=(
  "fonts.gstatic.com"
  "developer.apple.com"
  "support.apple.com"
  "api.ipify.org"
  "imgur.com"
  "steamstat.us"
  "fastly.com"
  "global.bing.com"
  "avatars.githubusercontent.com"
)

FAKETLS_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}

# ------------------------------------------------------------
# 安装 MTG
# ------------------------------------------------------------
MTG_VER="2.1.7"
ARCH=$(uname -m)

[[ "$ARCH" == "x86_64" ]] && MTG_ARCH="linux-amd64"
[[ "$ARCH" == "aarch64" ]] && MTG_ARCH="linux-arm64"

MTG_TAR="mtg-${MTG_VER}-${MTG_ARCH}.tar.gz"
MTG_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VER}/${MTG_TAR}"

wget -q $MTG_URL -O /tmp/$MTG_TAR || err "下载 MTG 失败"
tar -xzf /tmp/$MTG_TAR -C /tmp

MTG_BIN=$(tar -tf /tmp/$MTG_TAR | head -n1)
mv "/tmp/$MTG_BIN" /usr/local/bin/mtg
chmod +x /usr/local/bin/mtg

# ------------------------------------------------------------
# FakeTLS Secret（ee）
# ------------------------------------------------------------
FAKETLS_SECRET=$(mtg generate-secret tls -c "$FAKETLS_DOMAIN" | tr -d '\n')

# ------------------------------------------------------------
# systemd 服务
# ------------------------------------------------------------
cat >/etc/systemd/system/mtg-faketls.service <<EOF
[Unit]
Description=MTG FakeTLS Proxy
After=network-online.target wg-quick@wgcf.service
Wants=wg-quick@wgcf.service

[Service]
ExecStart=/usr/local/bin/mtg run -b 0.0.0.0:${MTG_PORT} ${FAKETLS_SECRET}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtg-faketls
systemctl restart mtg-faketls

# ------------------------------------------------------------
# mtgctl 管理脚本
# ------------------------------------------------------------
cat >/usr/local/bin/mtgctl <<EOF
#!/bin/bash
case "\$1" in
  start) systemctl start mtg-faketls ;;
  stop) systemctl stop mtg-faketls ;;
  restart) systemctl restart mtg-faketls ;;
  status) systemctl status mtg-faketls ;;
  logs) journalctl -u mtg-faketls -e ;;
  *) echo "用法：mtgctl {start|stop|restart|status|logs}" ;;
esac
EOF

chmod +x /usr/local/bin/mtgctl

# ------------------------------------------------------------
# watchdog 自动检测脚本
# ------------------------------------------------------------
cat >/usr/local/bin/mtg-watchdog <<'EOF'
#!/bin/bash
LOG=/var/log/mtg-watchdog.log
DATE=$(date "+%F %T")

check() {
    CODE=$(curl -I -m 5 -o /dev/null -s -w "%{http_code}" https://core.telegram.org)
    [[ "$CODE" == "200" ]]
}

echo "[$DATE] 检测 Telegram..." >> $LOG

if check; then
    echo "[$DATE] 正常" >> $LOG
    exit 0
fi

echo "[$DATE] Telegram 不可达 → 重启 WARP" >> $LOG
systemctl restart wg-quick@wgcf
sleep 3

if check; then
    echo "[$DATE] WARP 修复成功" >> $LOG
    exit 0
fi

echo "[$DATE] 重启 MTG" >> $LOG
systemctl restart mtg-faketls
EOF

chmod +x /usr/local/bin/mtg-watchdog

# ------------------------------------------------------------
# Cron 每分钟检测一次
# ------------------------------------------------------------
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/mtg-watchdog") | crontab -

# ------------------------------------------------------------
# 输出连接信息
# ------------------------------------------------------------
SERVER_IP=$(curl -4s ifconfig.me)

echo "====================================================="
echo " FakeTLS + WARP + MTG 已安装完成"
echo "====================================================="
echo "服务器 IP：$SERVER_IP"
echo "端口：$MTG_PORT"
echo "伪装域名：$FAKETLS_DOMAIN"
echo "FakeTLS Secret：$FAKETLS_SECRET"
echo
echo "代理链接："
echo "tg://proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${FAKETLS_SECRET}"
echo
echo "管理命令：mtgctl start | stop | restart | status | logs"
echo "====================================================="

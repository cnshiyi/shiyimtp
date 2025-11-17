#!/bin/bash
# ============================================================
# Cloudflare WARP + FakeTLS (ee) + MTG
# 一键安装脚本（带进程守护 + 启动脚本 + 系统服务）
# 作者：ChatGPT（专为用户定制版）
# ============================================================

set -e

GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
err(){ echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }

[[ $EUID -ne 0 ]] && err "请使用 root 用户运行（sudo -i）"

apt update -y >/dev/null 2>&1 || true
apt install -y curl wget sudo xxd tar git make >/dev/null 2>&1 || \
err "无法安装基础依赖，请检查网络或系统源。"

# ------------------------------------------------------------
# 安装 Cloudflare WARP
# ------------------------------------------------------------
ok "安装 Cloudflare WARP..."

wget -N https://gitlab.com/wyx1816/warp-script/raw/main/menu.sh -O warp.sh
chmod +x warp.sh

echo "1" | bash warp.sh >/dev/null 2>&1
echo "2" | bash warp.sh >/dev/null 2>&1

warp_status=$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep warp | cut -d= -f2)
[[ "$warp_status" != "on" ]] && err "WARP 启动失败，请检查 WireGuard 是否正常！"

ok "WARP 已启用（Cloudflare 节点出口）"

# ------------------------------------------------------------
# 选择端口
# ------------------------------------------------------------
read -p "请输入 MTProto 监听端口（默认 443）: " MTG_PORT
MTG_PORT=${MTG_PORT:-443}
ok "监听端口：$MTG_PORT"

# ------------------------------------------------------------
# 随机 FakeTLS 域名
# ------------------------------------------------------------
DOMAINS=(
  "fonts.gstatic.com"
  "api.ipify.org"
  "imgur.com"
  "developer.apple.com"
  "support.apple.com"
  "sentry.io"
  "avatars.githubusercontent.com"
  "assets-cdn.github.com"
  "steamstat.us"
  "fastly.com"
  "global.bing.com"
)

FAKETLS_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}
ok "FakeTLS 伪装域名：$FAKETLS_DOMAIN"

# ------------------------------------------------------------
# 下载 MTG
# ------------------------------------------------------------
MTG_VER="2.1.7"
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && MTG_ARCH="linux-amd64"
[[ "$ARCH" == "aarch64" ]] && MTG_ARCH="linux-arm64"

MTG_TAR="mtg-${MTG_VER}-${MTG_ARCH}.tar.gz"
MTG_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VER}/${MTG_TAR}"

ok "下载 MTG：$MTG_URL"
cd /tmp
wget -q $MTG_URL -O $MTG_TAR || err "下载 MTG 失败"
tar -xzf $MTG_TAR

BIN=$(tar -tf $MTG_TAR | head -n1)
mv "$BIN" /usr/local/bin/mtg
chmod +x /usr/local/bin/mtg

# ------------------------------------------------------------
# FakeTLS Secret
# ------------------------------------------------------------
FAKETLS_SECRET=$(mtg generate-secret tls -c "$FAKETLS_DOMAIN" | tr -d '\n')
[[ "$FAKETLS_SECRET" != ee* ]] && warn "FakeTLS Secret 并非 ee 开头"

ok "FakeTLS Secret：$FAKETLS_SECRET"

# ------------------------------------------------------------
# systemd 服务
# ------------------------------------------------------------
SERVICE=/etc/systemd/system/mtg-faketls.service

cat > $SERVICE <<EOF
[Unit]
Description=MTG FakeTLS Proxy
After=network-online.target wg-quick@wgcf.service
Wants=wg-quick@wgcf.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run -b 0.0.0.0:${MTG_PORT} ${FAKETLS_SECRET}
Restart=always
RestartSec=3
LimitNOFILE=200000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtg-faketls
systemctl restart mtg-faketls

# ------------------------------------------------------------
# 安装管理脚本 mtgctl
# ------------------------------------------------------------
cat >/usr/local/bin/mtgctl <<EOF
#!/bin/bash

case "\$1" in
  start) systemctl start mtg-faketls ;;
  stop) systemctl stop mtg-faketls ;;
  restart) systemctl restart mtg-faketls ;;
  status) systemctl status mtg-faketls ;;
  log|logs) journalctl -u mtg-faketls -e ;;
  *)
    echo "用法：mtgctl {start|stop|restart|status|logs}"
    ;;
esac
EOF

chmod +x /usr/local/bin/mtgctl
ok "管理脚本安装完成：mtgctl"

# ------------------------------------------------------------
# 安装 watchdog 监控脚本
# ------------------------------------------------------------
cat >/usr/local/bin/mtg-watchdog <<'EOF'
#!/bin/bash

LOGFILE="/var/log/mtg-watchdog.log"
CHECK_URL="https://core.telegram.org"
TIMEOUT=5
DATESTR=$(date "+%Y-%m-%d %H:%M:%S")

echo "[$DATESTR] 开始检测 Telegram 状态..." >> $LOGFILE

check_tg() {
    HTTP_CODE=$(curl -I -m $TIMEOUT -o /dev/null -s -w "%{http_code}" "$CHECK_URL")
    [[ "$HTTP_CODE" == "200" ]]
}

if check_tg; then
    echo "[$DATESTR] Telegram 可达" >> $LOGFILE
    exit 0
fi

echo "[$DATESTR] Telegram 不可达 → 重启 WARP" >> $LOGFILE
systemctl restart wg-quick@wgcf >/dev/null 2>&1
sleep 4

if check_tg; then
    echo "[$DATESTR] WARP 修复成功" >> $LOGFILE
    exit 0
fi

echo "[$DATESTR] WARP 修复失败 → 重启 MTG" >> $LOGFILE
systemctl restart mtg-faketls >/dev/null 2>&1
sleep 3

if check_tg; then
    echo "[$DATESTR] MTG 重启后恢复" >> $LOGFILE
    exit 0
fi

echo "[$DATESTR] 多次修复失败，需要检查服务器。" >> $LOGFILE
EOF

chmod +x /usr/local/bin/mtg-watchdog
ok "自动检测 watchdog 安装完成"

# ------------------------------------------------------------
# 配置 cron 定时检测
# ------------------------------------------------------------
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/mtg-watchdog") | crontab -
ok "已设置每分钟自动检测 Telegram 连接状态"

# ------------------------------------------------------------
# 输出结果
# ------------------------------------------------------------
SERVER_IP=$(curl -4s ifconfig.me)

echo -e "\n=============================================================="
echo "          Cloudflare WARP + FakeTLS（ee） + MTG"
echo "                      安装已完成！"
echo "=============================================================="
echo "服务器真实 IP：$SERVER_IP"
echo "出口 IP（WARP）：$(curl -4s ifconfig.me)"
echo "监听端口：$MTG_PORT"
echo "FakeTLS 域名：$FAKETLS_DOMAIN"
echo "FakeTLS Secret：$FAKETLS_SECRET"
echo
echo "👉 Telegram 代理链接："
echo "tg://proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${FAKETLS_SECRET}"
echo
echo "管理命令："
echo "  mtgctl start | stop | restart | status | logs"
echo "日志：/var/log/mtg-watchdog.log"
echo "=============================================================="

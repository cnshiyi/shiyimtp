#!/bin/bash
# ============================================================
# Cloudflare WARP + FakeTLS (ee) + MTG 一键安装脚本
# 完整修复版（2025.11）
# 作者：ChatGPT 为 cnshiyi 特制
# ============================================================

set -e

GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
err(){ echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }

[[ $EUID -ne 0 ]] && err "请使用 root 运行（sudo -i）"

# ------------------------------------------------------------
# 依赖安装
# ------------------------------------------------------------
ok "安装系统依赖..."
apt update -y >/dev/null 2>&1 || true
apt install -y curl wget sudo xxd tar git make >/dev/null 2>&1 \
|| err "依赖安装失败"

# ------------------------------------------------------------
# WARP 安装（修复所有 403/404）
# ------------------------------------------------------------
ok "安装 Cloudflare WARP..."

# 三重下载源：GitLab（主）→ GitHub（次）→ jsDelivr（备）
wget -N https://gitlab.com/fscarmen/warp/-/raw/main/warp.sh -O warp.sh \
|| wget -N https://raw.githubusercontent.com/fscarmen/warp/main/warp.sh -O warp.sh \
|| wget -N https://cdn.jsdelivr.net/gh/fscarmen/warp/warp.sh -O warp.sh \
|| err "下载 WARP 安装脚本失败（GitLab/GitHub/jsDelivr 全部失败）"

chmod +x warp.sh

# 安装 + 启用 WARP
echo "1" | bash warp.sh >/dev/null 2>&1
echo "2" | bash warp.sh >/dev/null 2>&1

# 检查 WARP 状态
warp_status=$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep warp | cut -d= -f2)
[[ "$warp_status" != "on" ]] && err "WARP 启动失败！请检查 WireGuard 是否可用"

ok "WARP 已启动（流量走 Cloudflare 节点出口）"

# ------------------------------------------------------------
# 选择端口
# ------------------------------------------------------------
read -p "请输入 MTProto 监听端口（默认 443）: " MTG_PORT
MTG_PORT=${MTG_PORT:-443}
ok "监听端口：$MTG_PORT"

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
ok "FakeTLS 伪装域名：$FAKETLS_DOMAIN"

# ------------------------------------------------------------
# 安装 MTG（FakeTLS 引擎）
# ------------------------------------------------------------
ok "安装 MTG..."

MTG_VER="2.1.7"
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && MTG_ARCH="linux-amd64"
[[ "$ARCH" == "aarch64" ]] && MTG_ARCH="linux-arm64"

MTG_TAR="mtg-${MTG_VER}-${MTG_ARCH}.tar.gz"
MTG_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VER}/${MTG_TAR}"

wget -q $MTG_URL -O /tmp/$MTG_TAR || err "MTG 下载失败"
tar -xzf /tmp/$MTG_TAR -C /tmp

MTG_BIN=$(tar -tf /tmp/$MTG_TAR | head -n1)
mv "/tmp/$MTG_BIN" /usr/local/bin/mtg
chmod +x /usr/local/bin/mtg

# ------------------------------------------------------------
# 生成 FakeTLS Secret（ee 开头）
# ------------------------------------------------------------
FAKETLS_SECRET=$(mtg generate-secret tls -c "$FAKETLS_DOMAIN" | tr -d '\n')
[[ "$FAKETLS_SECRET" != ee* ]] && warn "生成的 Secret 不是 ee 开头？"

ok "FakeTLS Secret：$FAKETLS_SECRET"

# ------------------------------------------------------------
# systemd 服务（MTG 守护）
# ------------------------------------------------------------
ok "创建 systemd 服务..."

cat >/etc/systemd/system/mtg-faketls.service <<EOF
[Unit]
Description=MTG FakeTLS Proxy
After=network-online.target wg-quick@wgcf.service
Wants=wg-quick@wgcf.service

[Service]
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

ok "MTG 服务已启动"

# ------------------------------------------------------------
# 安装 mtgctl 管理脚本
# ------------------------------------------------------------
cat >/usr/local/bin/mtgctl <<EOF
#!/bin/bash
case "\$1" in
  start) systemctl start mtg-faketls ;;
  stop) systemctl stop mtg-faketls ;;
  restart) systemctl restart mtg-faketls ;;
  status) systemctl status mtg-faketls ;;
  logs|log) journalctl -u mtg-faketls -e ;;
  *)
    echo "用法：mtgctl {start|stop|restart|status|logs}"
    ;;
esac
EOF

chmod +x /usr/local/bin/mtgctl
ok "管理命令已安装：mtgctl"

# ------------------------------------------------------------
# watchdog 自动检测脚本（每分钟检测 Telegram）
# ------------------------------------------------------------
ok "安装自动检测 watchdog..."

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

echo "[$DATE] 修复失败 → 重启 MTG" >> $LOG
systemctl restart mtg-faketls
sleep 3

if check; then
    echo "[$DATE] MTG 修复成功" >> $LOG
    exit 0
fi

echo "[$DATE] 多次修复失败，需要人工检查" >> $LOG
EOF

chmod +x /usr/local/bin/mtg-watchdog

# ------------------------------------------------------------
# Cron 定时任务
# ------------------------------------------------------------
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/mtg-watchdog") | crontab -

# ------------------------------------------------------------
# 输出代理连接信息
# ------------------------------------------------------------
SERVER_IP=$(curl -4s ifconfig.me)

echo
echo "=============================================================="
echo "  WARP + FakeTLS（ee）+ MTG 安装成功！"
echo "=============================================================="
echo "服务器真实 IP：$SERVER_IP"
echo "出口 IP（WARP）：$(curl -4s ifconfig.me)"
echo "监听端口：$MTG_PORT"
echo "伪装域名：$FAKETLS_DOMAIN"
echo "FakeTLS Secret：$FAKETLS_SECRET"
echo
echo "代理链接："
echo "tg://proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${FAKETLS_SECRET}"
echo
echo "管理命令： mtgctl start | stop | restart | status | logs"
echo "日志文件： /var/log/mtg-watchdog.log"
echo "=============================================================="
echo

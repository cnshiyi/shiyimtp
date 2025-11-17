#!/bin/bash
# ============================================================
# Cloudflare WARP (wgcf) + FakeTLS (ee) + MTG 一键安装脚本
# 完整修复版：不使用 warp.sh / menu.sh，不依赖 raw.githubusercontent
# 仅使用 GitHub Releases 下载 wgcf / mtg 二进制
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
apt install -y curl wget sudo xxd tar git make resolvconf >/dev/null 2>&1 || \
  err "依赖安装失败（curl/wget/git 等）"

# WireGuard 依赖（Debian/Ubuntu 系）
apt install -y wireguard wireguard-tools >/dev/null 2>&1 || \
  warn "wireguard 安装失败，请手动检查内核是否自带 WireGuard"

# ------------------------------------------------------------
# CPU 架构识别（仅支持 amd64 / arm64）
# ------------------------------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  CPU_ARCH="amd64" ;;
  aarch64|arm64) CPU_ARCH="arm64" ;;
  *)
    err "当前架构 $ARCH 暂不支持（只支持 x86_64 / aarch64）"
    ;;
esac
ok "CPU 架构：$ARCH → $CPU_ARCH"

# ------------------------------------------------------------
# 安装 wgcf（WARP CLI，来自 GitHub Releases）
# ------------------------------------------------------------
WGCF_VER="2.2.24"   # 稳定版本
WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${CPU_ARCH}"

ok "下载 wgcf：$WGCF_URL"
cd /tmp
wget -q "$WGCF_URL" -O wgcf || err "下载 wgcf 失败"
chmod +x wgcf
mv wgcf /usr/local/bin/wgcf

# ------------------------------------------------------------
# 注册 WARP 账号 & 生成 WireGuard 配置
# ------------------------------------------------------------
ok "注册 WARP 账号（wgcf register）..."
yes | wgcf register >/tmp/wgcf-register.log 2>&1 || {
  cat /tmp/wgcf-register.log
  err "wgcf register 失败"
}

ok "生成 WARP WireGuard 配置（wgcf generate）..."
wgcf generate >/tmp/wgcf-generate.log 2>&1 || {
  cat /tmp/wgcf-generate.log
  err "wgcf generate 失败"
}

# 默认生成 wgcf-profile.conf
if [[ ! -f wgcf-profile.conf ]]; then
  err "未找到 wgcf-profile.conf，wgcf generate 出问题了"
fi

# ------------------------------------------------------------
# 安装到 /etc/wireguard/wgcf.conf
# ------------------------------------------------------------
ok "写入 /etc/wireguard/wgcf.conf ..."
mkdir -p /etc/wireguard
cp wgcf-profile.conf /etc/wireguard/wgcf.conf

# 一般不需要改 AllowedIPs/Endpoint，如需只走出口，可在这里做 sed 修改

chmod 600 /etc/wireguard/wgcf.conf

# ------------------------------------------------------------
# 启动 WARP：wg-quick@wgcf
# ------------------------------------------------------------
ok "启动 WARP（wg-quick@wgcf）..."
systemctl enable wg-quick@wgcf >/dev/null 2>&1 || warn "enable wg-quick@wgcf 失败"
systemctl restart wg-quick@wgcf || err "启动 wg-quick@wgcf 失败，请检查 WireGuard"

sleep 3

# 检查 WARP 状态
TRACE=$(curl -s https://www.cloudflare.com/cdn-cgi/trace || true)
WARP_FLAG=$(echo "$TRACE" | grep '^warp=' | cut -d= -f2)

if [[ "$WARP_FLAG" != "on" ]]; then
  warn "WARP 似乎没有成功启用（warp=$WARP_FLAG），后续可用 watchdog 自动修复"
else
  ok "WARP 已启用（warp=on）"
fi

# ------------------------------------------------------------
# 选择 MTProto 端口
# ------------------------------------------------------------
read -p "请输入 MTProto 监听端口（默认 443）: " MTG_PORT
MTG_PORT=${MTG_PORT:-443}
ok "监听端口：$MTG_PORT"

# ------------------------------------------------------------
# FakeTLS 伪装域名池
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
# 安装 MTG（二进制来自 GitHub Releases）
# ------------------------------------------------------------
ok "安装 MTG..."

MTG_VER="2.1.7"
if [[ "$CPU_ARCH" == "amd64" ]]; then
  MTG_FILE="mtg-linux-amd64"
else
  MTG_FILE="mtg-linux-arm64"
fi

MTG_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VER}/${MTG_FILE}"

wget -q "$MTG_URL" -O /usr/local/bin/mtg || err "下载 MTG 失败：$MTG_URL"
chmod +x /usr/local/bin/mtg

# ------------------------------------------------------------
# 生成 FakeTLS Secret（ee 开头）
# ------------------------------------------------------------
FAKETLS_SECRET=$(mtg generate-secret tls -c "$FAKETLS_DOMAIN" | tr -d '\n')

if [[ "$FAKETLS_SECRET" != ee* ]]; then
  warn "生成的 Secret 不是 ee 开头：$FAKETLS_SECRET"
else
  ok "FakeTLS Secret 生成成功（ee 开头）"
fi

# ------------------------------------------------------------
# 写入 systemd 服务：mtg-faketls
# ------------------------------------------------------------
ok "创建 MTG systemd 服务..."

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

ok "MTG FakeTLS 服务已启动"

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
  logs|log) journalctl -u mtg-faketls -e ;;
  *) echo "用法：mtgctl {start|stop|restart|status|logs}" ;;
esac
EOF

chmod +x /usr/local/bin/mtgctl
ok "管理命令已安装：mtgctl"

# ------------------------------------------------------------
# watchdog：自动检测 Telegram 是否可达
# ------------------------------------------------------------
cat >/usr/local/bin/mtg-watchdog <<'EOF'
#!/bin/bash
LOG=/var/log/mtg-watchdog.log
DATE=$(date "+%F %T")

check() {
    CODE=$(curl -I -m 5 -o /dev/null -s -w "%{http_code}" https://core.telegram.org || echo 000)
    [[ "$CODE" == "200" ]]
}

echo "[$DATE] 检测 Telegram..." >> $LOG

if check; then
    echo "[$DATE] Telegram 正常" >> $LOG
    exit 0
fi

echo "[$DATE] Telegram 不可达 → 重启 WARP(wg-quick@wgcf)" >> $LOG
systemctl restart wg-quick@wgcf
sleep 3

if check; then
    echo "[$DATE] 重启 WARP 后恢复正常" >> $LOG
    exit 0
fi

echo "[$DATE] 仍不可达 → 重启 MTG" >> $LOG
systemctl restart mtg-faketls
sleep 3

if check; then
    echo "[$DATE] 重启 MTG 后恢复正常" >> $LOG
    exit 0
fi

echo "[$DATE] 多次修复失败，需要人工检查" >> $LOG
EOF

chmod +x /usr/local/bin/mtg-watchdog
ok "watchdog 已安装：/usr/local/bin/mtg-watchdog"

# ------------------------------------------------------------
# 加入 cron，每分钟检测一次
# ------------------------------------------------------------
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/mtg-watchdog") | crontab -
ok "已加入 crontab：每分钟检测 Telegram + 自动修复 WARP/MTG"

# ------------------------------------------------------------
# 输出连接信息
# ------------------------------------------------------------
SERVER_IP=$(curl -4s ifconfig.me || echo "YOUR_SERVER_IP")

echo
echo "=============================================================="
echo "  ✅ WARP (wgcf) + FakeTLS（ee）+ MTG 已安装完成"
echo "=============================================================="
echo "服务器真实 IP：$SERVER_IP"
echo "监听端口：$MTG_PORT"
echo "伪装域名：$FAKETLS_DOMAIN"
echo "FakeTLS Secret：$FAKETLS_SECRET"
echo
echo "代理链接："
echo "tg://proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${FAKETLS_SECRET}"
echo
echo "管理命令： mtgctl start | stop | restart | status | logs"
echo "watchdog 日志： /var/log/mtg-watchdog.log"
echo "=============================================================="
echo

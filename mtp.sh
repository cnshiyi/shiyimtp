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

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------
[[ $EUID -ne 0 ]] && err "请使用 root 用户运行（sudo -i）"

# ------------------------------------------------------------
# Base packages
# ------------------------------------------------------------
apt update -y >/dev/null 2>&1 || true
apt install -y curl wget sudo xxd tar git make >/dev/null 2>&1 || \
err "无法安装基础依赖，请检查网络或系统源。"

# ------------------------------------------------------------
# 安装 Cloudflare WARP（WireGuard 隧道）
# ------------------------------------------------------------
ok "安装 Cloudflare WARP..."

wget -N https://gitlab.com/wyx1816/warp-script/raw/main/menu.sh -O warp.sh
chmod +x warp.sh

echo "1" | bash warp.sh >/dev/null 2>&1
echo "2" | bash warp.sh >/dev/null 2>&1

warp_status=$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep warp | cut -d= -f2)
[[ "$warp_status" != "on" ]] && err "WARP 启动失败，请检查 WireGuard 是否正常！"

ok "WARP 隧道已启动 → 所有流量将从 Cloudflare 节点出口"

# ------------------------------------------------------------
# 选择端口
# ------------------------------------------------------------
read -p "请输入 MTProto 监听端口（默认 443）: " MTG_PORT
MTG_PORT=${MTG_PORT:-443}
ok "使用端口：$MTG_PORT"

# ------------------------------------------------------------
# 随机选择 FakeTLS 域名（避开常见域名）
# ------------------------------------------------------------
DOMAINS=(
  "fonts.gstatic.com"
  "api.ipify.org"
  "imgur.com"
  "developer.apple.com"
  "support.apple.com"
  "sentry.io"
  "assets-cdn.github.com"
  "avatars.githubusercontent.com"
  "fastly.com"
  "steamstat.us"
  "global.bing.com"
)

FAKETLS_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}
ok "使用伪装域名（FakeTLS）：$FAKETLS_DOMAIN"

# ------------------------------------------------------------
# 安装 MTG 二进制
# ------------------------------------------------------------
MTG_VER="2.1.7"
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && MTG_ARCH="linux-amd64"
[[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && MTG_ARCH="linux-arm64"
[[ -z "$MTG_ARCH" ]] && err "不支持此 CPU 架构：$ARCH"

MTG_TAR="mtg-${MTG_VER}-${MTG_ARCH}.tar.gz"
MTG_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VER}/${MTG_TAR}"

ok "下载 MTG 二进制：$MTG_URL"
cd /tmp
wget -q $MTG_URL -O $MTG_TAR || err "MTG 下载失败"
tar -xzf $MTG_TAR
MTG_BIN=$(tar -tf $MTG_TAR | head -n1)

mv "$MTG_BIN" /usr/local/bin/mtg
chmod +x /usr/local/bin/mtg

ok "MTG 安装完成"

# ------------------------------------------------------------
# 生成 FakeTLS Secret
# ------------------------------------------------------------
FAKETLS_SECRET=$(mtg generate-secret tls -c "$FAKETLS_DOMAIN" | tr -d '\n')
[[ "$FAKETLS_SECRET" != ee* ]] && warn "FakeTLS Secret 不是 ee 开头，请检查！"
ok "FakeTLS Secret：$FAKETLS_SECRET"

# ------------------------------------------------------------
# 写入 systemd 服务
# ------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/mtg-faketls.service"

cat > $SERVICE_FILE <<EOF
[Unit]
Description=MTG FakeTLS Proxy (Cloudflare WARP 加速)
After=network-online.target wg-quick@wgcf.service
Wants=wg-quick@wgcf.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run -b 0.0.0.0:${MTG_PORT} ${FAKETLS_SECRET}
Restart=always
RestartSec=3
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtg-faketls
systemctl restart mtg-faketls

ok "MTProxy FakeTLS 服务已启动"

# ------------------------------------------------------------
# 创建管理脚本 mtgctl
# ------------------------------------------------------------
cat > /usr/local/bin/mtgctl <<EOF
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
ok "管理脚本已安装： mtgctl"

# ------------------------------------------------------------
# 输出信息
# ------------------------------------------------------------
SERVER_IP=$(curl -4s https://ifconfig.me || hostname -I | awk '{print $1}')

echo -e "\n=============================================================="
echo -e "      FakeTLS + MTG + Cloudflare WARP 安装完成"
echo -e "=============================================================="
echo -e "服务器出口 IP（Cloudflare 节点）：$(curl -4s ifconfig.me)"
echo -e "服务器真实 IP：$SERVER_IP"
echo -e "端口：$MTG_PORT"
echo -e "伪装域名：$FAKETLS_DOMAIN"
echo -e "FakeTLS Secret：$FAKETLS_SECRET"
echo -e "\n👉 代理链接："
echo -e "tg://proxy?server=${SERVER_IP}&port=${MTG_PORT}&secret=${FAKETLS_SECRET}"
echo -e "=============================================================="
echo -e "管理命令： mtgctl start | stop | restart | status | logs"
echo -e "==============================================================\n"

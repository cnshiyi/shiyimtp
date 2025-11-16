#!/bin/bash
# ================================================================
# MTProxy Docker 安装脚本（最终修复版）
# 绝不再出现 invalid proto
# 固定端口：10086
# ================================================================

set -e

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"

log()  { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERR]${RESET} $1"; }

# ----------------------------------------------------------------
# 获取公网 IP
# ----------------------------------------------------------------
IP=$(wget -qO- ipv4.icanhazip.com || echo "0.0.0.0")

# ----------------------------------------------------------------
# 端口固定（不使用 read，避免 empty）
# ----------------------------------------------------------------
PORT=10086
log "端口固定为：$PORT"

# ----------------------------------------------------------------
# 安装 xxd
# ----------------------------------------------------------------
if ! command -v xxd >/dev/null 2>&1; then
    warn "xxd 未安装，正在安装..."
    apt update -y
    apt install -y xxd
fi

# ----------------------------------------------------------------
# 安装 Docker（如未安装）
# ----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    warn "Docker 未安装，自动安装中..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
else
    log "Docker 已安装"
fi

# ----------------------------------------------------------------
# 创建配置目录 & Secret
# ----------------------------------------------------------------
mkdir -p /opt/mtproxy/config
SECRET=$(xxd -ps -l 16 /dev/urandom)

echo -n "$SECRET" > /opt/mtproxy/config/secret

log "生成 Secret：$SECRET"

# ----------------------------------------------------------------
# 运行 Docker 容器
# ----------------------------------------------------------------
docker rm -f mtproxy >/dev/null 2>&1 || true

docker run -d \
    --name mtproxy \
    --restart always \
    -p 10086:443 \
    -v /opt/mtproxy/config:/data \
    -e SECRET=$SECRET \
    alexdoesh/mtproxy:latest

log "MTProxy Docker 容器已启动"

sleep 2

# ----------------------------------------------------------------
# 输出连接链接
# ----------------------------------------------------------------
TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
TM_LINK="https://t.me/proxy?server=${IP}&port=${PORT}&secret=${SECRET}"

echo -e "\n===================== MTProxy 连接信息 ====================="
echo -e "公网 IP: ${GREEN}${IP}${RESET}"
echo -e "端口:   ${GREEN}${PORT}${RESET}"
echo -e "秘钥:   ${GREEN}${SECRET}${RESET}"
echo
echo -e "tg:// 链接：\n${GREEN}${TG_LINK}${RESET}"
echo
echo -e "t.me 链接：\n${GREEN}${TM_LINK}${RESET}"
echo
echo -e "==============================================================="
log "MTProxy 安装并启动成功！"

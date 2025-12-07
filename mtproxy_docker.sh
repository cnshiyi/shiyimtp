#!/bin/bash
# ================================================================
# MTProxy Docker 安装脚本（固定 Secret 版）
# 端口固定：15689
# 使用你指定的 Secret：f0da49e49776700dec55677a5591bd1e
# 永远不会随机，不会变
# ================================================================

set -e

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERR]${RESET} $1"; }

PORT=15689
INSTALL_DIR="/opt/mtproxy/config"
SECRET_FILE="${INSTALL_DIR}/secret"

# ================================
# 🚨 固定 Secret（你已指定）
# ================================
FIXED_SECRET="f0da49e49776700dec55677a5591bd1e"


echo -e "\n========== MTProxy 环境检查 ==========\n"
ok "使用固定端口：$PORT"
ok "使用固定 SECRET：$FIXED_SECRET"

# ---------------------------------------------------------
# 检查 Docker
# ---------------------------------------------------------
DOCKER=false
if command -v docker >/dev/null 2>&1; then
    ok "Docker 已安装"
    DOCKER=true
else
    warn "Docker 未安装，稍后自动安装。"
fi

# ---------------------------------------------------------
# 如果已经安装 → 输出代理链接（始终使用固定 Secret）
# ---------------------------------------------------------
if [ -d "$INSTALL_DIR" ] && [ -f "$SECRET_FILE" ]; then

    # 永远保持固定 secret
    echo -n "$FIXED_SECRET" > "$SECRET_FILE"

    IP=$(wget -qO- ipv4.icanhazip.com || echo "0.0.0.0")

    TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${FIXED_SECRET}"
    TM_LINK="https://t.me/proxy?server=${IP}&port=${PORT}&secret=${FIXED_SECRET}"

    echo -e "\n========== MTProxy 已安装，输出连接 =========="
    echo -e "公网 IP: ${GREEN}${IP}${RESET}"
    echo -e "端口:   ${GREEN}${PORT}${RESET}"
    echo -e "秘钥:   ${GREEN}${FIXED_SECRET}${RESET}\n"
    echo -e "tg:// 链接：\n${GREEN}${TG_LINK}${RESET}\n"
    echo -e "t.me 链接：\n${GREEN}${TM_LINK}${RESET}"
    echo -e "=================================================\n"
    exit 0
fi

echo -e "\n========== 开始安装 MTProxy ==========\n"

# ---------------------------------------------------------
# 安装 xxd
# ---------------------------------------------------------
if ! command -v xxd >/dev/null 2>&1; then
    warn "xxd 未安装 → 正在安装"
    apt update -y
    apt install -y xxd vim-common
    ok "xxd 安装完成"
else
    ok "xxd 已安装"
fi

# ---------------------------------------------------------
# 安装 Docker
# ---------------------------------------------------------
if [ "$DOCKER" = false ]; then
    warn "Docker 未安装 → 正在安装"
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    ok "Docker 安装完成"
fi

# ---------------------------------------------------------
# 写入固定 Secret（不会随机）
# ---------------------------------------------------------
mkdir -p "$INSTALL_DIR"
echo -n "$FIXED_SECRET" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
ok "已写入固定 Secret：$FIXED_SECRET"

# ---------------------------------------------------------
# 获取公网 IP
# ---------------------------------------------------------
IP=$(wget -qO- ipv4.icanhazip.com || echo "0.0.0.0")
ok "公网 IP：$IP"

# ---------------------------------------------------------
# 启动容器
# ---------------------------------------------------------
docker rm -f mtproxy >/dev/null 2>&1 || true

docker run -d \
    --name mtproxy \
    --restart always \
    -p ${PORT}:443 \
    -v /opt/mtproxy/config:/data \
    -e SECRET=${FIXED_SECRET} \
    alexdoesh/mtproxy:latest

sleep 2

# ---------------------------------------------------------
# 启动检查
# ---------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -q "^mtproxy$"; then
    err "MTProxy 启动失败，查看日志：docker logs mtproxy"
    exit 1
fi

ok "MTProxy 启动成功！"

# ---------------------------------------------------------
# 输出连接信息
# ---------------------------------------------------------
TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${FIXED_SECRET}"
TM_LINK="https://t.me/proxy?server=${IP}&port=${PORT}&secret=${FIXED_SECRET}"

echo -e "\n===================== MTProxy 连接信息 ====================="
echo -e "公网 IP: ${GREEN}${IP}${RESET}"
echo -e "端口:   ${GREEN}${PORT}${RESET}"
echo -e "秘钥:   ${GREEN}${FIXED_SECRET}${RESET}\n"
echo -e "tg:// 链接：\n${GREEN}${TG_LINK}${RESET}\n"
echo -e "t.me 链接：\n${GREEN}${TM_LINK}${RESET}"
echo -e "=============================================================\n"

ok "MTProxy 安装完成，已在 Docker 后台运行。"

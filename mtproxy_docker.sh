#!/bin/bash
# ================================================================
# MTProxy Docker 安装脚本（正式增强版）
# 端口固定：15689
# 功能：
#  - 自动跳过重复安装，但会输出已有代理链接
#  - 固定 Secret（保存在 /opt/mtproxy/config/secret）
#  - 自动安装 Docker + xxd
#  - 永不出现 invalid proto
#  - 自动 docker run
#  - 启动成功检测
# ================================================================

set -e

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERR]${RESET} $1"; }

PORT=15689
INSTALL_DIR="/opt/mtproxy/config"
SECRET_FILE="${INSTALL_DIR}/secret"

echo -e "\n========== MTProxy 环境检查 ==========\n"
ok "使用固定端口：$PORT"

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
# 如果已经安装 → 输出代理链接（你要求的）
# ---------------------------------------------------------
if [ -d "$INSTALL_DIR" ] && [ -f "$SECRET_FILE" ]; then
    SECRET=$(cat "$SECRET_FILE")

    IP=$(wget -qO- ipv4.icanhazip.com || echo "0.0.0.0")

    TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
    TM_LINK="https://t.me/proxy?server=${IP}&port=${PORT}&secret=${SECRET}"

    echo -e "\n========== MTProxy 已安装，输出连接 =========="
    echo -e "公网 IP: ${GREEN}${IP}${RESET}"
    echo -e "端口:   ${GREEN}${PORT}${RESET}"
    echo -e "秘钥:   ${GREEN}${SECRET}${RESET}\n"
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
# 生成固定 Secret（只生成一次）
# ---------------------------------------------------------
mkdir -p "$INSTALL_DIR"

SECRET=$(xxd -ps -l 16 /dev/urandom)
echo -n "$SECRET" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
ok "生成 Secret：$SECRET"

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
    -e SECRET=${SECRET} \
    alexdoesh/mtproxy:latest

sleep 2

# ---------------------------------------------------------
# 确认启动成功
# ---------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -q "^mtproxy$"; then
    err "MTProxy 启动失败，查看日志：docker logs mtproxy"
    exit 1
fi

ok "MTProxy 启动成功！"

# ---------------------------------------------------------
# 输出连接
# ---------------------------------------------------------
TG_LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
TM_LINK="https://t.me/proxy?server=${IP}&port=${PORT}&secret=${SECRET}"

echo -e "\n===================== MTProxy 连接信息 ====================="
echo -e "公网 IP: ${GREEN}${IP}${RESET}"
echo -e "端口:   ${GREEN}${PORT}${RESET}"
echo -e "秘钥:   ${GREEN}${SECRET}${RESET}\n"
echo -e "tg:// 链接：\n${GREEN}${TG_LINK}${RESET}\n"
echo -e "t.me 链接：\n${GREEN}${TM_LINK}${RESET}"
echo -e "=============================================================\n"

ok "MTProxy 安装完成，已在 Docker 后台运行。"

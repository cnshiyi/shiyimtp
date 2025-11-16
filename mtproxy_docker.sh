#!/bin/bash
# ================================================================
# MTProxy Docker 一键安装脚本（最终修复 + 自动跳过版本）
# 端口固定为 10086，不会出现 invalid proto
# 适配 alexdoesh/mtproxy 镜像
# ================================================================

set -e

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERR]${RESET} $1"; }

echo -e "\n========== MTProxy 环境检查 ==========\n"

# ---------------------------------------------------------
# 检查 Docker 是否安装
# ---------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    warn "Docker 未安装，稍后会自动安装。"
else
    ok "Docker 已安装"
fi

# ---------------------------------------------------------
# 检查 MTProxy 是否已运行（完全跳过安装）
# ---------------------------------------------------------
if docker ps --format '{{.Names}}' | grep -q "^mtproxy$"; then
    ok "MTProxy 正在运行"
    warn "检测到 MTProxy 已安装并正在运行 —— 自动跳过安装流程。"
    exit 0
fi

# ---------------------------------------------------------
# 检查 MTProxy 容器是否存在（已安装但未运行）
# ---------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -q "^mtproxy$"; then
    ok "MTProxy 容器已存在"
    warn "检测到 MTProxy 已安装（容器存在） —— 自动跳过安装流程。"
    exit 0
fi

# ---------------------------------------------------------
# 检查配置目录（避免重复安装）
# ---------------------------------------------------------
if [ -d "/opt/mtproxy/config" ]; then
    ok "/opt/mtproxy/config 目录已存在"
    warn "检测到上次安装残留 —— 自动跳过安装流程。"
    exit 0
fi

echo -e "\n========== 开始安装 MTProxy ==========\n"

# ---------------------------------------------------------
# 固定端口（不使用 read，避免空值导致 invalid proto）
# ---------------------------------------------------------
PORT=15689
ok "端口固定为：${PORT}"

# ---------------------------------------------------------
# 安装 xxd
# ---------------------------------------------------------
if ! command -v xxd >/dev/null 2>&1; then
    warn "xxd 未安装，正在安装..."
    apt update -y
    apt install -y xxd
else
    ok "xxd 已安装"
fi

# ---------------------------------------------------------
# 安装 Docker（如果尚未安装）
# ---------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    warn "Docker 未安装，正在安装..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    ok "Docker 安装完成"
fi

# ---------------------------------------------------------
# 生成 Secret
# ---------------------------------------------------------
mkdir -p /opt/mtproxy/config

SECRET=$(xxd -ps -l 16 /dev/urandom)
echo -n "$SECRET" > /opt/mtproxy/config/secret

ok "生成 Secret：$SECRET"

# ---------------------------------------------------------
# 获取公网 IP
# ---------------------------------------------------------
IP=$(wget -qO- ipv4.icanhazip.com || echo "0.0.0.0")
ok "公网 IP：$IP"

# ---------------------------------------------------------
# 启动 MTProxy 容器
# ---------------------------------------------------------
docker rm -f mtproxy >/dev/null 2>&1 || true

docker run -d \
    --name mtproxy \
    --restart always \
    -p 10086:443 \
    -v /opt/mtproxy/config:/data \
    -e SECRET=${SECRET} \
    alexdoesh/mtproxy:latest

ok "MTProxy Docker 容器已启动"

sleep 2

# ---------------------------------------------------------
# 输出链接
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

ok "MTProxy 安装并启动成功！"

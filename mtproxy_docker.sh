#!/bin/bash
# ================================================================
# MTProxy Docker 安装脚本（正式版）
# 端口固定：15689
# 功能：
#  - 自动跳过重复安装
#  - 完整依赖检测（Docker / xxd）
#  - 永不出现 invalid proto
#  - 自动生成 Secret
#  - 自动 docker run
#  - 启动成功检测
#  - 完整代理链接输出
# ================================================================

set -e

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERR]${RESET} $1"; }

echo -e "\n========== MTProxy 环境检查 ==========\n"


# ---------------------------------------------------------
# 固定端口（如需修改，仅需改这里）
# ---------------------------------------------------------
PORT=15689
ok "使用固定端口：$PORT"


# ---------------------------------------------------------
# 检查 Docker 是否安装
# ---------------------------------------------------------
DOCKER_INSTALLED=true
if ! command -v docker >/dev/null 2>&1; then
    DOCKER_INSTALLED=false
    warn "Docker 未安装，稍后将自动安装。"
else
    ok "Docker 已安装"
fi


# ---------------------------------------------------------
# 如果 Docker 已安装，才能检查容器是否存在
# ---------------------------------------------------------
if [ "$DOCKER_INSTALLED" = true ]; then

    # MTProxy 正在运行？
    if docker ps --format '{{.Names}}' | grep -q "^mtproxy$"; then
        ok "MTProxy 正在运行"
        warn "检测到 MTProxy 已安装 —— 自动跳过安装。"
        exit 0
    fi

    # MTProxy 容器存在但未运行？
    if docker ps -a --format '{{.Names}}' | grep -q "^mtproxy$"; then
        ok "MTProxy 容器已存在（未运行）"
        warn "检测到 MTProxy 已安装 —— 自动跳过安装。"
        exit 0
    fi
fi


# ---------------------------------------------------------
# 检查配置目录是否存在
# ---------------------------------------------------------
if [ -d "/opt/mtproxy/config" ]; then
    ok "检测到配置目录存在（旧安装残留）"
    warn "自动跳过安装。"
    exit 0
fi


echo -e "\n========== 开始安装 MTProxy ==========\n"


# ---------------------------------------------------------
# 安装 xxd
# ---------------------------------------------------------
if ! command -v xxd >/dev/null 2>&1; then
    warn "xxd 未安装，正在安装..."
    apt update -y
    apt install -y xxd vim-common
    ok "xxd 安装完成"
else
    ok "xxd 已安装"
fi


# ---------------------------------------------------------
# 安装 Docker
# ---------------------------------------------------------
if [ "$DOCKER_INSTALLED" = false ]; then
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
chmod 600 /opt/mtproxy/config/secret

ok "生成 Secret：$SECRET"


# ---------------------------------------------------------
# 获取公网 IP
# ---------------------------------------------------------
IP=$(wget -qO- ipv4.icanhazip.com || echo "0.0.0.0")
ok "公网 IP：$IP"


# ---------------------------------------------------------
# 启动 MTProxy Docker 容器
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
# 检查容器是否成功启动
# ---------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -q "^mtproxy$"; then
    err "MTProxy 启动失败！请运行以下命令查看日志："
    echo "docker logs mtproxy"
    exit 1
fi

ok "MTProxy 已成功启动！"


# ---------------------------------------------------------
# 输出代理链接
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

ok "MTProxy 安装成功！"
ok "MTProxy 已在 Docker 后台稳定运行。"

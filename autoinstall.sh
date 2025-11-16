#!/bin/bash

# ================================
# 彩色输出
# ================================
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

ok() { echo -e "${GREEN}[OK] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; }

# ================================
# 自动检测依赖
# ================================
echo -e "${YELLOW}>> 检查依赖...${RESET}"

apt update -y
apt install -y git wget xxd python3 python3-pip htop

# ================================
# 变量
# ================================
INSTALL_ROOT="/opt/mtprotoproxy"
REPO="https://github.com/alexbers/mtprotoproxy.git"
IP=$(wget -qO- ipv4.icanhazip.com)

# ================================
# 获取自定义端口
# ================================
read -p "请输入 MTProxy 端口（默认 10086）:" PORT
PORT=${PORT:-10086}
ok "使用端口: $PORT"

# ================================
# 生成 32 位随机十六进制密钥
# ================================
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
ok "生成 SECRET: $SECRET"

# ================================
# 安装
# ================================
echo -e "${GREEN}>> 开始安装 MTProxy ...${RESET}"

rm -rf $INSTALL_ROOT
mkdir -p $INSTALL_ROOT
cd /opt
git clone $REPO

cp -r mtprotoproxy/* $INSTALL_ROOT

# 写入 config.py
cat > $INSTALL_ROOT/config.py <<EOF
PORT = $PORT
USERS = {"user1": "$SECRET"}
EOF

# ================================
# Systemd 服务
# ================================
cat > /etc/systemd/system/MTProxy.service <<EOF
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
ExecStart=/usr/bin/python3 $INSTALL_ROOT/mtprotoproxy.py $INSTALL_ROOT/config.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart MTProxy
systemctl enable MTProxy

ok "MTProxy 安装完成！"

# ================================
# 创建管理命令：mtp
# ================================
ok "创建管理脚本 /usr/local/bin/mtp"

cat > /usr/local/bin/mtp <<'EOF'
#!/bin/bash

INSTALL_ROOT="/opt/mtprotoproxy"
CONF="$INSTALL_ROOT/config.py"
IP=$(wget -qO- ipv4.icanhazip.com)
SERVICE="MTProxy.service"

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

menu() {
    echo -e "${GREEN}
================ MTProxy 管理菜单 ================
1) 查看状态
2) 重启服务
3) 修改端口
4) 生成新的 SECRET
5) 添加额外 SECRET
6) 输出代理连接
7) 卸载 MTProxy
0) 退出
=================================================${RESET}"
}

show_status() {
    echo -e "${GREEN}>>> 服务状态:${RESET}"
    systemctl status MTProxy --no-pager

    echo -e "\n${GREEN}>>> 当前配置:${RESET}"
    cat $CONF
}

restart_service() {
    systemctl restart MTProxy
    echo -e "${GREEN}已重启 MTProxy${RESET}"
}

change_port() {
    read -p "请输入新端口: " NEWPORT
    sed -i "s/^PORT.*/PORT = $NEWPORT/" $CONF
    restart_service
    echo -e "${GREEN}端口已修改为 $NEWPORT${RESET}"
}

new_secret() {
    NEW=$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/user1\": \".*\"/user1\": \"$NEW\"/" $CONF
    restart_service
    echo -e "${GREEN}新 SECRET: $NEW${RESET}"
}

add_secret() {
    read -p "输入新用户名: " NAME
    NEW=$(head -c 16 /dev/urandom | xxd -ps)
    sed -i "s/}/,\"$NAME\": \"$NEW\"}/" $CONF
    restart_service
    echo -e "${GREEN}已添加用户 $NAME，SECRET=$NEW${RESET}"
}

show_links() {
    PORT=$(grep PORT $CONF | grep -oE '[0-9]+')
    SECRETS=$(grep -oP '"\w+": "\K[a-f0-9]+' $CONF)

    echo -e "${YELLOW}>>> 连接信息:${RESET}"
    for S in $SECRETS; do
        echo -e "${GREEN}tg://proxy?server=$IP&port=$PORT&secret=dd$S${RESET}"
        echo -e "https://t.me/proxy?server=$IP&port=$PORT&secret=dd$S"
        echo -e "server=$IP  port=$PORT  secret=dd$S\n"
    done
}

uninstall() {
    systemctl stop MTProxy
    systemctl disable MTProxy
    rm -f /etc/systemd/system/MTProxy.service
    rm -rf /opt/mtprotoproxy
    echo -e "${RED}MTProxy 已卸载${RESET}"
}

while true; do
    menu
    read -p "选择功能: " CH
    case $CH in
        1) show_status ;;
        2) restart_service ;;
        3) change_port ;;
        4) new_secret ;;
        5) add_secret ;;
        6) show_links ;;
        7) uninstall ;;
        0) exit ;;
        *) echo "无效输入" ;;
    esac
done
EOF

chmod +x /usr/local/bin/mtp

ok "安装完成！使用命令：mtp"
echo ""
echo -e "${GREEN}立即查看连接：${RESET}"
echo -e "  ${GREEN}mtp 6${RESET}"

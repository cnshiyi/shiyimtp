#!/bin/bash
###
# MTProxy 本地目录安装增强版
# @Author: Enhanced by ChatGPT
# @Origin: Vincent Young
# @Upgrade: Install to current directory instead of /usr/bin,/etc
###

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] Please run as ROOT!" && exit 1

# ================================
# 安装到当前目录
# ================================
BASE_DIR="$(pwd)"
MTG_BIN="${BASE_DIR}/mtg"
MTG_CONF="${BASE_DIR}/mtg.toml"
MTG_SERVICE="/etc/systemd/system/mtg.service"

# ================================
# 获取当前配置并显示连接
# ================================
get_current_config() {
    if [[ -f "$MTG_CONF" ]]; then
        port=$(grep '^bind-to' "$MTG_CONF" | sed -E 's/.*:(.*)".*/\1/')
        secret=$(grep '^secret' "$MTG_CONF" | sed -E 's/.*"([^"]+)".*/\1/')
        public_ip=$(curl -s ipv4.ip.sb)

        tg1="tg://proxy?server=${public_ip}&port=${port}&secret=${secret}"
        tg2="https://t.me/proxy?server=${public_ip}&port=${port}&secret=${secret}"

        echo -e "\n${green}====== 当前 MTProxy 连接 ======${plain}"
        echo -e "${tg1}"
        echo -e "${tg2}"
        echo -e "${green}===============================${plain}\n"
    else
        echo -e "${yellow}未找到配置文件，无法显示连接。${plain}"
    fi
}

# ================================
# 下载并解压 mtg
# ================================
download_file() {
    echo "Checking System..."

    bit=`uname -m`
    if [[ ${bit} = "x86_64" ]]; then
        bit="amd64"
    elif [[ ${bit} = "aarch64" ]]; then
        bit="arm64"
    else
        bit="386"
    fi

    last_version=$(curl -Ls "https://api.github.com/repos/9seconds/mtg/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ ! -n "$last_version" ]] && echo -e "${red}Failed to detect version.${plain}" && exit 1

    echo -e "Latest mtg: ${last_version}, installing..."
    version=$(echo ${last_version} | sed 's/v//g')

    wget -N --no-check-certificate -O mtg-${version}-linux-${bit}.tar.gz \
        https://github.com/9seconds/mtg/releases/download/${last_version}/mtg-${version}-linux-${bit}.tar.gz

    tar -xzf mtg-${version}-linux-${bit}.tar.gz
    mv mtg-${version}-linux-${bit}/mtg "${MTG_BIN}"
    rm -rf mtg-${version}-linux-${bit}*
    chmod +x "${MTG_BIN}"
}

# ================================
# 写入当前目录的 mtg.toml
# ================================
configure_mtg() {
    wget -N --no-check-certificate -O "$MTG_CONF" \
        https://raw.githubusercontent.com/missuo/MTProxy/main/mtg.toml

    read -p "请输入伪装域名 (默认 itunes.apple.com): " domain
    [ -z "${domain}" ] && domain="itunes.apple.com"

    read -p "请输入监听端口 (默认 443): " port
    [ -z "${port}" ] && port="443"

    secret=$("${MTG_BIN}" generate-secret --hex "$domain")

    sed -i "s/secret.*/secret = \"${secret}\"/g" "$MTG_CONF"
    sed -i "s/bind-to.*/bind-to = \"0.0.0.0:${port}\"/g" "$MTG_CONF"
}

# ================================
# 生成 systemd 服务（指向当前目录）
# ================================
configure_systemctl() {
cat > "$MTG_SERVICE" <<EOF
[Unit]
Description=MTProxy Local Directory Service
After=network.target

[Service]
ExecStart=${MTG_BIN} run ${MTG_CONF}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtg
    systemctl restart mtg
}

# ================================
# 安装流程
# ================================
install_mtg() {
    if [[ -f "$MTG_BIN" && -f "$MTG_CONF" ]]; then
        echo -e "${yellow}检测到 MTProxy 已安装，不重复。${plain}"
        get_current_config
        return
    fi
    download_file
    configure_mtg
    configure_systemctl
    echo -e "${green}MTProxy 安装成功！${plain}"
    get_current_config
}

# ================================
# 修改端口
# ================================
change_port() {
    read -p "请输入新的端口 (默认 443): " port
    [ -z "${port}" ] && port="443"

    sed -i "s/bind-to.*/bind-to = \"0.0.0.0:${port}\"/g" "$MTG_CONF"
    systemctl restart mtg
    echo -e "${green}端口修改成功！${plain}"
    get_current_config
}

# ================================
# 修改 Secret
# ================================
change_secret() {
    read -p "请输入新的 Secret (留空自动生成): " secret
    [ -z "${secret}" ] && secret=$("${MTG_BIN}" generate-secret --hex itunes.apple.com)

    sed -i "s/secret.*/secret = \"${secret}\"/g" "$MTG_CONF"
    systemctl restart mtg
    echo -e "${green}Secret 修改成功！${plain}"
    get_current_config
}

# ================================
# 更新
# ================================
update_mtg() {
    download_file
    systemctl restart mtg
    echo -e "${green}更新完成！${plain}"
    get_current_config
}

# ================================
# 菜单
# ================================
start_menu() {
    clear
    echo -e "  MTProxy v2 一键管理脚本（本地安装版）
 ${green}1.${plain} 安装 MTProxy
 ${green}2.${plain} 卸载 MTProxy
————————————
 ${green}3.${plain} 启动 MTProxy
 ${green}4.${plain} 停止 MTProxy
 ${green}5.${plain} 重启 MTProxy（显示连接）
 ${green}6.${plain} 修改监听端口
 ${green}7.${plain} 修改 Secret
 ${green}8.${plain} 更新 MTProxy
————————————
 ${green}9.${plain} 显示连接
————————————
 ${green}0.${plain} 退出
————————————"

    read -e -p "请输入数字 [0-9]：" num
    case "$num" in
        1) install_mtg ;;
        2)
            systemctl stop mtg
            systemctl disable mtg
            rm -f "$MTG_BIN" "$MTG_CONF" "$MTG_SERVICE"
            echo "卸载成功！"
        ;;
        3) systemctl start mtg && echo "启动成功！" && get_current_config ;;
        4) systemctl stop mtg && echo "停止成功！" ;;
        5) systemctl restart mtg && echo "重启成功！" && get_current_config ;;
        6) change_port ;;
        7) change_secret ;;
        8) update_mtg ;;
        9) get_current_config ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
}

start_menu

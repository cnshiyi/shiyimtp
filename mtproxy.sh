#!/bin/bash
###
# MTG 多实例管理终极版
# @Author: ChatGPT Ultra Edition
# @Version: 3.0
# 支持无限实例、独立配置、命令模式 + 菜单模式、多实例 systemd、自动生成 Secret
###

set -e

BASE_DIR=$(dirname $(readlink -f $0))
INSTANCE_DIR="${BASE_DIR}/instances"
BIN="${BASE_DIR}/mtg"

green="\033[32m"; red="\033[31m"; yellow="\033[33m"; plain="\033[0m"


# ---------------------------------------------
# 公共函数
# ---------------------------------------------
ensure_dirs() {
    [[ -d "$INSTANCE_DIR" ]] || mkdir -p "$INSTANCE_DIR"
}

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "[${red}错误${plain}] 请使用 root 运行脚本" && exit 1
}

public_ip() {
    curl -s ipv4.ip.sb || curl -s ifconfig.me || echo "0.0.0.0"
}

get_latest_mtg() {
    echo -e "${yellow}获取 MTG 最新版本...${plain}"
    arch=$(uname -m)
    [[ $arch == "x86_64" ]] && arch="amd64"
    [[ $arch == "aarch64" ]] && arch="arm64"

    version=$(curl -Ls "https://api.github.com/repos/9seconds/mtg/releases/latest" \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

    filename="mtg-${version#v}-linux-${arch}.tar.gz"

    wget -q -O "$filename" \
        "https://github.com/9seconds/mtg/releases/download/${version}/${filename}"

    tar -xzf "$filename"
    mv mtg-*/* "$BIN"
    chmod +x "$BIN"
    rm -rf mtg-* "$filename"

    echo -e "${green}MTG 程序安装完成${plain}"
}

ensure_mtg() {
    [[ -f "$BIN" ]] || get_latest_mtg
}


# ---------------------------------------------
# 实例相关
# ---------------------------------------------
instance_path() {
    echo "${INSTANCE_DIR}/$1"
}

instance_conf() {
    echo "$(instance_path $1)/mtg.toml"
}

instance_secret_file() {
    echo "$(instance_path $1)/secret.txt"
}

instance_service() {
    echo "mtg_$1.service"
}


create_instance() {
    port=$1
    domain=$2

    ensure_dirs
    ensure_mtg

    INST_DIR=$(instance_path $port)
    mkdir -p "$INST_DIR"

    SECRET=$($BIN generate-secret --hex "$domain")
    echo "$SECRET" > "$(instance_secret_file $port)"

cat > "$(instance_conf $port)" <<EOF
secret = "$SECRET"
bind-to = "0.0.0.0:${port}"
EOF

cat > "/etc/systemd/system/$(instance_service $port)" <<EOF
[Unit]
Description=MTG Instance on port $port
After=network.target

[Service]
ExecStart=$BIN run $(instance_conf $port)
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$(instance_service $port)"
    systemctl restart "$(instance_service $port)"

    echo -e "${green}实例 ${port} 安装完成！${plain}"
    show_link $port
}


show_link() {
    port=$1
    conf=$(instance_conf $port)

    secret=$(grep '^secret' "$conf" | sed -E 's/.*"([^"]+)".*/\1/')
    ip=$(public_ip)

    tg1="tg://proxy?server=${ip}&port=${port}&secret=${secret}"
    tg2="https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}"

    echo -e "${green}====== MTG 实例 $port 连接信息 ======${plain}"
    echo "$tg1"
    echo "$tg2"
    echo -e "${green}====================================${plain}"
}


start_instance() {
    port=$1
    systemctl start "$(instance_service $port)"
    echo -e "${green}实例 $port 已启动${plain}"
    show_link $port
}

stop_instance() {
    port=$1
    systemctl stop "$(instance_service $port)"
    echo -e "${yellow}实例 $port 已停止${plain}"
}

restart_instance() {
    port=$1
    systemctl restart "$(instance_service $port)"
    echo -e "${green}实例 $port 已重启${plain}"
    show_link $port
}

uninstall_instance() {
    port=$1
    stop_instance $port
    systemctl disable "$(instance_service $port)"
    rm -f "/etc/systemd/system/$(instance_service $port)"
    rm -rf "$(instance_path $port)"
    systemctl daemon-reload
    echo -e "${red}实例 $port 已卸载${plain}"
}

list_instances() {
    echo -e "${green}===== 已安装实例 =====${plain}"
    ls -1 "$INSTANCE_DIR"
}


# ---------------------------------------------
# 菜单
# ---------------------------------------------
menu() {
clear
echo -e "
${green}MTG 多实例终极管理脚本${plain}

1. 安装实例
2. 卸载实例
3. 启动实例
4. 停止实例
5. 重启实例
6. 查看实例链接
7. 列出所有实例
0. 退出
--------------------------------
"

read -p "请输入选项：" n
case $n in
    1)
        read -p "请输入端口：" port
        read -p "请输入伪装域名（默认 itunes.apple.com）：" domain
        [[ -z "$domain" ]] && domain="itunes.apple.com"
        create_instance $port $domain
    ;;
    2)
        read -p "请输入要卸载的端口：" port
        uninstall_instance $port
    ;;
    3)
        read -p "请输入要启动的端口：" port
        start_instance $port
    ;;
    4)
        read -p "请输入要停止的端口：" port
        stop_instance $port
    ;;
    5)
        read -p "请输入要重启的端口：" port
        restart_instance $port
    ;;
    6)
        read -p "请输入要查看的端口：" port
        show_link $port
    ;;
    7)
        list_instances
    ;;
    0)
        exit 0
    ;;
    *)
        echo "无效输入"
    ;;
esac
}

# ---------------------------------------------
# 命令方式入口
# ---------------------------------------------
if [[ $# -eq 0 ]]; then
    menu
    exit 0
fi

cmd=$1
shift

case "$cmd" in
    install)   create_instance $@ ;;
    uninstall) uninstall_instance $@ ;;
    start)     start_instance $@ ;;
    stop)      stop_instance $@ ;;
    restart)   restart_instance $@ ;;
    show|status) show_link $@ ;;
    list)      list_instances ;;
    *)
        echo "未知命令：$cmd"
        echo "示例："
        echo " bash mtg.sh install 443 itunes.apple.com"
        echo " bash mtg.sh start 443"
        echo " bash mtg.sh list"
    ;;
esac

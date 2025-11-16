#!/bin/bash

SERVICE="MTProxy.service"
PORT=$(grep PORT /opt/mtprotoproxy/config.py | grep -oE '[0-9]+')
LOG="/var/log/mtproxy_watchdog.log"

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# 检查 systemctl 状态
if ! systemctl is-active --quiet $SERVICE; then
    echo "$(timestamp) systemd 服务不在运行，尝试重启…" >> $LOG
    systemctl restart $SERVICE
fi

# 检查进程 PID 是否存在
if ! pgrep -f "mtprotoproxy.py" > /dev/null; then
    echo "$(timestamp) mtprotoproxy.py 进程丢失，尝试重启…" >> $LOG
    systemctl restart $SERVICE
fi

# 检查端口监听
if ! ss -tuln | grep -q ":$PORT "; then
    echo "$(timestamp) 端口 $PORT 未监听，尝试重启…" >> $LOG
    systemctl restart $SERVICE
fi

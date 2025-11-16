cat >/usr/local/bin/mtp <<'EOF'
#!/bin/bash

SERVICE_NAME="mtproxy"
CONF_PATH="/home/mtproxy1/mtproxy_autoinstaller/mtproxy.conf"

case "$1" in
  status|"")
    echo "================ MTProxy Status ================"
    systemctl status $SERVICE_NAME --no-pager 2>/dev/null || echo "⚠️ service '$SERVICE_NAME' not found"

    echo -e "\n================ Connection Info ================"
    if [ -f "$CONF_PATH" ]; then
        cat "$CONF_PATH"
    else
        echo "⚠️ mtproxy.conf not found at $CONF_PATH"
    fi
    echo -e "\n================================================="
    ;;

  restart)
    echo "🔄 Restarting MTProxy..."
    systemctl restart $SERVICE_NAME
    echo "Done."
    ;;

  stop)
    echo "🛑 Stopping MTProxy..."
    systemctl stop $SERVICE_NAME
    echo "Done."
    ;;

  start)
    echo "▶ Starting MTProxy..."
    systemctl start $SERVICE_NAME
    echo "Done."
    ;;

  *)
    echo "Usage: mtp {status|start|stop|restart}"
    ;;
esac
EOF

chmod +x /usr/local/bin/mtp

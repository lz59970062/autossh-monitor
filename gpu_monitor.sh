#!/bin/bash

# GPU服务器端监控脚本
# 监控autossh连接状态，如果断开则自动重启

LOG_FILE="/var/log/autossh_monitor.log"

# 读取安装程序写入的配置文件（不使用环境变量）
if [ -f "/etc/autossh-remote-host" ]; then
    REMOTE_HOST="$(cat /etc/autossh-remote-host)"
else
    REMOTE_HOST="serhk"
fi
LOCAL_PORT="8081"
if [ -f "/etc/autossh-remote-port" ]; then
    REMOTE_PORT="$(cat /etc/autossh-remote-port)"
else
    REMOTE_PORT="8081"
fi
SERVICE_NAME="autossh-comfyui@${REMOTE_PORT}"
MONITOR_PORT="20000"

# 从 envfile 读取 RUN_USER（如果存在），以便使用该用户的 ssh config
if [ -f "/etc/autossh-comfyui.env" ]; then
    # shellcheck disable=SC1091
    . /etc/autossh-comfyui.env
fi
SSH_CONFIG_PATH="/home/${RUN_USER:-root}/.ssh/config"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_autossh_service() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        return 0
    else
        return 1
    fi
}

check_port_forward() {
    if netstat -tlnp 2>/dev/null | grep -q ":$REMOTE_PORT.*LISTEN"; then
        return 0
    else
        return 1
    fi
}

check_remote_connection() {
    if timeout 10 ssh -F "$SSH_CONFIG_PATH" -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_HOST" "echo 'connection_test'" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

restart_autossh() {
    log "重启 $SERVICE_NAME 服务..."
    systemctl restart "$SERVICE_NAME"
    sleep 5
    if check_autossh_service; then
        log "服务重启成功"
        return 0
    else
        log "服务重启失败"
        return 1
    fi
}

main() {
    log "开始监控 autossh 连接..."
    while true; do
        if ! check_autossh_service; then
            log "警告: $SERVICE_NAME 服务未运行，尝试重启..."
            restart_autossh
        fi
        if ! check_port_forward; then
            log "警告: 端口转发可能有问题，检查服务状态..."
            if ! check_autossh_service; then
                log "服务确实有问题，重启服务..."
                restart_autossh
            fi
        fi
        if ! check_remote_connection; then
            log "警告: 无法连接到远程服务器 $REMOTE_HOST"
            log "等待网络恢复..."
        fi
        if check_autossh_service && check_port_forward; then
            log "状态正常: autossh 服务运行中，端口转发正常"
        fi
        sleep 30
    done
}

main 
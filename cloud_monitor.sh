#!/bin/bash

# 云服务器端监控脚本（每端口实例）
# 监控端口转发状态，检测端口冲突并自动处理

LOG_FILE="/var/log/port_forward_monitor.log"
FORWARD_PORT="${FORWARD_PORT:-8081}"
BACKUP_PORT="$((FORWARD_PORT+1))"
HEALTH_CHECK_URL="http://localhost:${FORWARD_PORT}/comfyui/"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_port_occupied() {
    if netstat -tlnp 2>/dev/null | grep -q ":$FORWARD_PORT.*LISTEN"; then
        return 0
    else
        return 1
    fi
}

check_ssh_occupation() {
    if netstat -tlnp 2>/dev/null | grep -q ":$FORWARD_PORT.*sshd"; then
        return 0
    else
        return 1
    fi
}

check_port_forward_working() {
    if timeout 10 curl -s "$HEALTH_CHECK_URL" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

kill_port_process() {
    local port=$1
    log "尝试杀死占用端口 $port 的进程..."
    local pids=$(netstat -tlnp 2>/dev/null | grep ":$port.*LISTEN" | awk '{print $7}' | cut -d'/' -f1 | grep -v PID)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            if [ "$pid" != "$$" ]; then
                log "杀死进程 PID: $pid"
                kill -9 "$pid" 2>/dev/null
            fi
        done
        sleep 2
        return 0
    else
        log "没有找到占用端口 $port 的进程"
        return 1
    fi
}

notify_gpu_server() {
    log "端口转发异常，GPU服务器应该会自动重连"
    return 1
}

switch_to_backup_port() {
    log "端口 $FORWARD_PORT 被占用，建议GPU服务器使用备用端口 $BACKUP_PORT"
    return 1
}

restore_main_port() {
    log "主端口 $FORWARD_PORT 可用，GPU服务器可以恢复使用"
    return 0
}

main() {
    log "开始监控端口转发状态... (FORWARD_PORT=${FORWARD_PORT}, BACKUP_PORT=${BACKUP_PORT})"
    while true; do
        if check_port_forward_working; then
            log "端口转发工作正常"
        else
            log "端口转发可能有问题，开始诊断..."
            if check_port_occupied; then
                log "端口 $FORWARD_PORT 被占用"
                if check_ssh_occupation; then
                    log "端口被SSH占用，尝试杀死SSH进程..."
                    kill_port_process "$FORWARD_PORT"
                    sleep 5
                    if ! check_port_occupied; then
                        log "成功释放端口，通知GPU服务器重启服务"
                        notify_gpu_server
                    else
                        log "无法释放端口，切换到备用端口"
                        switch_to_backup_port
                    fi
                else
                    log "端口被其他进程占用，尝试杀死进程..."
                    kill_port_process "$FORWARD_PORT"
                    notify_gpu_server
                fi
            else
                log "端口未被占用，但转发不工作，通知GPU服务器重启"
                notify_gpu_server
            fi
        fi

        if check_port_forward_working; then
            if curl -s "http://localhost:$BACKUP_PORT/comfyui/" >/dev/null 2>&1; then
                log "检测到使用备用端口，尝试恢复主端口..."
                restore_main_port
            fi
        fi
        sleep 60
    done
}

main 
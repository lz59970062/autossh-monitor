#!/bin/bash

# 监控系统安装脚本（集中于 deploy/monitoring/ 下）

echo "=== AutoSSH 监控系统安装脚本 ==="

# 计算脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
    echo "请使用root权限运行此脚本"
    exit 1
fi

# 检测当前服务器类型
if hostname | grep -q "C202507250943037"; then
    SERVER_TYPE="cloud"
    echo "检测到云服务器"
elif hostname | grep -q "ubu-System-Product-Name"; then
    SERVER_TYPE="gpu"
    echo "检测到GPU服务器"
else
    echo "无法识别服务器类型，请手动选择："
    echo "1. 云服务器"
    echo "2. GPU服务器"
    read -p "请选择 (1/2): " choice
    case $choice in
        1) SERVER_TYPE="cloud" ;;
        2) SERVER_TYPE="gpu" ;;
        *) echo "无效选择"; exit 1 ;;
    esac
fi

# 安装依赖
echo "安装依赖..."
apt update
apt install -y curl net-tools autossh

# 创建脚本目录
mkdir -p /usr/local/bin

if [ "$SERVER_TYPE" = "gpu" ]; then
    echo "=== 在GPU服务器上安装监控 ==="
    
    # 复制GPU监控脚本
    cp "$SCRIPT_DIR/gpu_monitor.sh" /usr/local/bin/
    chmod +x /usr/local/bin/gpu_monitor.sh
    
    # 安装systemd服务（监控 + autossh 模板）
    cp "$SCRIPT_DIR/autossh-monitor.service" /etc/systemd/system/
    cp "$SCRIPT_DIR/autossh-comfyui@.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable autossh-monitor.service

    # 交互式配置（不从环境读取）
    echo "请选择该GPU节点的类型偏好（可回车跳过）："
    echo "1) text2image"
    echo "2) image2image"
    echo "3) depth-control"
    echo "4) 其他/跳过"
    read -p "节点类型 (1/2/3/4) [默认: 4]: " input_node_type_idx
    case ${input_node_type_idx} in
        1) NODE_TYPE="text2image" ;;
        2) NODE_TYPE="image2image" ;;
        3) NODE_TYPE="depth-control" ;;
        *) NODE_TYPE="" ;;
    esac

    read -p "请输入控制端SSH目标(如 user@host) [默认: serhk]: " input_remote_host
    REMOTE_HOST=${input_remote_host:-serhk}
    read -p "请输入该节点在控制端使用的远程端口 [默认: 8081]: " input_remote_port
    REMOTE_PORT=${input_remote_port:-8081}

    # 显示确认信息
    echo "\n配置预览："
    echo "- 节点类型: ${NODE_TYPE:-未设置}"
    echo "- 控制端SSH: ${REMOTE_HOST}"
    echo "- 远程端口: ${REMOTE_PORT}"
    read -p "确认安装并启动? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        exit 0
    fi

    # 写入配置文件
    echo "${REMOTE_HOST}" > /etc/autossh-remote-host
    echo "${REMOTE_PORT}" > /etc/autossh-remote-port

    # 为 autossh systemd 模板提供变量
    cat >/etc/autossh-comfyui.env <<EOF
REMOTE_HOST="${REMOTE_HOST}"
LOCAL_PORT="8081"
NODE_TYPE="${NODE_TYPE}"
EOF

    # 启用并启动 autossh 反向隧道实例
    systemctl enable autossh-comfyui@"${REMOTE_PORT}".service
    
    echo "GPU服务器监控安装完成"
    echo "启动autossh反向隧道与监控服务..."
    systemctl start autossh-comfyui@"${REMOTE_PORT}".service
    systemctl start autossh-monitor.service
    
elif [ "$SERVER_TYPE" = "cloud" ]; then
    echo "=== 在云服务器上安装监控 ==="
    
    # 复制云服务器监控脚本
    cp "$SCRIPT_DIR/cloud_monitor.sh" /usr/local/bin/
    chmod +x /usr/local/bin/cloud_monitor.sh
    
    # 安装systemd服务模板
    cp "$SCRIPT_DIR/cloud-port-monitor@.service" /etc/systemd/system/
    systemctl daemon-reload

    # 输入需要监控的端口（可多个，用逗号分隔）
    read -p "请输入需要监控的转发端口（可多个，用逗号分隔）[默认: 8081]: " input_ports
    MONITOR_PORTS=${input_ports:-8081}

    # 启用/启动每个端口的实例
    IFS=',' read -ra PORT_ARRAY <<< "$MONITOR_PORTS"
    for p in "${PORT_ARRAY[@]}"; do
      PORT_TRIM=$(echo "$p" | xargs)
      if [ -n "$PORT_TRIM" ]; then
        echo "启用 cloud-port-monitor@${PORT_TRIM}.service"
        systemctl enable cloud-port-monitor@"${PORT_TRIM}".service
        systemctl start cloud-port-monitor@"${PORT_TRIM}".service
      fi
    done
    
    echo "云服务器监控安装完成"
fi

# 创建日志目录
mkdir -p /var/log

echo "=== 安装完成 ==="
echo "监控服务已启动并设置为开机自启"
echo "日志文件位置："
if [ "$SERVER_TYPE" = "gpu" ]; then
    echo "- GPU监控日志: /var/log/autossh_monitor.log"
    echo "查看状态: systemctl status autossh-monitor.service"
else
    echo "- 端口转发监控日志: /var/log/port_forward_monitor.log"
    echo "查看状态: systemctl status cloud-port-monitor@<port>.service"
fi

echo "查看实时日志: journalctl -u [服务名] -f" 
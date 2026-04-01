#!/bin/bash

# SSH端口修改脚本
# 功能：安全地修改SSH服务端口，包含备份、检查、测试等完整流程
# 作者：OpenClaw Assistant
# 版本：2.0

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root用户运行"
        exit 1
    fi
}

# 生成随机端口 (1024-65535之间，避开常见端口)
generate_random_port() {
    local common_ports="20 21 22 23 25 53 80 110 143 443 465 587 993 995 3306 3389 5432 6379 8080 8443 9200 27017"
    local port
    
    while true; do
        # 生成1024-65535的随机数
        port=$((RANDOM % 64512 + 1024))
        
        # 检查是否是常见端口
        if [[ " $common_ports " =~ " $port " ]]; then
            continue
        fi
        
        # 检查是否被占用
        if ! ss -tuln 2>/dev/null | grep -q ":${port}\b"; then
            echo "$port"
            return 0
        fi
    done
}

# 检查端口是否有效
check_port_valid() {
    local port=$1
    if ! [[ $port =~ ^[0-9]+$ ]]; then
        log_error "端口必须是数字"
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        log_error "端口必须在1-65535范围内"
        return 1
    fi
    if (( port < 1024 )); then
        log_warning "选择的是特权端口(<1024)，需要确保无其他服务占用"
    fi
    return 0
}

# 检查端口是否被占用
check_port_in_use() {
    local port=$1
    if ss -tuln 2>/dev/null | grep -q ":${port}\b"; then
        log_error "端口 ${port} 已被占用"
        return 1
    fi
    return 0
}

# 备份SSH配置
backup_sshd_config() {
    local config_file="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [[ -f $config_file ]]; then
        cp "$config_file" "$backup_file"
        log_success "SSH配置已备份到: $backup_file"
        echo "$backup_file"
        return 0
    else
        log_error "找不到SSH配置文件: $config_file"
        return 1
    fi
}

# 获取当前SSH端口
get_current_port() {
    local port=$(/usr/sbin/sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' || echo "22")
    echo "$port"
}

# 修改SSH配置
modify_sshd_config() {
    local new_port=$1
    local config_file="/etc/ssh/sshd_config"
    
    # 先移除所有Port配置（注释或未注释的）
    sed -i '/^[[:space:]]*Port[[:space:]]/d' "$config_file"
    
    # 在合适位置添加新的Port配置（在ListenAddress之前或文件开头）
    if grep -q "^ListenAddress" "$config_file"; then
        sed -i "/^ListenAddress/i Port $new_port" "$config_file"
    else
        sed -i "1i Port $new_port" "$config_file"
    fi
    
    # 验证配置
    if ! /usr/sbin/sshd -t; then
        log_error "SSH配置验证失败，请检查配置"
        return 1
    fi
    
    log_success "SSH配置已更新为端口: $new_port"
    return 0
}

# 处理SELinux
configure_selinux() {
    local new_port=$1
    
    if ! command -v semanage &> /dev/null; then
        log_info "SELinux工具未安装，跳过SELinux配置"
        return 0
    fi
    
    if ! sestatus 2>/dev/null | grep -q "Current mode.*enforcing"; then
        log_info "SELinux未处于enforcing模式，跳过SELinux配置"
        return 0
    fi
    
    log_info "配置SELinux允许端口 $new_port..."
    
    # 检查端口是否已在SSH端口类型中
    if semanage port -l 2>/dev/null | grep -q "ssh_port_t.*${new_port}\b"; then
        log_info "SELinux已允许端口 $new_port"
        return 0
    fi
    
    # 添加端口
    if semanage port -a -t ssh_port_t -p tcp "$new_port" 2>/dev/null; then
        log_success "SELinux已配置允许端口 $new_port"
    else
        log_warning "SELinux配置可能需要手动调整"
    fi
}

# 处理防火墙
configure_firewall() {
    local new_port=$1
    
    # 检查ufw
    if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "配置UFW防火墙..."
        ufw allow "$new_port/tcp" 2>/dev/null || true
        log_success "UFW已允许端口 $new_port"
        return 0
    fi
    
    # 检查firewalld
    if command -v firewall-cmd &> /dev/null && firewall-cmd --state 2>/dev/null; then
        log_info "配置firewalld防火墙..."
        firewall-cmd --permanent --add-port="${new_port}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_success "firewalld已允许端口 $new_port"
        return 0
    fi
    
    log_info "未检测到活动的防火墙(ufw/firewalld)，跳过防火墙配置"
    log_warning "请确保云服务商安全组已放行端口 $new_port"
}

# 停止ssh.socket（如果存在）
stop_ssh_socket() {
    if systemctl list-unit-files 2>/dev/null | grep -q "ssh.socket"; then
        log_info "检测到ssh.socket，正在停止并禁用..."
        systemctl stop ssh.socket 2>/dev/null || true
        systemctl disable ssh.socket 2>/dev/null || true
        log_success "ssh.socket已停止并禁用"
    fi
}

# 重启SSH服务
restart_sshd() {
    log_info "正在重启SSH服务..."
    
    if systemctl restart sshd; then
        sleep 2
        if systemctl is-active --quiet sshd; then
            log_success "SSH服务重启成功"
            return 0
        fi
    fi
    
    log_error "SSH服务启动失败"
    return 1
}

# 验证新端口是否监听
verify_port_listening() {
    local port=$1
    local max_attempts=10
    local attempt=1
    
    log_info "验证端口 $port 是否正在监听..."
    
    while (( attempt <= max_attempts )); do
        if ss -tuln 2>/dev/null | grep -q ":${port}\b"; then
            log_success "端口 $port 正在监听"
            return 0
        fi
        log_info "等待端口启动... (${attempt}/${max_attempts})"
        sleep 2
        (( attempt++ ))
    done
    
    log_error "端口 $port 未能在预期时间内启动监听"
    return 1
}

# 回滚函数
rollback() {
    local backup_file=$1
    log_warning "正在执行回滚操作..."
    
    if [[ -n $backup_file && -f $backup_file ]]; then
        cp "$backup_file" "/etc/ssh/sshd_config"
        log_success "配置已从备份恢复"
        systemctl restart sshd 2>/dev/null || true
        log_info "SSH服务已重启"
    else
        log_error "没有可用的备份文件，无法自动回滚"
    fi
}

# 显示使用帮助
show_help() {
    cat << EOF
用法: $0 [选项] [端口号]

选项:
    -h, --help      显示帮助信息
    -r, --random    使用随机端口(1024-65535，避开常见端口)

参数:
    端口号          指定新的SSH端口(1-65535)

示例:
    $0 2222                    # 使用指定端口2222
    $0 -r                      # 使用随机生成的端口
    $0 --random                # 同上
    curl -fsSL <脚本URL> | sudo bash -s -- 2222    # 远程执行指定端口
    curl -fsSL <脚本URL> | sudo bash -s -- -r      # 远程执行随机端口

EOF
}

# 主函数
main() {
    local new_port=""
    local use_random=false
    
    echo "========================================="
    echo "       SSH 端口修改脚本 v2.0"
    echo "========================================="
    echo
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -r|--random)
                use_random=true
                shift
                ;;
            [0-9]*)
                new_port=$1
                shift
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 检查root
    check_root
    
    # 获取当前端口
    local current_port=$(get_current_port)
    log_info "当前SSH端口: $current_port"
    
    # 确定新端口
    if [[ "$use_random" == true ]]; then
        new_port=$(generate_random_port)
        log_info "生成的随机端口: $new_port"
    elif [[ -z $new_port ]]; then
        # 交互模式：要求用户输入
        read -p "请输入新的SSH端口 (1-65535, 或直接回车生成随机端口): " input_port
        
        if [[ -z $input_port ]]; then
            new_port=$(generate_random_port)
            log_info "已生成随机端口: $new_port"
        else
            new_port=$input_port
        fi
    fi
    
    # 验证端口
    if ! check_port_valid "$new_port"; then
        exit 1
    fi
    
    if [[ $new_port -eq $current_port ]]; then
        log_warning "新端口与当前端口相同，无需修改"
        exit 0
    fi
    
    # 检查端口占用
    if ! check_port_in_use "$new_port"; then
        exit 1
    fi
    
    echo
    log_info "准备将SSH端口从 $current_port 修改为 $new_port"
    read -p "确认继续? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "用户取消操作"
        exit 0
    fi
    echo
    
    # 备份配置
    local backup_file=""
    backup_file=$(backup_sshd_config) || exit 1
    
    # 设置回滚陷阱
    trap 'rollback "$backup_file"' ERR
    
    # 修改配置
    modify_sshd_config "$new_port" || exit 1
    
    # 配置SELinux
    configure_selinux "$new_port"
    
    # 配置防火墙
    configure_firewall "$new_port"
    
    # 停止ssh.socket
    stop_ssh_socket
    
    # 重启SSH服务
    restart_sshd || exit 1
    
    # 验证端口监听
    verify_port_listening "$new_port" || exit 1
    
    # 移除回滚陷阱
    trap - ERR
    
    echo
    echo "========================================="
    log_success "SSH端口修改完成！"
    echo "========================================="
    echo
    echo "📋 修改摘要："
    echo "   旧端口: $current_port"
    echo "   新端口: $new_port"
    echo "   配置备份: $backup_file"
    echo
    echo "⚠️  重要提示："
    echo "   1. 不要关闭当前会话！"
    echo "   2. 新开一个终端窗口测试连接："
    echo "      ssh -p $new_port user@your-server"
    echo "   3. 确认新端口可以连接后再关闭当前会话"
    echo "   4. 如遇到问题，可以从备份恢复："
    echo "      cp $backup_file /etc/ssh/sshd_config"
    echo "      systemctl restart sshd"
    echo "   5. 记得检查云服务商安全组是否已放行 $new_port 端口！"
    echo
    
    # 记录使用的端口到日志（方便查看历史）
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Changed from $current_port to $new_port" >> /var/log/ssh-port-changes.log 2>/dev/null || true
}

# 运行主函数
main "$@"

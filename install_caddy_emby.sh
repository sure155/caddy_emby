#!/bin/bash

# ====================================================
#  Caddy Reverse Proxy for Emby - Pro Script
#  Author: AiLi1337
#  Github: https://github.com/AiLi1337/install_caddy_emby
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 检查是否为 root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

# 基础函数
log() { echo -e "${GREEN}[Info]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[Warning]${PLAIN} $1"; }
error() { echo -e "${RED}[Error]${PLAIN} $1"; }

# 1. 安装环境检测与安装
install_base() {
    log "正在更新系统并安装必要组件..."
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y curl wget sudo socat
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget sudo socat
    fi
}

install_caddy() {
    if command -v caddy &> /dev/null; then
        warn "Caddy 已安装，跳过安装步骤。"
        return
    fi

    log "正在安装 Caddy..."
    if [ -f /etc/debian_version ]; then
        apt install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update
        apt install caddy -y
    elif [ -f /etc/redhat-release ]; then
        yum install yum-plugin-copr -y
        yum copr enable @caddyserver/caddy -y
        yum install caddy -y
    fi
    
    systemctl enable caddy
    log "Caddy 安装完成！"
}

# 2. 配置向导 (核心部分)
configure_caddy() {
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}Caddy 反代 Emby 配置向导${PLAIN}"
    echo -e "------------------------------------------------"

    # 使用 /dev/tty 确保支持 curl | bash 模式下的交互
    read -p "请输入你的域名 (例如 emby.test.com): " DOMAIN < /dev/tty
    if [[ -z "$DOMAIN" ]]; then
        error "域名不能为空！"
        return
    fi

    read -p "请输入你的邮箱 (用于 SSL 证书申请): " EMAIL < /dev/tty
    if [[ -z "$EMAIL" ]]; then
        warn "邮箱为空，建议填写以免证书申请受限。"
    fi

    read -p "请输入 Emby 内网地址 (默认 127.0.0.1:8096): " EMBY_ADDRESS < /dev/tty
    if [[ -z "$EMBY_ADDRESS" ]]; then
        EMBY_ADDRESS="127.0.0.1:8096"
    fi

    # 备份旧配置
    if [ -f /etc/caddy/Caddyfile ]; then
        cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%F_%H%M%S)
        warn "已备份原配置文件为 Caddyfile.bak_日期"
    fi

    log "正在生成配置文件..."

    cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    ${EMAIL:+email $EMAIL}
    encode gzip
    
    # 允许跨域 (可选，解决部分客户端连接问题)
    header {
        Access-Control-Allow-Origin *
    }

    reverse_proxy $EMBY_ADDRESS {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF

    log "配置已写入。正在重启 Caddy..."
    systemctl restart caddy
    
    if systemctl is-active --quiet caddy; then
        echo -e "\n${GREEN}=========================================="
        echo -e " 恭喜！反代配置成功！"
        echo -e " 访问地址: https://$DOMAIN"
        echo -e "==========================================${PLAIN}"
    else
        error "Caddy 启动失败！请检查域名解析或端口占用。"
        echo "查看日志: systemctl status caddy -l"
    fi
}

# 3. 卸载功能
uninstall_caddy() {
    read -p "确定要卸载 Caddy 吗? [y/N] " confirm < /dev/tty
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop caddy
        if [ -f /etc/debian_version ]; then
            apt remove caddy -y
        elif [ -f /etc/redhat-release ]; then
            yum remove caddy -y
        fi
        rm -rf /etc/caddy
        log "Caddy 已卸载。"
    else
        log "已取消卸载。"
    fi
}

# 4. 菜单系统
menu() {
    clear
    echo -e "#################################################"
    echo -e "#    Caddy + Emby 一键反代脚本 (Pro Ver)        #"
    echo -e "#    Author: AiLi1337                           #"
    echo -e "#################################################"
    echo -e ""
    echo -e " ${GREEN}1.${PLAIN} 安装 Caddy 并配置反代"
    echo -e " ${GREEN}2.${PLAIN} 仅修改配置 (重新设置域名/IP)"
    echo -e " ${GREEN}3.${PLAIN} 查看 Caddy 运行状态"
    echo -e " ${GREEN}4.${PLAIN} 停止 Caddy 服务"
    echo -e " ${GREEN}5.${PLAIN} 重启 Caddy 服务"
    echo -e " ${RED}6.${PLAIN} 卸载 Caddy"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e ""
    read -p " 请输入数字 [0-6]: " num < /dev/tty

    case "$num" in
        1) install_base; install_caddy; configure_caddy ;;
        2) configure_caddy ;;
        3) systemctl status caddy ;;
        4) systemctl stop caddy; log "服务已停止" ;;
        5) systemctl restart caddy; log "服务已重启" ;;
        6) uninstall_caddy ;;
        0) exit 0 ;;
        *) error "请输入正确的数字" ;;
    esac
}

# 运行菜单
menu

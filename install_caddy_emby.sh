#!/bin/bash

# ====================================================
#  Caddy Reverse Proxy for Emby - V5 (Safe Peak Optimized)
#  基于原脚本，仅做稳定性优化，保证可启动
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！" && exit 1

log()   { echo -e "${GREEN}[Info]${PLAIN} $1"; }
warn()  { echo -e "${YELLOW}[Warn]${PLAIN} $1"; }
error() { echo -e "${RED}[Error]${PLAIN} $1"; }

install_base() {
    log "检查基础组件..."
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y curl wget sudo socat net-tools psmisc sed grep
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget sudo socat net-tools psmisc sed grep
    fi
}

check_port() {
    echo -e "${SKYBLUE}检查 80 / 443 端口占用${PLAIN}"
    command -v netstat >/dev/null && netstat -tunlp | grep -E ":80|:443" || ss -tulpn | grep -E ":80|:443"
}

kill_port() {
    warn "强制清理 80 / 443 端口"
    systemctl stop nginx apache2 httpd 2>/dev/null
    systemctl disable nginx apache2 httpd 2>/dev/null
    fuser -k 80/tcp 443/tcp 2>/dev/null
    log "端口清理完成"
}

install_caddy() {
    if command -v caddy >/dev/null; then
        warn "Caddy 已安装"
        return
    fi

    install_base
    log "安装 Caddy..."

    if [ -f /etc/debian_version ]; then
        apt install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
          | gpg --dearmor -o /usr/share/keyrings/caddy-stable.gpg
        curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
          | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update && apt install -y caddy
    else
        yum install -y yum-plugin-copr
        yum copr enable @caddyserver/caddy -y
        yum install -y caddy
    fi

    systemctl enable caddy
    log "Caddy 安装完成"
}

configure_caddy() {
    echo -e "${SKYBLUE}Caddy 反代 Emby 配置（稳定高峰期优化）${PLAIN}"

    MODE="new"
    if [ -s /etc/caddy/Caddyfile ]; then
        echo "检测到已有配置："
        echo "1 覆盖  2 追加"
        read -p "请选择 [1-2]: " m
        [[ "$m" == "2" ]] && MODE="append"
    fi

    while true; do
        read -p "请输入域名（回车结束）: " DOMAIN
        [[ -z "$DOMAIN" ]] && break

        read -p "请输入 Emby 后端地址 [127.0.0.1:8096]: " EMBY_ADDRESS
        [[ -z "$EMBY_ADDRESS" ]] && EMBY_ADDRESS="127.0.0.1:8096"

        cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%F_%H%M%S) 2>/dev/null

        if [[ "$MODE" == "append" ]]; then
            sed -i "/^$DOMAIN {/,/^}/d" /etc/caddy/Caddyfile 2>/dev/null
            sed -i '/^\s*$/d' /etc/caddy/Caddyfile
        fi

        CONFIG_BLOCK="$DOMAIN {
    header Access-Control-Allow-Origin *
    header Access-Control-Allow-Methods GET,POST,OPTIONS

    reverse_proxy $EMBY_ADDRESS {
        transport http {
            versions 1.1
        }
        flush_interval -1
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up Host {upstream_hostport}
    }
}"

        if [[ "$MODE" == "new" ]]; then
            echo "$CONFIG_BLOCK" > /etc/caddy/Caddyfile
            MODE="append"
        else
            echo "" >> /etc/caddy/Caddyfile
            echo "$CONFIG_BLOCK" >> /etc/caddy/Caddyfile
        fi

        log "域名 $DOMAIN 已添加"
    done

    restart_caddy
}

delete_config() {
    [[ ! -f /etc/caddy/Caddyfile ]] && error "未找到配置文件" && return

    grep -E "^[a-zA-Z0-9.-]+ \{" /etc/caddy/Caddyfile | awk '{print $1}' > /tmp/caddy_domains.txt
    cat /tmp/caddy_domains.txt

    read -p "输入要删除的域名: " DEL_DOMAIN
    sed -i "/^$DEL_DOMAIN {/,/^}/d" /etc/caddy/Caddyfile
    sed -i '/^\s*$/d' /etc/caddy/Caddyfile
    restart_caddy
}

restart_caddy() {
    log "重启 Caddy..."
    systemctl restart caddy
    sleep 2
    systemctl is-active --quiet caddy && log "Caddy 运行正常" || error "Caddy 启动失败，请检查日志"
}

show_menu() {
    clear
    echo "===================================="
    echo " Caddy + Emby 管理脚本（稳定版）"
    echo "===================================="
    echo "1. 安装 Caddy"
    echo "2. 添加 / 更新 Emby 反代"
    echo "3. 删除站点"
    echo "4. 查看 Caddyfile"
    echo "5. 停止 Caddy"
    echo "6. 重启 Caddy"
    echo "7. 检查端口"
    echo "8. 强制清理端口"
    echo "9. 卸载 Caddy"
    echo "0. 退出"
    read -p "请选择: " num

    case "$num" in
        1) install_caddy ;;
        2) configure_caddy ;;
        3) delete_config ;;
        4) cat /etc/caddy/Caddyfile ;;
        5) systemctl stop caddy ;;
        6) restart_caddy ;;
        7) check_port ;;
        8) kill_port ;;
        9) apt remove -y caddy 2>/dev/null; yum remove -y caddy 2>/dev/null; rm -rf /etc/caddy ;;
        0) exit ;;
        *) error "无效选择" ;;
    esac
}

while true; do
    show_menu
    read -p "回车继续..."
done

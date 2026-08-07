#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Caddy Reverse Proxy for Public Emby
# V7 Optimized Edition
#
# Target:
# Oracle ARM VPS
# Multiple Public Emby
# Shield TV
# 4K Remux Streaming
#
# Features:
#
# - Auto HTTPS
# - Multi Emby nodes
# - Range streaming
# - HTTP/3
# - Long connection optimization
# - Hide upstream
# - Static cache
# - Video no-cache
#
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
CADDYFILE="/etc/caddy/Caddyfile"
BACKUP_DIR="/etc/caddy/backup"
LOG_DIR="/var/log/caddy"
if [[ "${EUID}" -ne 0 ]]; then
echo -e "${RED}必须使用 root 运行${PLAIN}"
exit 1
fi
log(){
echo -e "${GREEN}[INFO]${PLAIN} $*"
}
warn(){
echo -e "${YELLOW}[WARN]${PLAIN} $*"
}
err(){
echo -e "${RED}[ERROR]${PLAIN} $*"
}
pause(){
echo
read -rp "按回车继续..." _
}
has_cmd(){
command -v "$1" >/dev/null 2>&1
}
detect_pm(){
if has_cmd apt;
then
echo apt
elif has_cmd dnf;
then
echo dnf
elif has_cmd yum;
then
echo yum
else
echo unknown
fi
}
init_dirs(){
mkdir -p \
/etc/caddy \
"$BACKUP_DIR" \
"$LOG_DIR"
if id caddy >/dev/null 2>&1;
then
chown -R caddy:caddy "$LOG_DIR" || true
fi
}
backup(){
init_dirs
if [[ -f "$CADDYFILE" ]];
then
cp "$CADDYFILE" \
"$BACKUP_DIR/Caddyfile.$(date +%F_%H%M%S).bak"
fi
}
install_base(){
local pm
pm=$(detect_pm)
case "$pm" in
apt)
apt update -y
apt install -y \
curl \
wget \
sudo \
socat \
net-tools \
psmisc \
gnupg \
ca-certificates \
debian-keyring \
debian-archive-keyring \
apt-transport-https
;;
dnf)
dnf install -y \
curl \
wget \
sudo \
socat \
net-tools \
gnupg2 \
ca-certificates
;;
yum)
yum install -y \
curl \
wget \
sudo \
socat \
net-tools \
gnupg2 \
ca-certificates
;;
*)
err "不支持系统"
return 1
;;
esac
}
install_caddy(){
if has_cmd caddy;
then
log "Caddy 已安装"
return
fi
install_base
local pm
pm=$(detect_pm)
case "$pm" in
apt)
curl -1sLf \
'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
| gpg --dearmor \
-o /usr/share/keyrings/caddy.gpg
curl -1sLf \
'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
> /etc/apt/sources.list.d/caddy.list
apt update -y
apt install -y caddy
;;
dnf)
dnf install -y 'dnf-command(copr)' || true
dnf copr enable -y @caddyserver/caddy || true
dnf install -y caddy
;;
yum)
yum install -y yum-plugin-copr || true
yum copr enable -y @caddyserver/caddy || true
yum install -y caddy
;;
esac
systemctl enable caddy
systemctl start caddy || true
log "Caddy 安装完成"
}
validate(){
local file="$1"
caddy fmt \
--overwrite \
"$file" >/dev/null 2>&1 || true
caddy validate \
--config "$file" \
--adapter caddyfile
}
reload(){
if systemctl is-active --quiet caddy;
then
systemctl reload caddy || systemctl restart caddy
else
systemctl restart caddy
fi
}
init_caddyfile(){
init_dirs
if [[ ! -f "$CADDYFILE" ]];
then
cat > "$CADDYFILE" <<EOF
{
servers {
protocols h1 h2 h3
}
}
EOF
fi
}
# ===== 第1部分结束 =====
# ============================================================
# Emby Site Generator
# ============================================================
generate_site(){
local DOMAIN="$1"
local UPSTREAM="$2"
local MODE="$3"
local UP_HOST
local UP_PORT
local TLS_NAME
UP_HOST=$(echo "$UPSTREAM" \
| sed -E 's#https?://([^:/]+).*#\1#')
TLS_NAME="$UP_HOST"
if [[ "$UPSTREAM" =~ :([0-9]+)$ ]];
then
UP_PORT="${BASH_REMATCH[1]}"
else
if [[ "$UPSTREAM" == https* ]];
then
UP_PORT="443"
else
UP_PORT="80"
fi
fi
cat >> "$CADDYFILE" <<EOF
# ============================================================
# Emby Node
#
# Domain:
# $DOMAIN
#
# Upstream:
# $UPSTREAM
#
# ============================================================
$DOMAIN {
    encode off
    # -----------------------------
    # 静态资源缓存
    # -----------------------------
    @static {
        path \
        /web/* \
        /Items/*/Images/* \
        /Users/*/Images/*
        file {
            extensions .js .css .png .jpg .jpeg .webp .svg .ico .woff .woff2
        }
    }
    header @static Cache-Control "public,max-age=2592000,immutable"
    # -----------------------------
    # Emby 视频流
    #
    # 禁止缓存
    # 保留 Range
    # -----------------------------
    @video {
        path \
        /Videos/* \
        /Audio/* \
        /Items/*/Download* \
        /Playback/* \
        /Sessions/* \
        /Sync/*
    }
    header @video Cache-Control "no-store"
    header @video X-Accel-Buffering "no"
    # -----------------------------
    # 反向代理
    # -----------------------------
    reverse_proxy $UPSTREAM {
        # 流媒体关键
        flush_interval -1
        transport http {
            # TCP连接
            dial_timeout 10s
            response_header_timeout 120s
            read_timeout 0
            write_timeout 0
            idle_timeout 30m
            # Oracle ARM 多用户优化
            keepalive 256
            keepalive_idle_conns 256
            keepalive_idle_conns_per_host 64
            # 大文件缓冲
            read_buffer 65536
            write_buffer 65536
            # HTTPS 上游
            tls_server_name $TLS_NAME
        }
        # -----------------------------
        # 请求头
        # -----------------------------
        header_up Host $UP_HOST
        header_up Accept-Encoding identity
        header_up Range {http.request.header.Range}
        header_up If-Range {http.request.header.If-Range}
        # 保持 WebSocket
        header_up Connection {http.request.header.Connection}
        header_up Upgrade {http.request.header.Upgrade}
        # -----------------------------
        # 公费 Emby 隐私模式
        #
        # 不暴露真实客户端IP
        #
        # -----------------------------
        header_up -X-Forwarded-For
        header_up -X-Real-IP
        header_up -CF-Connecting-IP
        # -----------------------------
        # 隐藏版本信息
        # -----------------------------
        header_down -Server
        header_down -X-Powered-By
        header_down -X-Emby-Version
    }
}
EOF
}
# ============================================================
# 添加 Emby 节点
# ============================================================
add_emby(){
backup
echo
echo "=============================="
echo "添加 Emby 节点"
echo "=============================="
read -rp "输入访问域名(例如 emby1.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]];
then
err "域名不能为空"
return
fi
read -rp "输入上游Emby地址(例如 https://abc.com): " UPSTREAM
if [[ -z "$UPSTREAM" ]];
then
err "上游不能为空"
return
fi
read -rp "模式(normal/strict，默认strict): " MODE
MODE=${MODE:-strict}
generate_site \
"$DOMAIN" \
"$UPSTREAM" \
"$MODE"
if validate "$CADDYFILE";
then
reload
echo
log "Emby节点添加成功"
echo
echo "访问地址:"
echo "https://$DOMAIN"
else
err "配置错误，恢复备份"
cp \
"$(ls -t $BACKUP_DIR/Caddyfile.* 2>/dev/null | head -1)" \
"$CADDYFILE"
fi
}
# ============================================================
# 查看当前配置
# ============================================================
show_config(){
echo
echo "=============================="
echo "当前 Caddy 配置"
echo "=============================="
cat "$CADDYFILE"
pause
}
# ============================================================
# 查看运行状态
# ============================================================
status(){
systemctl status caddy \
--no-pager
pause
}
# ===== 第2部分结束 =====
# ============================================================
# 删除 Emby 节点
# ============================================================
delete_emby(){
backup
echo
echo "当前 Caddy 配置："
echo
grep -E "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" \
"$CADDYFILE" || true
echo
read -rp "输入要删除的域名: " DOMAIN
if [[ -z "$DOMAIN" ]];
then
err "域名不能为空"
return
fi
sed -i \
"/^$DOMAIN {/,/^}/d" \
"$CADDYFILE"
if validate "$CADDYFILE";
then
reload
log "删除完成"
else
err "删除失败，恢复备份"
cp \
"$(ls -t $BACKUP_DIR/Caddyfile.* 2>/dev/null | head -1)" \
"$CADDYFILE"
fi
pause
}
# ============================================================
# 查看日志
# ============================================================
show_log(){
echo
echo "最近 Caddy 日志"
echo "=============================="
journalctl \
-u caddy \
-n 100 \
--no-pager
pause
}
# ============================================================
# 重载配置
# ============================================================
reload_menu(){
if validate "$CADDYFILE";
then
reload
log "Caddy 已重新加载"
else
err "配置错误"
fi
pause
}
# ============================================================
# 检查端口
# ============================================================
check_port(){
echo
echo "监听端口："
echo
ss -lntp \
| grep -E ":80|:443" \
|| true
pause
}
# ============================================================
# 更新 Caddy
# ============================================================
update_caddy(){
echo
log "更新 Caddy"
local pm
pm=$(detect_pm)
case "$pm" in
apt)
apt update
apt upgrade caddy -y
;;
dnf)
dnf update caddy -y
;;
yum)
yum update caddy -y
;;
*)
warn "无法自动更新"
;;
esac
systemctl restart caddy
pause
}
# ============================================================
# 卸载
# ============================================================
uninstall(){
echo
read -rp "确认卸载 Caddy? 输入 YES: " OK
if [[ "$OK" != "YES" ]];
then
return
fi
systemctl stop caddy || true
systemctl disable caddy || true
local pm
pm=$(detect_pm)
case "$pm" in
apt)
apt remove caddy -y
;;
dnf)
dnf remove caddy -y
;;
yum)
yum remove caddy -y
;;
esac
echo
log "Caddy 已卸载"
}
# ============================================================
# 主菜单
# ============================================================
menu(){
while true
do
clear
echo -e "${CYAN}"
cat <<EOF
================================================
 Caddy Emby Reverse Proxy V7
 Oracle ARM + Multi Emby + 4K Remux
================================================
1. 安装 Caddy
2. 初始化配置
3. 添加 Emby 节点
4. 删除 Emby 节点
5. 查看配置
6. 查看状态
7. 查看日志
8. 检查端口
9. 重载 Caddy
10. 更新 Caddy
11. 卸载 Caddy
0. 退出
================================================
EOF
echo -e "${PLAIN}"
read -rp "请选择: " NUM
case "$NUM" in
1)
install_caddy
pause
;;
2)
init_caddyfile
log "初始化完成"
pause
;;
3)
add_emby
;;
4)
delete_emby
;;
5)
show_config
;;
6)
status
;;
7)
show_log
;;
8)
check_port
;;
9)
reload_menu
;;
10)
update_caddy
;;
11)
uninstall
pause
;;
0)
exit 0
;;
*)
echo "无效选择"
sleep 1
;;
esac
done
}
# ============================================================
# Main
# ============================================================
init_dirs
menu

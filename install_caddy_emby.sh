#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Caddy Reverse Proxy for Public Emby (V6.1 Final Stable+)
# Maintainer: sure155 (optimized)
# Project: https://github.com/sure155/caddy_emby
# 场景：上游 Emby 不可控（公费/共享）
# 目标：隐私优先、兼容可切换、可维护
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CADDYFILE="/etc/caddy/Caddyfile"
BACKUP_DIR="/etc/caddy/backup"
LOG_DIR="/var/log/caddy"
BACKUP_KEEP=20   # 备份保留份数，超出自动清理旧备份

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
echo -e "${RED}[Error]${PLAIN} 必须使用 root 运行"
exit 1
fi

log() { echo -e "${GREEN}[Info]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[Warn]${PLAIN} $*"; }
err() { echo -e "${RED}[Error]${PLAIN} $*"; }

# ---- 出错追踪：出问题时告诉用户是哪一行/哪个命令 ----
on_err() {
local exit_code=$?
local line_no=${BASH_LINENO[0]:-0}
err "脚本在第 ${line_no} 行执行失败（exit=${exit_code}）：${BASH_COMMAND}"
}
trap on_err ERR

# ---- 临时文件跟踪，脚本任何原因退出都会清理，避免 /tmp 残留 ----
TMP_FILES=()
cleanup_tmp() {
local f
for f in "${TMP_FILES[@]:-}"; do
[[ -n "${f:-}" && -f "$f" ]] && rm -f "$f"
done
}
trap cleanup_tmp EXIT

mktemp_track() {
local f
f="$(mktemp)"
TMP_FILES+=("$f")
echo "$f"
}

pause() {
echo
read -r -p "按回车返回菜单..." _ < /dev/tty
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pm() {
if has_cmd apt; then
echo "apt"
elif has_cmd dnf; then
echo "dnf"
elif has_cmd yum; then
echo "yum"
else
echo "unknown"
fi
}

ensure_dirs() {
mkdir -p /etc/caddy "$BACKUP_DIR" "$LOG_DIR"
if id caddy >/dev/null 2>&1; then
chown -R caddy:caddy "$LOG_DIR" || true
fi
}

ensure_caddyfile_minimal() {
ensure_dirs
if [[ ! -f "$CADDYFILE" ]]; then
cat > "$CADDYFILE" <<'EOF'
{
# global options
}
EOF
fi
}

prune_backups() {
# 只保留最近 BACKUP_KEEP 份备份，避免无限增长
[[ -d "$BACKUP_DIR" ]] || return 0
local count
count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'Caddyfile.*.bak' | wc -l)"
if (( count > BACKUP_KEEP )); then
find "$BACKUP_DIR" -maxdepth 1 -name 'Caddyfile.*.bak' -printf '%T@ %p\n' 2>/dev/null \
| sort -n \
| head -n "$(( count - BACKUP_KEEP ))" \
| awk '{ $1=""; sub(/^ /,""); print }' \
| xargs -r rm -f
fi
}

backup_caddyfile() {
ensure_dirs
if [[ -f "$CADDYFILE" ]]; then
cp -a "$CADDYFILE" "$BACKUP_DIR/Caddyfile.$(date +%F_%H%M%S).bak"
prune_backups
fi
}

install_base() {
log "检查并安装基础依赖..."
local pm
pm="$(detect_pm)"

case "$pm" in
apt)
apt update -y
apt install -y curl wget sudo socat net-tools psmisc sed grep gawk gnupg ca-certificates lsb-release
;;
dnf)
dnf install -y curl wget sudo socat net-tools psmisc sed grep gawk gnupg2 ca-certificates
;;
yum)
yum install -y curl wget sudo socat net-tools psmisc sed grep gawk gnupg2 ca-certificates
;;
*)
err "不支持的系统包管理器，请手动安装依赖。"
return 1
;;
esac
}

install_caddy() {
ensure_caddyfile_minimal

if has_cmd caddy; then
warn "Caddy 已安装：$(caddy version 2>/dev/null || true)"
return 0
fi

install_base
local pm
pm="$(detect_pm)"
log "安装 Caddy..."

case "$pm" in
apt)
apt install -y debian-keyring debian-archive-keyring apt-transport-https
mkdir -p /usr/share/keyrings
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
| gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
> /etc/apt/sources.list.d/caddy-stable.list
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
*)
err "不支持的系统包管理器，无法自动安装 Caddy。"
return 1
;;
esac

systemctl enable caddy
systemctl start caddy || true
log "Caddy 安装完成。"
}

check_ports() {
echo -e "${CYAN}=== 80/443 端口占用 ===${PLAIN}"
local found=0
if has_cmd ss; then
if ss -tulpn 2>/dev/null | grep -E ':(80|443)\b'; then
found=1
fi
elif has_cmd netstat; then
if netstat -tunlp 2>/dev/null | grep -E ':(80|443)\b'; then
found=1
fi
else
warn "ss/netstat 都不可用"
return 0
fi
[[ "$found" -eq 0 ]] && log "80/443 端口当前无占用。"
}

kill_ports_aggressive() {
warn "将停止常见 Web 服务并清理 80/443 占用..."
systemctl stop nginx apache2 httpd caddy 2>/dev/null || true
systemctl disable nginx apache2 httpd 2>/dev/null || true

if has_cmd fuser; then
fuser -k 80/tcp 2>/dev/null || true
fuser -k 443/tcp 2>/dev/null || true
fi

pkill -9 nginx 2>/dev/null || true
pkill -9 apache2 2>/dev/null || true
pkill -9 httpd 2>/dev/null || true
log "端口清理完成。"
}

normalize_upstream() {
local u="$1"
if [[ "$u" =~ ^https?:// ]]; then
echo "$u"
else
echo "http://$u"
fi
}

extract_hostport_from_url() {
local u="$1"
u="${u#http://}"
u="${u#https://}"
u="${u%%/*}"
echo "$u"
}

extract_host_only() {
local hp="$1"
if [[ "$hp" =~ ^\[(.*)\](:[0-9]+)?$ ]]; then
echo "${BASH_REMATCH[1]}"
return
fi
echo "${hp%%:*}"
}

validate_domain() {
local d="$1"
# 允许多级域名/子域名；不允许空格、协议前缀、通配符等明显错误输入
if [[ "$d" =~ ^https?:// ]]; then
err "域名不应包含协议前缀 (http:// 或 https://)"
return 1
fi
if [[ "$d" =~ [[:space:]] ]]; then
err "域名不能包含空格"
return 1
fi
if ! [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
err "域名格式看起来不正确：${d}"
return 1
fi
return 0
}

validate_caddyfile() {
local file="$1"
caddy fmt --overwrite "$file" >/dev/null 2>&1 || true
caddy validate --config "$file" --adapter caddyfile
}

reload_caddy() {
if systemctl is-active --quiet caddy; then
systemctl reload caddy || systemctl restart caddy
else
systemctl restart caddy
fi
}

remove_managed_block() {
local domain="$1"
local in_file="$2"
local out_file="$3"

awk -v d="$domain" '
BEGIN{
begin="# BEGIN MANAGED: " d
end="# END MANAGED: " d
skip=0
}
{
if ($0 == begin) { skip=1; next }
if ($0 == end) { skip=0; next }
if (!skip) print
}
' "$in_file" > "$out_file"
}

site_block() {
local domain="$1"
local upstream="$2"
local privacy_mode="$3" # strict|compat
local insecure_skip="$4" # yes|no
local log_json="$5" # yes|no

local hp host
hp="$(extract_hostport_from_url "$upstream")"
host="$(extract_host_only "$hp")"

cat <<EOF
# BEGIN MANAGED: ${domain}
${domain} {
	# Emby/大视频不要全局压缩
	# encode zstd gzip

	@static_cache path /Items/*/Images/* /Users/*/Images/* /web/*.js /web/*.css /web/*.woff2 *.png *.jpg *.jpeg *.webp *.ico *.svg *.woff2
	header @static_cache Cache-Control "public, max-age=2592000, immutable"

	@media_stream path /Videos/* /emby/Videos/* /Audio/* /emby/Audio/* /Items/*/Download* /Sessions/Playing* /Playback/*
	header @media_stream Cache-Control "no-store"
	header @media_stream X-Accel-Buffering "no"

	header {
		-Server
		-X-Powered-By
		-X-Emby-Version
		Referrer-Policy "no-referrer"
		X-Content-Type-Options "nosniff"
	}

	reverse_proxy ${upstream} {
		# 通用最优：不写 flush_interval，交给 Caddy 默认处理
        flush_interval -1
		transport http {
			dial_timeout 10s
			response_header_timeout 120s
			read_timeout 0
			write_timeout 0
			keepalive 60s
			keepalive_idle_conns 256
			keepalive_idle_conns_per_host 64
			read_buffer 32768
			write_buffer 32768
EOF

if [[ "$upstream" =~ ^https:// ]]; then
cat <<EOF
			tls_server_name ${host}
EOF
	if [[ "$insecure_skip" == "yes" ]]; then
cat <<EOF
			tls_insecure_skip_verify
EOF
	fi
fi

cat <<EOF
		}

		header_up Host ${host}

		# 保留拖动/分段播放必需头
		header_up Range {http.request.header.Range}
		header_up If-Range {http.request.header.If-Range}
EOF

if [[ "$privacy_mode" == "strict" ]]; then
cat <<'EOF'

		# 严格隐私：不暴露真实来源
		header_up -X-Forwarded-For
		header_up -X-Real-IP
		header_up -Forwarded
		header_up -CF-Connecting-IP
		header_up -True-Client-IP
		header_up -X-Client-IP
EOF
else
cat <<'EOF'

		# 兼容模式：隐藏真实 IP，但保留协议/Host 语义
		header_up -X-Forwarded-For
		header_up -X-Real-IP
		header_up X-Forwarded-Proto https
		header_up X-Forwarded-Host {host}
EOF
fi

cat <<EOF

		header_down -Server
		header_down -X-Powered-By
		header_down -X-Emby-Version
	}
EOF

if [[ "$log_json" == "yes" ]]; then
cat <<EOF

	log {
		output file ${LOG_DIR}/${domain}.access.log {
			roll_size 50MiB
			roll_keep 10
			roll_keep_for 720h
		}
		format json
	}
EOF
fi

cat <<EOF
}
# END MANAGED: ${domain}
EOF
}

add_or_update_site() {
ensure_caddyfile_minimal

echo "--------------------------------------------"
echo -e "${CYAN}添加/更新 Emby 反代站点${PLAIN}"
echo "--------------------------------------------"

local domain
read -r -p "请输入域名 (如 emby.example.com): " domain < /dev/tty
[[ -z "${domain:-}" ]] && { err "域名不能为空"; return 1; }
validate_domain "$domain" || return 1

local upstream
read -r -p "请输入上游地址 (如 https://upstream.example.com:443 或 127.0.0.1:8096): " upstream < /dev/tty
[[ -z "${upstream:-}" ]] && upstream="127.0.0.1:8096"
upstream="$(normalize_upstream "$upstream")"

echo
echo "隐私模式："
echo " 1) strict（默认，尽量不泄露来源）"
echo " 2) compat（兼容优先，保留 scheme/host）"
local m
read -r -p "请选择 [1-2] (默认1): " m < /dev/tty
local privacy_mode="strict"
[[ "${m:-1}" == "2" ]] && privacy_mode="compat"

local insecure_skip="no"
if [[ "$upstream" =~ ^https:// ]]; then
local sk
read -r -p "上游 HTTPS 证书不可控，是否跳过校验? [y/N，风险较高]: " sk < /dev/tty
[[ "${sk:-N}" =~ ^[Yy]$ ]] && insecure_skip="yes"
fi

local l
read -r -p "是否开启该站点访问日志(JSON)? [Y/n]: " l < /dev/tty
local log_json="yes"
[[ "${l:-Y}" =~ ^[Nn]$ ]] && log_json="no"

backup_caddyfile
local tmp tmp2
tmp="$(mktemp_track)"
cp -a "$CADDYFILE" "$tmp"

tmp2="$(mktemp_track)"
remove_managed_block "$domain" "$tmp" "$tmp2"
cp -f "$tmp2" "$tmp"

site_block "$domain" "$upstream" "$privacy_mode" "$insecure_skip" "$log_json" >> "$tmp"

if validate_caddyfile "$tmp"; then
cp -af "$tmp" "$CADDYFILE"
chown root:root "$CADDYFILE"
chmod 644 "$CADDYFILE"
reload_caddy
log "站点 ${domain} 已写入并生效。"
else
err "配置校验失败，未应用。"
return 1
fi
}

list_managed_sites() {
if [[ ! -f "$CADDYFILE" ]]; then
warn "未找到 Caddyfile"
return
fi

local list
list="$(grep -E '^# BEGIN MANAGED: ' "$CADDYFILE" | sed 's/^# BEGIN MANAGED: //' || true)"

if [[ -z "${list:-}" ]]; then
warn "未找到受管站点"
return
fi

echo -e "${CYAN}当前受管站点：${PLAIN}"
echo "$list" | nl -w2 -s'. '
}

delete_site() {
if [[ ! -f "$CADDYFILE" ]]; then
err "未找到 $CADDYFILE"
return
fi

list_managed_sites
echo
local domain
read -r -p "请输入要删除的域名（精确）: " domain < /dev/tty
[[ -z "${domain:-}" ]] && return

if ! grep -Fq "# BEGIN MANAGED: ${domain}" "$CADDYFILE"; then
err "未找到受管域名：${domain}"
return 1
fi

backup_caddyfile
local tmp
tmp="$(mktemp_track)"
remove_managed_block "$domain" "$CADDYFILE" "$tmp"
if validate_caddyfile "$tmp"; then
cp -af "$tmp" "$CADDYFILE"
chown root:root "$CADDYFILE"
chmod 644 "$CADDYFILE"
reload_caddy
log "域名 ${domain} 已删除并生效。"
else
err "删除后配置校验失败，未应用。"
return 1
fi
}

show_caddyfile() {
if [[ -f "$CADDYFILE" ]]; then
sed -n '1,260p' "$CADDYFILE"
else
warn "未找到 $CADDYFILE"
fi
}

show_logs() {
local domain
read -r -p "输入域名查看访问日志（留空看系统日志）: " domain < /dev/tty
if [[ -n "${domain:-}" && -f "${LOG_DIR}/${domain}.access.log" ]]; then
tail -n 100 "${LOG_DIR}/${domain}.access.log"
else
journalctl -u caddy -n 100 --no-pager || true
fi
}

uninstall_caddy() {
local x
read -r -p "确认卸载 Caddy? [y/N]: " x < /dev/tty
[[ "${x:-N}" =~ ^[Yy]$ ]] || return

local pm
pm="$(detect_pm)"
systemctl stop caddy 2>/dev/null || true

case "$pm" in
apt) apt remove -y caddy ;;
dnf) dnf remove -y caddy ;;
yum) yum remove -y caddy ;;
*) warn "未知包管理器，请手动卸载" ;;
esac

warn "是否删除 /etc/caddy ?（配置将丢失）"
local y
read -r -p "[y/N]: " y < /dev/tty
if [[ "${y:-N}" =~ ^[Yy]$ ]]; then
rm -rf /etc/caddy
log "/etc/caddy 已删除。"
fi
}

restart_caddy() {
if ! has_cmd caddy; then
err "caddy 未安装"
return 1
fi

ensure_caddyfile_minimal

if [[ -f "$CADDYFILE" ]] && ! validate_caddyfile "$CADDYFILE"; then
err "当前配置校验失败，拒绝重启。"
return 1
fi

reload_caddy
sleep 1

if systemctl is-active --quiet caddy; then
log "Caddy 运行正常。"
else
err "Caddy 未正常运行，请检查：systemctl status caddy -l"
fi
}

menu() {
clear
echo "############################################################"
echo "# Caddy + Emby 多站点反代管理（V6.1 Final Stable+） #"
echo "############################################################"
echo " 1) 安装基础环境 & Caddy"
echo " 2) 添加/更新 反代站点（受管）"
echo " 3) 删除反代站点（受管）"
echo " 4) 列出受管站点"
echo " 5) 查看 Caddyfile"
echo " 6) 查看日志（站点/服务）"
echo " ----------------------------------------------------------"
echo " 7) 停止 Caddy"
echo " 8) 重启/重载 Caddy（含配置校验）"
echo " 9) 检查 80/443 端口占用"
echo "10) 强制清理 80/443 占用（危险）"
echo "11) 卸载 Caddy"
echo " 0) 退出"
echo "------------------------------------------------------------"
local n
read -r -p "请选择 [0-11]: " n < /dev/tty

case "$n" in
1) install_caddy ;;
2) install_caddy; add_or_update_site ;;
3) delete_site ;;
4) list_managed_sites ;;
5) show_caddyfile ;;
6) show_logs ;;
7) systemctl stop caddy 2>/dev/null || true; log "Caddy 已停止" ;;
8) restart_caddy ;;
9) check_ports ;;
10) kill_ports_aggressive ;;
11) uninstall_caddy ;;
0) exit 0 ;;
*) err "请输入正确选项" ;;
esac
pause
}

while true; do
menu
done

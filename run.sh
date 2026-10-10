#!/bin/bash
# =================================================================
# /H/aisrc/IRC/run.sh — Live ISO Reset 后 IRC 一键启动（零 apt install）
# =================================================================
# 彻底遵循 weston 无安装范式：
#   - UnrealIRCd:  源码编译到 /H，硬编码全路径指向 /H（天然零安装）
#   - nginx:       从 .deb 解压 binary + mime.types 到 /H/aisrc/IRC/nginx-rootfs/
#                  所有运行时 .so 在 squashfs 底层（reset 不丢）
#                  所有 temp_path / log / pid 硬编码到 /H（reset 不丢）
#
#   运行时零 apt install:
#     ✗ 不需要 apt-get install nginx-extras
#     ✗ 不需要 apt-get install nginx-common
#     ✗ 不需要 /etc/nginx/ 下的任何文件
#     ✗ 不需要 /var/lib/nginx/ 下的任何目录
#
# 用法:
#   bash /H/aisrc/IRC/run.sh          # 启动
#   bash /H/aisrc/IRC/run.sh stop     # 停止
#   bash /H/aisrc/IRC/run.sh status   # 状态
# =================================================================
set -e

BASE="/H/aisrc/IRC"
LOG="/H/usr/aisrc/log"
mkdir -p "$LOG"

NGINX="$BASE/nginx-rootfs/bin/nginx"
log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "✗ $*" >&2; exit 1; }

# ========== stop ==========
if [ "${1:-}" = "stop" ]; then
    log "停止服务..."
    "$BASE/unrealircd/unrealircd" stop 2>/dev/null || true
    # 用 -s quit 优雅停止；找不到 pidfile 时 pkill fallback
    if [ -f "$BASE/tmp/nginx_logs/nginx.pid" ]; then
        sudo "$NGINX" -c "$BASE/conf/nginx.conf" -s quit 2>/dev/null || true
    else
        sudo pkill -x nginx 2>/dev/null || true
    fi
    log "已停止"
    exit 0
fi

# ========== status ==========
if [ "${1:-}" = "status" ]; then
    echo "UnrealIRCd: $(pgrep -f 'unrealircd/bin/unrealircd' >/dev/null 2>&1 && echo '✅ 运行中' || echo '❌ 未运行')"
    echo "nginx:      $(pgrep -x nginx >/dev/null 2>&1 && echo '✅ 运行中' || echo '❌ 未运行')"
    ss -tlnp 2>/dev/null | grep -E ':80 |:8067|:8697' || netstat -tlnp 2>/dev/null | grep -E ':80 |:8067|:8697' || true
    exit 0
fi

# ========== start ==========
echo "=============================================="
echo "  IRC 一键启动 — 零 apt install (weston 范式)"
echo "=============================================="

# --- 1. 检查 /bin 可用性（仅检查，不 bind mount！） ---
# 之前用 mount --bind /tmp/binwrapper /bin 修 /bin 导致系统彻底崩溃：
#   /bin/bash → symlink → /usr/bin/bash 形成循环 → spawn 任何进程都报
#   "Too many levels of symbolic links"，连 sudo/umount 都跑不起来
# Live ISO reset 后 /bin 从 squashfs lowerdir 挂载，本身就是好的，不需要修
# 如果 /bin/bash 真坏了，那是 squashfs 镜像本身的问题，应该重烧 ISO
if [ -x /bin/bash ] && /bin/bash -c 'true' 2>/dev/null; then
    log "/bin/bash 正常 ✓"
else
    err "/bin/bash 坏了！手动检查: ls -la /bin/bash /usr/bin/bash"
fi

# --- 2. 验证 nginx binary 在 /H ---
if [ ! -f "$NGINX" ]; then
    err "nginx binary 不存在: $NGINX"
fi
# 验证运行时 .so 全在 squashfs（ldd 输出里没有 "not found"）
LDD_MISSING=$(sudo ldd "$NGINX" 2>&1 | grep "not found" || true)
if [ -n "$LDD_MISSING" ]; then
    log "⚠️  nginx 有运行时 .so 缺失: $(echo "$LDD_MISSING" | tr '\n' ' ')"
    log "尝试 apt 重装 (fallback)..."
    sudo apt-get update -o Acquire::http::Timeout=30 2>&1 | tail -2
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx-extras 2>&1 | tail -3
    # 重装后把 binary + .deb 缓存都镜像到 /H（下次零 apt）
    mkdir -p "$BASE/nginx-rootfs/bin" "$BASE/nginx-rootfs/etc"
    cp /usr/sbin/nginx "$BASE/nginx-rootfs/bin/" 2>/dev/null || true
    cp /etc/nginx/mime.types "$BASE/nginx-rootfs/etc/" 2>/dev/null || true
    mkdir -p /H/usr/aisrc/apt/nginx
    cp /var/cache/apt/archives/*nginx*.deb /H/usr/aisrc/apt/nginx/ 2>/dev/null || true
    # 重验一次
    LDD_MISSING=$(sudo ldd "$NGINX" 2>&1 | grep "not found" || true)
    [ -n "$LDD_MISSING" ] && err "nginx .so 仍缺失，无法启动"
fi
log "nginx binary $NGINX ✓"

# --- 3. 确保 nginx 所有临时目录存在（reset 后 overlay 丢失！） ---
# nginx 默认需要 /var/lib/nginx/{proxy,fastcgi,uwsgi,scgi,body} 和 /var/log/nginx/
# 这些路径在 nginx.conf 里已全部重定向到 /H/aisrc/IRC/tmp/
# reset 后 /H 不丢，但目录权限可能被影响
for _d in body proxy fastcgi uwsgi scgi logs; do
    sudo mkdir -p "$BASE/tmp/nginx_$_d"
    sudo chown www-data:www-data "$BASE/tmp/nginx_$_d" 2>/dev/null || true
    sudo chmod 700 "$BASE/tmp/nginx_$_d" 2>/dev/null || true
done
log "nginx temp 目录 (body/proxy/fastcgi/uwsgi/scgi/logs) ✓"

# --- 4. 确保 uploads 目录存在 ---
sudo mkdir -p "$BASE/uploads"
sudo chown www-data:www-data "$BASE/uploads" 2>/dev/null || true
sudo chmod 775 "$BASE/uploads" 2>/dev/null || true
log "uploads $BASE/uploads ✓"

# --- 5. UnrealIRCd (二进制在 /H，天然零安装) ---
if [ ! -f "$BASE/unrealircd/bin/unrealircd" ]; then
    err "UnrealIRCd 二进制不存在！请先手动编译一次。"
fi
log "UnrealIRCd configtest..."
"$BASE/unrealircd/unrealircd" configtest 2>&1 | tee -a "$LOG/run.log" | grep -E "passed|error|failed" || true

# --- 6. nginx configtest 前置（防止启动后秒退） ---
log "nginx configtest..."
sudo "$NGINX" -c "$BASE/conf/nginx.conf" -t 2>&1 | tee -a "$LOG/run.log"
# 非零退出直接 abort
sudo "$NGINX" -c "$BASE/conf/nginx.conf" -t >/dev/null 2>&1 || err "nginx configtest 失败，检查 $BASE/conf/nginx.conf"
log "nginx configtest ✓"

# --- 7. 停旧进程 ---
log "停旧进程..."
"$BASE/unrealircd/unrealircd" stop 2>/dev/null || true
if [ -f "$BASE/tmp/nginx_logs/nginx.pid" ]; then
    sudo "$NGINX" -c "$BASE/conf/nginx.conf" -s quit 2>/dev/null || true
else
    sudo pkill -x nginx 2>/dev/null || true
fi
sleep 1

# --- 8. 启动 UnrealIRCd ---
log "启动 UnrealIRCd..."
"$BASE/unrealircd/unrealircd" start 2>&1 | tee -a "$LOG/run.log" | grep -E "listening|started|error" || true
sleep 1
pgrep -f "unrealircd/bin/unrealircd" > /dev/null || err "UnrealIRCd 没起来！"
log "UnrealIRCd ✓"

# --- 9. 启动 nginx ---
log "启动 nginx..."
sudo "$NGINX" -c "$BASE/conf/nginx.conf" 2>&1 | tee -a "$LOG/run.log" || true
sleep 1
pgrep -x nginx > /dev/null || err "nginx 没起来！检查 $BASE/tmp/nginx_logs/error.log"
log "nginx ✓"

# --- 10. 验证 ---
log "端口监听:"
ss -tlnp 2>/dev/null | grep -E ':80 |:8067|:8697' || netstat -tlnp 2>/dev/null | grep -E ':80 |:8067|:8697' || true
echo
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
log "HTTP:   $(curl -s -o /dev/null -w 'http_code=%{http_code}' http://127.0.0.1/)"
log "WS 代理: $(curl -s -o /dev/null -w 'HTTP %{http_code}' http://127.0.0.1/ws \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')"
log "DAV PUT: $(echo probe | curl -s -o /dev/null -w 'HTTP %{http_code}' -T - http://127.0.0.1/uploads/_probe)"
curl -s -X DELETE http://127.0.0.1/uploads/_probe > /dev/null 2>&1 || true

echo
echo "=============================================="
echo "  ✅ 就绪！浏览器打开: http://$IP/"
echo "  停止:  bash $0 stop"
echo "  状态:  bash $0 status"
echo "  零 apt install ✓"
echo "=============================================="

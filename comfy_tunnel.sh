#!/usr/bin/env bash
# ComfyUI 公网入口：Basic Auth 反向代理 + frpc (HINAS frps)
# 用法: bash comfy_tunnel.sh {start|stop|status|url|restart}
# frps: vnts2.770710712.xyz:7000, allowPorts 10000-20000, 远程端口 18188 (固定)
set -u

ROOT=/mnt/workspace
PY=$ROOT/h3-ascend/.venv/bin/python3
AUTH=$ROOT/comfy_tunnel_auth.py
FRPC=$ROOT/bin/frp071/frpc
FRPC_CFG=$ROOT/frpc.toml
FRPC_LOG=$ROOT/logs/frpc.log
PASS_FILE=$ROOT/.comfy_web_pass
TOKEN_FILE=$ROOT/.frps_token
USER_NAME=${COMFY_WEB_USER:-comfy}
URL_FILE=$ROOT/COMFY_URL.txt
PUBLIC_URL=http://vnts2.770710712.xyz:18188
LOG=$ROOT/logs
AUTH_PID_FILE=$ROOT/.comfy_auth.pid
FRPC_PID_FILE=$ROOT/.comfy_frpc.pid
mkdir -p "$LOG"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

kill_by_pattern() {
  ps -eo pid,args 2>/dev/null | awk -v pat="$1" \
    '$0 ~ pat && $0 !~ /awk/ && $0 !~ /comfy_tunnel.sh/ {print $1}' \
    | while read -r p; do kill "$p" 2>/dev/null || true; done
}

gen_pass() {
  if [ ! -s "$PASS_FILE" ]; then
    "$PY" -c 'import secrets; print(secrets.token_urlsafe(12))' > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
  fi
}

ensure_frpc() {
  if [ ! -x "$FRPC" ]; then
    echo "  frpc 不存在，下载 v0.71.0 (arm64)..."
    mkdir -p "$(dirname "$FRPC")"
    curl -fL --max-time 200 -o "$ROOT/frp071.tar.gz" \
      https://github.com/fatedier/frp/releases/download/v0.71.0/frp_0.71.0_linux_arm64.tar.gz \
      || { echo "  下载失败"; exit 1; }
    tar -xzf "$ROOT/frp071.tar.gz" -C "$(dirname "$FRPC")" \
      --strip-components=1 frp_0.71.0_linux_arm64/frpc
    chmod +x "$FRPC"
  fi
  if [ ! -s "$FRPC_CFG" ] || ! grep -q '^auth.token = ".\{4,\}"' "$FRPC_CFG"; then
    if [ ! -s "$TOKEN_FILE" ]; then
      echo "  缺少 frps token ($TOKEN_FILE)，无法生成配置"; exit 1
    fi
    "$PY" - <<'PY'
t = open("/mnt/workspace/.frps_token").read().strip()
cfg = """serverAddr = "vnts2.770710712.xyz"
serverPort = 7000
auth.method = "token"
auth.token = "%s"
loginFailExit = false
log.level = "info"

[[proxies]]
name = "cannlab-comfyui"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8189
remotePort = 18188
""" % t
open("/mnt/workspace/frpc.toml", "w").write(cfg)
PY
    echo "  已生成 frpc.toml"
  fi
}

start() {
  echo "[1/4] 检查 ComfyUI (127.0.0.1:8188)"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:8188/system_stats)
  if [ "$code" != "200" ]; then
    echo "  ComfyUI 未运行，请先执行: cd /mnt/workspace && bash deploy-h3-cannlab.sh start"
    exit 1
  fi

  gen_pass
  PASS=$(cat "$PASS_FILE")

  echo "[2/4] 启动认证代理 (127.0.0.1:8189)"
  if ! alive "$AUTH_PID_FILE"; then
    COMFY_WEB_USER="$USER_NAME" COMFY_WEB_PASS="$PASS" \
      nohup "$PY" "$AUTH" > "$LOG/comfy_auth.log" 2>&1 &
    echo $! > "$AUTH_PID_FILE"
  fi
  c=""
  for _ in $(seq 1 20); do
    c=$(curl -s -o /dev/null -w '%{http_code}' -m 2 \
        -u "$USER_NAME:$PASS" http://127.0.0.1:8189/system_stats)
    [ "$c" = "200" ] && break
    sleep 1
  done
  if [ "$c" != "200" ]; then
    echo "  认证代理启动失败，日志: $LOG/comfy_auth.log"; tail -12 "$LOG/comfy_auth.log"
    exit 1
  fi

  echo "[3/4] 启动 frpc -> HINAS frps:7000 (远程端口 18188)"
  ensure_frpc
  if ! alive "$FRPC_PID_FILE"; then
    : > "$FRPC_LOG"
    nohup "$FRPC" -c "$FRPC_CFG" > "$FRPC_LOG" 2>&1 &
    echo $! > "$FRPC_PID_FILE"
  fi
  ok=0
  for _ in $(seq 1 30); do
    grep -q 'start proxy success' "$FRPC_LOG" 2>/dev/null && { ok=1; break; }
    sleep 1
  done
  if [ "$ok" != "1" ]; then
    echo "  frpc 未就绪，日志: $FRPC_LOG"; tail -12 "$FRPC_LOG"
    exit 1
  fi
  echo "$PUBLIC_URL" > "$URL_FILE"

  echo "[4/4] 完成"
  echo "  访问地址: $PUBLIC_URL  (固定，不会随重启变化)"
  echo "  用户名:   $USER_NAME"
  echo "  密码:     $PASS"
  echo "  ⚠️ 浏览器需直连该域名；若本机开了 HTTP 代理，请把 vnts2.770710712.xyz 加入直连/白名单，"
  echo "     否则 ComfyUI 前端的 WebSocket 握手会失败 (400 No WebSocket UPGRADE hdr)。"
}

stop() {
  alive "$FRPC_PID_FILE" && kill "$(cat "$FRPC_PID_FILE")" 2>/dev/null || true
  alive "$AUTH_PID_FILE" && kill "$(cat "$AUTH_PID_FILE")" 2>/dev/null || true
  kill_by_pattern 'frpc -c'
  rm -f "$FRPC_PID_FILE" "$AUTH_PID_FILE"
  echo "frpc 与认证代理已停止（ComfyUI 本身不受影响）"
}

status() {
  echo "ComfyUI 8188 : $(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:8188/system_stats)"
  echo "认证代理 8189: $(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:8189/system_stats) (401=正常，需认证)"
  echo "frpc         : $(alive "$FRPC_PID_FILE" && echo 运行中 || echo 未运行)"
  echo "认证代理     : $(alive "$AUTH_PID_FILE" && echo 运行中 || echo 未运行)"
  echo "公网地址     : $PUBLIC_URL (固定)"
  echo "用户名/密码  : $USER_NAME / $(cat "$PASS_FILE" 2>/dev/null || echo '-')"
  echo "cloudflared  : $(ps -eo args 2>/dev/null | grep -c '[c]loudflared tunnel') 个进程"
}

case "${1:-start}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep 2; start ;;
  status)  status ;;
  url)     echo "$PUBLIC_URL" ;;
  *) echo "用法: bash $0 {start|stop|status|url|restart}"; exit 1 ;;
esac

#!/usr/bin/env bash
# CANNLab 开机自启：拉起 ComfyUI + 带认证的公网隧道
# 幂等，可重复执行；同一时刻只允许一个实例（锁目录 + 存活 pid 检查）。
# 由 /home/developer/.bash_profile 在开机登录 shell 时投递，也可手动执行。
set -u

ROOT=/mnt/workspace
LOG=$ROOT/logs/auto_start.log
LOCKDIR=$ROOT/.auto_start.lock.d
mkdir -p "$ROOT/logs"

ts() { date '+%F %T'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

# ---- 并发/重复触发保护 ----
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    log "已有实例 pid=$oldpid 在运行，跳过"
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM

log "=== 开机自启开始 (pid $$, user $(id -un)) ==="

# ---- 等待持久卷挂载 ----
ready=0
for _ in $(seq 1 30); do
  if [ -f "$ROOT/deploy-h3-cannlab.sh" ] && [ -f "$ROOT/comfy_tunnel.sh" ]; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" != "1" ]; then
  log "工作区脚本未就绪（/mnt/workspace 可能尚未挂载），放弃本次"
  exit 1
fi

# ---- 1) ComfyUI ----
code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:8188/system_stats)
if [ "$code" = "200" ]; then
  log "ComfyUI 已在运行 (8188=200)，跳过"
else
  log "ComfyUI 未运行，执行 deploy-h3-cannlab.sh start"
  bash /mnt/workspace/deploy-h3-cannlab.sh start >> /mnt/workspace/logs/auto_start.log 2>&1
  for _ in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:8188/system_stats)
    [ "$code" = "200" ] && break
    sleep 3
  done
  if [ "$code" = "200" ]; then
    log "ComfyUI 就绪 (8188=200)"
  else
    log "ComfyUI 启动失败 (8188=$code)，详见本日志；跳过隧道"
  fi
fi

# ---- 2) 公网隧道 ----
if [ "$code" = "200" ]; then
  log "执行 comfy_tunnel.sh start"
  if bash /mnt/workspace/comfy_tunnel.sh start >> /mnt/workspace/logs/auto_start.log 2>&1; then
    log "隧道启动完成"
  else
    log "隧道启动失败（详见本日志）"
  fi
  url=$(cat "$ROOT/COMFY_URL.txt" 2>/dev/null || echo "-")
  user=${COMFY_WEB_USER:-comfy}
  pass=$(cat "$ROOT/.comfy_web_pass" 2>/dev/null || echo "-")
  {
    echo "更新时间: $(ts)"
    echo "访问地址: $url"
    echo "用户名:   $user"
    echo "密码:     $pass"
    echo ""
    echo "查看状态: bash /mnt/workspace/comfy_tunnel.sh status"
    echo "查看网址: bash /mnt/workspace/comfy_tunnel.sh url"
    echo "关闭入口: bash /mnt/workspace/comfy_tunnel.sh stop"
    echo "自启日志: /mnt/workspace/logs/auto_start.log"
  } > "$ROOT/COMFY_ACCESS.txt"
  log "访问信息已写入 COMFY_ACCESS.txt"
fi

log "=== 开机自启结束 ==="

#!/usr/bin/env bash
# =============================================================================
# MiniMax H3 (视频 + 原生音频) on Ascend 910C / CANNLab A3
# 基于 OwenLittleWhite/cannlab-h3-ascend 的分阶段部署脚本
#
# 适用环境（必须匹配，否则不要跑）:
#   CANNLab A3 实例，910C 暴露 2 个逻辑 NPU，CANN 9.0.0 镜像
#   Python 3.11.4 / torch 2.7.1+cpu / torch_npu 2.7.1.post4（平台镜像预装）
#   持久化卷 /mnt/workspace，空闲空间 >= 80GB
#
# 用法（在 CANNLab WebIDE 终端里）:
#   bash deploy-h3-cannlab.sh precheck   # 先跑这个，确认硬件/版本/磁盘/网络
#   bash deploy-h3-cannlab.sh all        # 一键跑完 code -> deps -> models -> config -> start
#   bash deploy-h3-cannlab.sh models     # 下载中断后单独续跑
#   bash deploy-h3-cannlab.sh fix        # 单独重做 sentencepiece 静态 TLS 修复
#   bash deploy-h3-cannlab.sh start      # 启动 ComfyUI + api-gateway
#   bash deploy-h3-cannlab.sh smoke      # 出第一个视频
#
# 说明:
#   - 每个阶段可重复执行，已完成的步骤会跳过；模型下载支持断点续传。
#   - 仓库只含源码与配置模板，不含权重、不含 aria2 二进制，本脚本负责补齐。
#   - 原项目 README 明确: 脚本针对测试过的 CANNLab 镜像，不是通用安装器；
#     且最后一次修正后未重跑端到端视频生成，smoke 失败需看日志排查。
#   - ✅ 已解决镜像差异 (2026-11-14 实测 CANNLab 20261106 镜像)：
#     venv 里 pip 装的 sentencepiece 0.2.3 wheel 自带 auditwheel bundled
#     libgomp-<hash>.so.1.0.0。torch_npu/CANN 大库加载后静态 TLS 已耗尽，
#     dlopen 该库报 "cannot allocate memory in static TLS block"，ComfyUI 启动即退出。
#     作者实跑镜像无此问题 (README 注明脚本非通用)。
#     解法（fix_sentencepiece_tls，幂等）：原地等长改写 _sentencepiece*.so 的
#     .dynstr，把 DT_NEEDED 从 bundled 名改成系统 libgomp.so.1；
#     .gnu.version_r 按偏移引用同一字符串会自动同步。
#     ⚠️ 切勿用 patchelf --remove-needed：它不会同步版本需求表，会导致
#     ld.so 断言 "_dl_check_map_versions: Assertion `needed != NULL' failed"。
#     也不要 LD_PRELOAD 两个 libgomp：静态 TLS 总量不够，两种顺序都失败。
#     另：作者验证版 deployment/scripts/start.sh 带 libsqlite3+libgomp 的 LD_PRELOAD
#     及 --cache-classic 等启动参数，模板版 start.sh 不可用，启动前需覆盖。
#   - CANNLab 单卡 NPU 持续空闲 30 分钟自动关机，长任务需保活；关机后数据保留，
#     各阶段已做幂等，重启环境后重跑 all 会自动续传。
# =============================================================================
set -euo pipefail

ROOT=/mnt/workspace/h3-ascend
COMFY="$ROOT/ComfyUI"
API="$ROOT/api-gateway"
REPO=https://github.com/OwenLittleWhite/cannlab-h3-ascend.git
UPSTREAM=https://gitcode.com/Ascend-SACT/MiniMax-H3-Comfy-NPU.git
COMFY_REPO=https://github.com/Comfy-Org/ComfyUI.git
# CANNLab 容器内实测(2026-11-14): GitHub 直连 Empty reply from server，
# gitclone.com 具体仓库 502、ghfast.top 403；仅以下两个镜像可用且含目标 commit。
COMFY_MIRRORS=(
  https://gitcode.com/gh_mirrors/co/ComfyUI.git
  https://gitee.com/mirrors/ComfyUI.git
)
COMFY_COMMIT=bd34f338ac505ea79e43968753968a464060e609
PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
# 权重下载源。若 hf-mirror 不通，可改用平台镜像后重跑 models 阶段，例如:
#   HF_BASE=https://ai.gitcode.com/hf_mirrors bash deploy-h3-cannlab.sh models
HF_BASE="${HF_BASE:-https://hf-mirror.com}"

STAGE="${1:-precheck}"
log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\n\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# GitHub 直连不通时走 gitclone.com 镜像
clone_repo() {
  local url="$1" dest="$2"
  if [ -d "$dest/.git" ]; then log "已存在，跳过: $dest"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  if git clone --depth 1 "$url" "$dest" 2>/dev/null; then return 0; fi
  log "直连失败，改用 gitclone.com 镜像: $url"
  git clone --depth 1 "https://gitclone.com/${url#https://}" "$dest"
}

precheck() {
  log "=== 1. NPU 设备 ==="
  npu-smi info || die "npu-smi 不可用，请确认创建的是 Ascend NPU 实例"
  log "=== 2. torch / torch_npu ==="
  python3 - <<'PY' || die "torch_npu 不可用或逻辑卡不足 2 张"
import torch, torch_npu
n = torch.npu.device_count()
print("torch", torch.__version__, "torch_npu", torch_npu.__version__, "NPU", n)
assert torch.npu.is_available() and n >= 2, "需要至少 2 个逻辑 NPU"
PY
  log "=== 3. 持久化磁盘 ==="
  df -h /mnt/workspace
  local free_gb
  free_gb=$(df -BG /mnt/workspace | awk 'NR==2{gsub("G","",$4);print $4}')
  [ "$free_gb" -ge 80 ] || die "/mnt/workspace 空闲 ${free_gb}GB，权重需 67.7GB + 余量，请先扩容到 >= 80GB"
  log "=== 4. CANN 环境 ==="
  if [ -f /home/developer/Ascend/cann-9.0.0/set_env.sh ]; then
    echo "找到 CANN 9.0.0 set_env.sh"
  else
    echo "未找到 /home/developer/Ascend/cann-9.0.0/set_env.sh，请确认选了 CANN 9.0 镜像"
    echo "当前 ASCEND_TOOLKIT_HOME=${ASCEND_TOOLKIT_HOME:-<未设置>}"
  fi
  log "=== 5. 网络 ==="
  for u in "$HF_BASE" "$PIP_INDEX" "${COMFY_MIRRORS[0]}" https://gitcode.com; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$u" || true)
    echo "$u -> ${code:-超时}"
  done
  log "预检完成。确认无误后执行: bash deploy-h3-cannlab.sh all"
}

code() {
  log "=== 拉取 cannlab-h3-ascend ==="
  mkdir -p /mnt/workspace
  clone_repo "$REPO" "$ROOT"
  cd "$ROOT"

  log "=== 拉取 ComfyUI 并锁定已验证 commit ==="
  # 必须完整 clone：blobless clone 在 checkout 时会按需回源(origin=GitHub)取 blob，
  # 而本环境 GitHub 不通，正是首次部署失败(fatal: Empty reply from server)的原因。
  # 镜像按可用性排序，逐个尝试，并校验其中确实含有补丁依赖的目标 commit。
  if [ ! -d "$COMFY/.git" ]; then
    for m in "${COMFY_MIRRORS[@]}"; do
      log "尝试镜像: $m"
      rm -rf "$COMFY"
      if git clone --no-checkout "$m" "$COMFY"; then
        if git -C "$COMFY" cat-file -t "$COMFY_COMMIT" >/dev/null 2>&1; then
          log "镜像可用且含目标 commit: $m"
          break
        fi
        log "该镜像缺少目标 commit，换下一个"
      fi
      rm -rf "$COMFY"
    done
  fi
  [ -d "$COMFY/.git" ] || die "所有 ComfyUI 镜像均失败，检查网络或手动指定 COMFY_MIRRORS"
  # 续跑时 HEAD 往往已是目标 commit 且工作区含补丁/overlay，不要重复 checkout 动工作区
  if [ "$(git -C "$COMFY" rev-parse HEAD 2>/dev/null)" != "$COMFY_COMMIT" ]; then
    git -C "$COMFY" checkout --detach "$COMFY_COMMIT"
  fi

  log "=== 应用 Ascend-SACT 基础补丁 (201KB) ==="
  local PATCH="$ROOT/patches/Ascend-SACT/comfy-ui-changes.patch"
  # 环境空闲 30 分钟会自动关机，all 可能被中断后多次重跑，补丁必须幂等
  if git -C "$COMFY" apply --reverse --check "$PATCH" 2>/dev/null; then
    log "补丁已应用，跳过"
  else
    git -C "$COMFY" apply --check "$PATCH" || \
      die "补丁预检失败，不要强行 apply；确认 ComfyUI commit 是否为 $COMFY_COMMIT"
    git -C "$COMFY" apply "$PATCH"
  fi

  log "=== 覆盖 comfyui-overlay 最终版文件 ==="
  cp -r "$ROOT/patches/comfyui-overlay/ComfyUI/." "$COMFY/"

  log "=== 安装 custom_nodes ==="
  mkdir -p "$COMFY/custom_nodes"
  cp -r "$ROOT/custom_nodes/." "$COMFY/custom_nodes/"

  log "=== 拉取上游工作流图 (prepare_workflows.py 依赖) ==="
  clone_repo "$UPSTREAM" "$ROOT/upstream/MiniMax-H3-Comfy-NPU"

  # 项目脚本用 ROOT=deployment/ 计算相对路径，需让 deployment/upstream 指向实际 clone 位置，
  # 否则 prepare_workflows.py 报找不到 additional_files/H-dreams/H2Videos_usage.log。
  mkdir -p "$ROOT/deployment/upstream"
  ln -sfn "$ROOT/upstream/MiniMax-H3-Comfy-NPU" "$ROOT/deployment/upstream/MiniMax-H3-Comfy-NPU"

  log "=== 补齐项目脚本期望的路径 ==="
  mkdir -p "$ROOT/scripts" "$ROOT/cache" "$ROOT/logs" "$ROOT/evidence" "$ROOT/workflows"
  cp -f "$ROOT"/deployment/scripts/* "$ROOT/scripts/"
  cp -f "$ROOT/docs/model-manifest.json" "$ROOT/model-manifest.json"
  chmod +x "$ROOT/scripts/"*.sh 2>/dev/null || true
  echo "代码与补丁就绪"
}

# CANNLab 20261106 镜像的静态 TLS 修复（幂等，可反复执行）
# 原理见文件头注释：等长改写 dynstr 中的 bundled libgomp 名 -> 系统 libgomp.so.1。
# 这样 torch_npu 已经加载的 libgomp 被复用，不再申请新的静态 TLS；
# 版本需求表 .gnu.version_r 通过偏移引用该字符串，因此自动保持一致。
fix_sentencepiece_tls() {
  local SO
  SO=$(ls "$ROOT"/.venv/lib/python3.11/site-packages/sentencepiece/_sentencepiece*.so 2>/dev/null | head -1)
  if [ -z "$SO" ]; then
    log "未找到 sentencepiece 扩展，跳过静态 TLS 修复"
    return 0
  fi
  "$ROOT/.venv/bin/python" - "$SO" <<'PY'
import re, sys
so = sys.argv[1]
d = open(so, 'rb').read()
m = re.search(rb'libgomp-[0-9a-f]{6,12}\.so\.1\.0\.0\x00', d)
if not m:
    print('TLS_FIX_ALREADY_OK (依赖已是系统 libgomp)')
    raise SystemExit(0)
old = m.group()
new = (b'libgomp.so.1\x00').ljust(len(old), b'\x00')
open(so + '.pre_tls_fix', 'wb').write(d)
open(so, 'wb').write(d.replace(old, new, 1))
print('TLS_FIX_APPLIED:', old.rstrip(b'\x00').decode(), '-> libgomp.so.1')
PY
  log "验证修复: torch + torch_npu + torchaudio + sentencepiece 导入"
  "$ROOT/.venv/bin/python" -c \
    'import torch, torch_npu, torchaudio, sentencepiece; print("IMPORT_CHAIN_OK")' \
    || die "静态 TLS 修复后导入链仍失败，检查 logs/comfyui.log"
}

deps() {
  cd "$ROOT" || die "先执行 code 阶段"
  log "=== 建 ComfyUI venv (继承平台预装 torch/torch_npu) ==="
  if [ ! -x "$ROOT/.venv/bin/python" ]; then
    python3 -m venv --system-site-packages "$ROOT/.venv"
  fi
  local PY="$ROOT/.venv/bin/python"
  "$PY" -m pip install -i "$PIP_INDEX" --upgrade pip

  # CANNLab 20261106 镜像自带 torchaudio 2.11，与平台 torch 2.7.1 ABI 不匹配，
  # 导入即报 libtorchaudio.abi3.so: undefined symbol: torch_library_impl。
  # 作者 constraints.txt 锁定 torchaudio==2.7.1；--no-deps 避免覆盖平台 torch/torch_npu。
  "$PY" -m pip install -i "$PIP_INDEX" --no-deps --force-reinstall 'torchaudio==2.7.1'

  log "=== ComfyUI 公共依赖 ==="
  "$PY" -m pip install -i "$PIP_INDEX" -r "$COMFY/requirements.txt"

  log "=== 锁定版推理依赖 (不覆盖平台 torch/torch_npu) ==="
  # constraints.txt 里 torch==2.7.1+cpu / torch-npu==2.7.1.post4 由镜像提供，
  # 强装会破坏 CANN 匹配，因此只安装其余固定版本的包。
  "$PY" -m pip install -i "$PIP_INDEX" \
    'comfy-kitchen==0.2.30' 'comfy-aimdo==0.4.13' \
    'transformers>=4.57.1,<5' 'av==16.1.0' 'numpy==1.26.4'

  log "=== custom_nodes 各自的 requirements ==="
  for req in "$COMFY"/custom_nodes/*/requirements.txt; do
    [ -f "$req" ] || continue
    "$PY" -m pip install -i "$PIP_INDEX" -r "$req" || echo "警告: $req 安装失败，检查日志"
  done

  log "=== api-gateway 独立 venv ==="
  bash "$API/scripts/install.sh"

  log "=== 修复 sentencepiece 静态 TLS 冲突 (20261106 镜像必需) ==="
  fix_sentencepiece_tls

  log "=== 运行时自检 (INT8 NPU 算子 + 编码器) ==="
  "$PY" "$ROOT/deployment/scripts/check_runtime.py" || die "运行时自检失败，先解决再继续"
}

models() {
  cd "$ROOT" || die "先执行 code 阶段"
  [ -f "$ROOT/model-manifest.json" ] || die "缺少 model-manifest.json，先跑 code 阶段"
  log "=== 准备下载器 ==="
  if ! command -v aria2c >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      (apt-get update -qq && apt-get install -y -qq aria2) || \
        (sudo apt-get update -qq && sudo apt-get install -y -qq aria2) || true
    fi
  fi
  command -v aria2c >/dev/null 2>&1 || die "aria2c 不可用，请手动安装 aria2 后重跑本阶段"

  log "=== 由 manifest 生成 aria2 输入 (hf-mirror + sha256) ==="
  python3 - <<'PY'
import json, pathlib, os
root = pathlib.Path('/mnt/workspace/h3-ascend')
base = os.environ.get('HF_BASE', 'https://hf-mirror.com').rstrip('/')
items = json.loads((root/'model-manifest.json').read_text())
lines = []
for f in items:
    dest = root/'ComfyUI/models'/f['destination']
    dest.parent.mkdir(parents=True, exist_ok=True)
    lines += [
        f"{base}/{f['repo']}/resolve/{f['revision']}/{f['path']}",
        f"  dir={dest.parent}", f"  out={dest.name}",
        f"  checksum=sha-256={f['sha256']}",
    ]
(root/'cache/models.aria2.txt').write_text('\n'.join(lines)+'\n')
total = sum(f['size'] for f in items)/1024**3
print(f"{len(items)} 个文件，合计 {total:.1f} GB")
PY

  log "=== 开始下载 (可中断，重跑本阶段会续传) ==="
  aria2c --input-file="$ROOT/cache/models.aria2.txt" \
    --continue=true --always-resume=true --auto-file-renaming=false \
    --check-integrity=true --file-allocation=none \
    --max-concurrent-downloads=2 --max-connection-per-server=12 \
    --split=12 --min-split-size=8M --max-tries=8 --retry-wait=3 \
    --connect-timeout=20 --timeout=90 --summary-interval=30 \
    --console-log-level=notice --enable-color=false

  log "=== 校验文件大小 ==="
  python3 - <<'PY'
import json, pathlib
root = pathlib.Path('/mnt/workspace/h3-ascend')
for f in json.loads((root/'model-manifest.json').read_text()):
    p = root/'ComfyUI/models'/f['destination']
    assert p.exists() and p.stat().st_size == f['size'], f"文件不完整: {p}"
    print("OK", f['destination'], f"{f['size']/1024**3:.2f} GB")
print("ALL_MODELS_VERIFIED")
PY
}

config() {
  cd "$ROOT" || die "先执行 code 阶段"
  log "=== 写入 api-gateway 配置 ==="
  python3 - <<'PY'
import json, pathlib, glob, re
root = pathlib.Path('/mnt/workspace/h3-ascend')
cfg = json.loads((root/'api-gateway/config/ascend.example.json').read_text())
devs = sorted(glob.glob('/dev/davinci[0-9]*'))
devs = [d for d in devs if not d.endswith('manager')]
if len(devs) < 2:
    # 910C 单 physical die 可能只暴露一个 /dev/davinciN，用 npu-smi 的 NPU id 兜底
    print('警告: 只发现', devs, '，按示例保留两个逻辑设备占位')
    devs = ['/dev/davinci0', '/dev/davinci1']
cfg['npu_device_paths'] = devs[:2]
# model-manifest 只提供 FL2VA DiT；示例里的 ref2va / text_model 字段需修正
cfg['model'] = 'minimax_h3_fl2va_int8_convrot.safetensors'
cfg['text_model'] = 'minimax_h3_fl2va_int8_convrot.safetensors'
cfg['clip'] = 'qwen3vl_32b_minimax_h3_int8_convrot.safetensors'
cfg['root'] = str(root)
(root/'api-gateway/config/ascend.json').write_text(json.dumps(cfg, indent=2, ensure_ascii=False)+'\n')
print('已写入 api-gateway/config/ascend.json, NPU:', cfg['npu_device_paths'])
PY

  log "=== 生成 smoke 工作流 ==="
  python3 "$ROOT/deployment/scripts/prepare_workflows.py" || \
    echo "警告: 工作流生成失败，可稍后手动从 ComfyUI 页面拖入 JSON"
  # prepare_workflows.py 把 JSON 写到 deployment/workflows/，而 smoke 读 ROOT/workflows/
  mkdir -p "$ROOT/workflows"
  cp -f "$ROOT"/deployment/workflows/*.json "$ROOT/workflows/" 2>/dev/null || true
  echo "配置就绪"
}

start() {
  cd "$ROOT" || die "先执行 code 阶段"
  # 环境关机重启后可能直接跑 start，这里再兜一次底（幂等）
  fix_sentencepiece_tls
  log "=== 启动 ComfyUI (127.0.0.1:8188) ==="
  python3 "$ROOT/deployment/scripts/launch.py"
  # api-gateway: 真实 API 在 8191，8190 只是反向代理（8190/health 恒为 404）。
  # 必须用 8191 探测，否则每次 start 都会误判「未启动」而重复拉起进程。
  log "=== 启动 api-gateway (API 127.0.0.1:8191 / 代理 8190) ==="
  if ! curl -fsS -m 2 http://127.0.0.1:8191/health >/dev/null 2>&1; then
    nohup bash "$API/scripts/start.sh" > "$ROOT/logs/api-gateway.log" 2>&1 &
    echo $! > "$ROOT/logs/api-gateway.pid"
  fi
  sleep 3
  curl -s -m 5 http://127.0.0.1:8188/system_stats | head -c 400 || true
  echo
  log "服务已启动。日志: $ROOT/logs/comfyui.log 与 $ROOT/logs/api-gateway.log"
  log "注意: 服务只监听 127.0.0.1，请通过 CANNLab 端口转发或 api-gateway 访问，勿直接暴露公网"
}

smoke() {
  cd "$ROOT" || die "先执行 code 阶段"
  local WF="$ROOT/workflows/h3_larry_v4_6step_2npu.api.json"
  [ -f "$WF" ] || die "缺少 $WF，先跑 config 阶段"
  log "=== 提交第一个视频任务 (736x416 / 124帧 / 6步) ==="
  python3 - <<'PY'
import json, time, urllib.request, pathlib
root = pathlib.Path('/mnt/workspace/h3-ascend')
wf = json.loads((root/'workflows/h3_larry_v4_6step_2npu.api.json').read_text())
base = 'http://127.0.0.1:8188'
def post(path, obj):
    req = urllib.request.Request(base+path, data=json.dumps(obj).encode(),
                                 headers={'Content-Type':'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())
r = post('/prompt', {'prompt': wf})
pid = r['prompt_id']; print('prompt_id =', pid)
for i in range(180):
    time.sleep(10)
    h = json.loads(urllib.request.urlopen(base+'/history/'+pid, timeout=30).read())
    if pid in h:
        out = h[pid].get('outputs', {})
        print('完成，输出节点:', json.dumps(out, ensure_ascii=False)[:800])
        break
    if i % 6 == 0: print('等待中...', i*10, '秒')
else:
    print('超时未完成，查看 logs/comfyui.log')
PY
  log "产物默认在 $COMFY/output/video/ 下"
}

case "$STAGE" in
  precheck) precheck ;;
  code)     code ;;
  deps)     deps ;;
  models)   models ;;
  config)   config ;;
  start)    start ;;
  smoke)    smoke ;;
  fix)      fix_sentencepiece_tls ;;
  all)      precheck; code; deps; models; config; start ;;
  *)        echo "用法: bash $0 {precheck|code|deps|models|config|fix|start|smoke|all}"; exit 1 ;;
esac

#!/usr/bin/env bash
# =============================================================================
# init_replicate.sh  ——  CANNLab A3 (1×NPU 910C) · MiniMax H3 + ComfyUI 一键复刻初始化
#
# 这个脚本给「另一个账号」用：在它自己的 CANNLab 环境（Web IDE 的 Terminal）里跑，
# 完成 环境自检 → 获取复刻套件 → 交给 deploy-h3-cannlab.sh 预检 + 部署。
#
# ───────────────────────── 前置（需在 CANNLab Web 控制台手动做）─────────────────────────
#   1. 新建环境：规格选「1×NPU 910C」（910B3 也可，H3 推理兼容）；CANN 选 9.0.0。
#   2. 打开该环境的 Web IDE（JupyterLab）→ Launcher → Terminal。
#   3. 把本脚本 + CANNLab_H3_Replication_Kit.zip 传进环境（拖拽上传到 /mnt/workspace，
#      或用下方「获取套件」里的 URL / git 方式自动拉取）。
#
# ─────────────────────────────── 运行方式 ──────────────────────────────
#   # 方式A：本地已上传套件 zip，直接跑
#   bash /mnt/workspace/init_replicate.sh
#
#   # 方式B：套件托管在直链，自动下载（把 URL 换成你自己的）
#   KIT_URL=https://你的域名/CANNLab_H3_Replication_Kit.zip \
#     bash <(curl -fsSL https://你的域名/init_replicate.sh)
#
#   # 方式C：套件在 git 仓库
#   KIT_REPO=https://gitcode.com/你的名/你的仓库.git \
#     bash <(curl -fsSL https://你的域名/init_replicate.sh)
#
#   # 预检通过后，带 --deploy 直接继续完整部署（权重很大，建议先只预检确认无误）
#   bash /mnt/workspace/init_replicate.sh --deploy
# =============================================================================
set -uo pipefail

# ───────────────────────────── 可配置项 ─────────────────────────────
WS="${WS:-/mnt/workspace}"                       # 持久卷挂载点
KIT_NAME="CANNLab_H3_Replication_Kit.zip"        # 套件包名
KIT_URL="${KIT_URL:-}"                           # 直链 zip；留空则尝试本地 / git
KIT_REPO="${KIT_REPO:-}"                         # git 仓库（KIT_URL 与本地都缺失时备用）
LOG="$WS/logs/init_replicate.log"
DO_DEPLOY=0
[ "${1:-}" = "--deploy" ] && DO_DEPLOY=1

# 套件内应存在的脚本清单（用于校验解包 & 拷贝到 $WS）
KIT_SCRIPTS=(deploy-h3-cannlab.sh gen_video.py gen_video.sh prompt.txt \
             comfy_tunnel_auth.py comfy_tunnel.sh setup_autostart.sh \
             auto_start.sh download_models.sh init_replicate.sh)

# ───────────────────────────── 工具函数 ─────────────────────────────
log(){ printf '\033[36m[%(%H:%M:%S)T]\033[0m %s\n' -1 "$*"; }
ok(){  printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
warn(){ printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[31m[FAIL]\033[0m %s\n' "$*"; }
die(){ err "$*"; echo "初始化中止。解决上面的问题后重跑本脚本即可。"; exit 1; }

mkdir -p "$WS/logs"
# 同时写日志文件 + 终端
exec > >(tee -a "$LOG") 2>&1

# ───────────────────────── 阶段 0：最基础环境 ─────────────────────────
log "========== 阶段0: 基础环境 =========="
if [ "$(id -u)" -ne 0 ] && [ "$(id -un)" != "developer" ]; then
  warn "当前用户为 $(id -un)，部分操作（写 /home/developer、挂开机自启）可能需要 root；"
  warn "若后续 setup_autostart.sh 失败，请先 sudo -i 再跑本脚本。"
fi

# 持久卷必须存在且可写
[ -d "$WS" ] || die "$WS 不存在 —— 你不在 CANNLab 持久卷环境里，请确认已打开正确环境的 Web IDE"
touch "$WS/.init_write_test" 2>/dev/null && rm -f "$WS/.init_write_test" \
  || die "$WS 不可写，请确认用的是带持久卷的环境（不是临时 Notebook）"

# 架构（H3 官方在 aarch64 / Ascend 上验证；x86 不支持 npu）
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ok "架构 $ARCH（昇腾 NPU 标准架构）" ;;
  *) warn "架构 $ARCH 不是 aarch64，Ascend NPU 可能不可用，继续但预检大概率失败" ;;
esac

# ───────────────────────── 阶段 1：硬件与运行时不强依赖的快检 ─────────────────────────
log "========== 阶段1: 硬件 / 运行时快检 =========="

# NPU 设备
if command -v npu-smi >/dev/null 2>&1; then
  if npu-smi info >/dev/null 2>&1; then
    ok "npu-smi 可用，NPU 设备在线"
  else
    warn "npu-smi 存在但 info 失败，可能驱动未就绪；预检会再校验"
  fi
else
  warn "未找到 npu-smi，请确认创建的是 Ascend NPU 实例（不是纯 CPU/GPU 环境）"
fi

# python3
command -v python3 >/dev/null 2>&1 || die "python3 不存在"
PYV="$(python3 -V 2>&1)"; ok "Python: $PYV"

# 磁盘空闲（权重 67.7GB + 文生图模型 ~26GB + 余量，建议 >= 110GB）
FREE_GB="$(df -BG "$WS" 2>/dev/null | awk 'NR==2{gsub("G","",$4);print $4+0}')"
[ -z "$FREE_GB" ] && FREE_GB=0
if [ "$FREE_GB" -ge 110 ]; then
  ok "/mnt/workspace 空闲 ${FREE_GB}GB（充足）"
elif [ "$FREE_GB" -ge 80 ]; then
  warn "/mnt/workspace 空闲 ${FREE_GB}GB：够跑 H3，但再加文生图模型会紧，注意清理"
else
  die "/mnt/workspace 空闲仅 ${FREE_GB}GB，H3 权重就要 67.7GB，请先扩容到 >= 110GB"
fi

# 下载工具
DL=""
for t in aria2c wget curl; do command -v "$t" >/dev/null 2>&1 && { DL="$t"; break; }; done
[ -n "$DL" ] && ok "下载工具: $DL" || die "aria2c/wget/curl 都缺失，无法获取套件"

# ───────────────────────── 阶段 2：获取复刻套件 ─────────────────────────
log "========== 阶段2: 获取复刻套件 =========="
SRC=""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 脚本所在目录（兼容 bash <(curl ...) 管道执行）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# 0. 脚本自身就在套件目录里（最常见的「git clone 后直接运行」场景）
ALL_THERE=1
for f in "${KIT_SCRIPTS[@]}"; do [ -f "$SCRIPT_DIR/$f" ] || { ALL_THERE=0; break; }; done
if [ "$ALL_THERE" -eq 1 ]; then
  ok "检测到脚本与套件同目录，直接使用本地文件（无需下载）: $SCRIPT_DIR"
  SRC="$SCRIPT_DIR"
# 2a. 本地已上传
elif [ -f "$WS/$KIT_NAME" ]; then
  ok "本地套件已存在: $WS/$KIT_NAME"
  unzip -oq "$WS/$KIT_NAME" -d "$TMP" && SRC="$TMP" || die "解包本地套件失败"
# 2b. 直链 zip
elif [ -n "$KIT_URL" ]; then
  ok "从直链下载套件: $KIT_URL"
  case "$DL" in
    aria2c) aria2c -c -x4 -s4 -o kit.zip "$KIT_URL" -d "$TMP" || die "aria2c 下载失败" ;;
    wget)   wget -c -O "$TMP/kit.zip" "$KIT_URL" || die "wget 下载失败" ;;
    curl)   curl -fSL -o "$TMP/kit.zip" "$KIT_URL" || die "curl 下载失败" ;;
  esac
  unzip -oq "$TMP/kit.zip" -d "$TMP" && SRC="$TMP" || die "解包下载的套件失败"
# 2c. git 仓库
elif [ -n "$KIT_REPO" ]; then
  ok "从 git 仓库克隆套件: $KIT_REPO"
  git clone --depth 1 "$KIT_REPO" "$TMP/repo" || die "git clone 失败"
  SRC="$TMP/repo"
# 2d. 都没有
else
  die "找不到套件。四选一：\n  1) 把 $KIT_NAME 拖拽上传到 $WS 再重跑；\n  2) 把套件仓库 git clone 到任意目录后，在该目录里 bash init_replicate.sh；\n  3) 设 KIT_URL=直链zip 重跑；\n  4) 设 KIT_REPO=git地址 重跑。"
fi

# 校验关键脚本都在
MISSING=()
for f in "${KIT_SCRIPTS[@]}"; do
  [ -f "$SRC/$f" ] || MISSING+=("$f")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  die "套件缺少关键文件: ${MISSING[*]}（可能下错了包或仓库结构不对）"
fi
ok "套件完整性校验通过（${#KIT_SCRIPTS[@]} 个脚本齐全）"

# 拷贝脚本到 $WS（已存在的用 -f 覆盖，保证复刻到最新版）
log "拷贝套件到 $WS ..."
for f in "${KIT_SCRIPTS[@]}"; do
  cp -f "$SRC/$f" "$WS/$f" || die "拷贝 $f 失败"
done
# 工作流目录（增量合并，不删旧）
if [ -d "$SRC/workflows_to_test" ]; then
  mkdir -p "$WS/workflows_to_test"
  cp -rf "$SRC/workflows_to_test/." "$WS/workflows_to_test/"
fi
chmod +x "$WS"/*.sh 2>/dev/null || true
ok "套件已就位：$WS/{deploy-h3-cannlab.sh, gen_video.*, comfy_tunnel.*, ...}"
ok "工作流已就位：$WS/workflows_to_test/{ready,official,community}/"

# ───────────────────────── 阶段 3：交给权威预检 ─────────────────────────
log "========== 阶段3: 运行 deploy-h3-cannlab.sh precheck =========="
cd "$WS" || die "无法进入 $WS"
if [ ! -x "$WS/deploy-h3-cannlab.sh" ]; then
  chmod +x "$WS/deploy-h3-cannlab.sh"
fi
bash "$WS/deploy-h3-cannlab.sh" precheck
PRECHECK_RC=$?
if [ "$PRECHECK_RC" -ne 0 ]; then
  die "precheck 未通过（退出码 $PRECHECK_RC）。按上面提示修复后，重跑 init_replicate.sh 即可。"
fi
ok "precheck 全部通过 ✅"

# ───────────────────────── 阶段 4：收尾 / 继续部署 ─────────────────────────
log "========== 阶段4: 收尾 =========="
if [ "$DO_DEPLOY" -eq 1 ]; then
  log "按 --deploy 继续完整部署（权重约 67.7GB，耗时较长，可能被 30 分钟空闲关机打断，可多次重跑）"
  bash "$WS/deploy-h3-cannlab.sh" all
  exit $?
else
  echo
  echo "────────────────────────────────────────────────────────────"
  ok "初始化完成。下一步（在 Terminal 里依次执行）："
  echo "  1) 跑完整部署（下载 H3 权重 + ComfyUI + 出片链路）："
  echo "       bash $WS/deploy-h3-cannlab.sh all"
  echo "  2) 部署完启动并开公网访问（若无 frps，见文档「公网入口」替代方案）："
  echo "       bash $WS/comfy_tunnel.sh start"
  echo "  3) 配置开机自启："
  echo "       bash $WS/setup_autostart.sh"
  echo "  4) （可选）再下载文生图/图生图模型："
  echo "       bash $WS/download_models.sh"
  echo "  5) 用完记得在 CANNLab 控制台关机，停止扣卡时。"
  echo "────────────────────────────────────────────────────────────"
  echo "详细步骤与排错见 CANNLab_H3_Replication_Guide.md / .html"
fi

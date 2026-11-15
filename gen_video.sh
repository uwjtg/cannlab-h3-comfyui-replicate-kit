#!/usr/bin/env bash
# MiniMax H3 视频+音频 一键出片入口
# 日常用法：编辑 /mnt/workspace/h3-ascend/prompt.txt 后运行本脚本
set -euo pipefail

if ! curl -fsS -m 5 http://127.0.0.1:8188/system_stats >/dev/null 2>&1; then
  echo "ComfyUI 没在跑，先启动服务："
  echo "  cd /mnt/workspace && bash deploy-h3-cannlab.sh start"
  exit 1
fi

exec python3 -u /mnt/workspace/gen_video.py "$@"

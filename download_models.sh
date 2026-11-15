#!/bin/bash
# 文生图 / 图生图 模型下载 —— 下载到 ComfyUI 的 models 目录（持久卷 /mnt/workspace）
# 幂等：已完整下载的文件会跳过；中断可续传（aria2c -c + .part）
ROOT=/mnt/workspace/h3-ascend/ComfyUI/models
CK=$ROOT/checkpoints
VAE=$ROOT/vae
L=/mnt/workspace/logs
mkdir -p "$CK" "$VAE" "$L"
M=$L/models_dl.log
echo "=== $(date) DOWNLOAD START ===" > "$M"

dl() {
  local url="$1" out="$2" tag="$3" want="$4"
  if [ -f "$out" ] && [ "$(stat -c%s "$out")" = "$want" ]; then
    echo "SKIP $tag already complete" >> "$M"
    return
  fi
  echo "START $tag want=$want" >> "$M"
  aria2c -c -x 6 -s 6 -k 4M --min-split-size 4M -m 5 --retry-wait 5 \
    --auto-file-renaming=false --allow-overwrite=true --console-log-level=error \
    --summary-interval=30 -d "$(dirname "$out")" -o "$(basename "$out").part" \
    "$url" > "$L/dl_${tag}.log" 2>&1
  local sz
  sz=$(stat -c%s "$out.part" 2>/dev/null || echo 0)
  if [ "$sz" = "$want" ]; then
    mv "$out.part" "$out"
    rm -f "$out.part.aria2"
    echo "DONE $tag size=$sz" >> "$M"
  else
    echo "FAIL $tag size=$sz want=$want" >> "$M"
  fi
}

# 1) SDXL 1.0 base —— 文生图主力（也可做 img2img）
dl "https://hf-mirror.com/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors" \
   "$CK/sd_xl_base_1.0.safetensors" "sdxl_base" 6938078334 &
# 2) SD 1.5 fp16 —— 图生图 / LoRA / ControlNet 生态最全，兼容性最好
dl "https://hf-mirror.com/Comfy-Org/stable-diffusion-v1-5-archive/resolve/main/v1-5-pruned-emaonly-fp16.safetensors" \
   "$CK/v1-5-pruned-emaonly-fp16.safetensors" "sd15" 2132696762 &
# 3) SDXL VAE fp16-fix —— 修 SDXL 半精度黑图
dl "https://hf-mirror.com/madebyollin/sdxl-vae-fp16-fix/resolve/main/sdxl_vae.safetensors" \
   "$VAE/sdxl_vae_fp16fix.safetensors" "sdxl_vae" 334641162 &
# 4) FLUX.1 [schnell] fp8 全合一 checkpoint —— 热门文生图（4 步出图），也可 img2img
dl "https://hf-mirror.com/Comfy-Org/flux1-schnell/resolve/main/flux1-schnell-fp8.safetensors" \
   "$CK/flux1-schnell-fp8.safetensors" "flux_schnell_fp8" 17236328572 &
wait
echo "=== ALL_FINISHED $(date) ===" >> "$M"
ls -lh "$CK"/*.safetensors "$VAE"/*.safetensors >> "$M" 2>&1
touch /mnt/workspace/.models_dl_done

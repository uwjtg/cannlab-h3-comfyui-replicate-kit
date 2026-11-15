# CANNLab A3 · MiniMax H3 + ComfyUI 一键复刻套件

面向「另一个账号」从零复刻 CANNLab A3（1×NPU 910C）上 MiniMax H3 + ComfyUI 的成套脚本、工作流与文档。**不含任何明文凭据**：frps token 与 ComfyUI 密码均在部署时运行时生成，可安全公开。

## 包含
- `deploy-h3-cannlab.sh`：分阶段部署（预检/代码/依赖/权重/配置/启动/出片）
- `gen_video.py` / `gen_video.sh` / `prompt.txt`：改提示词一键出片（视频+原生音频）
- `comfy_tunnel_auth.py` / `comfy_tunnel.sh`：公网入口（Basic Auth 反向代理 + frpc）
- `setup_autostart.sh` / `auto_start.sh`：开机自启
- `download_models.sh`：追加文生图/图生图模型
- `init_replicate.sh`：获取套件 + 解包 + 预检 一键初始化
- `CANNLab_H3_Replication_Guide.md` / `.html`：完整操作手册
- `workflows_to_test/`：33 个 ComfyUI 工作流（ready / official / community）

## 快速开始（在 CANNLab Web IDE 终端）
```bash
# 方式 D（推荐）：clone 后直接跑
git clone https://github.com/uwjtg/cannlab-h3-comfyui-replicate-kit.git ~/kit && cd ~/kit
bash init_replicate.sh --deploy
```
其他获取方式（本地 zip / 直链 / KIT_REPO）见文档 2.5 节。

## 复刻时必须替换
- `comfy_tunnel.sh` 里的 frps 主机名与远程端口（换成你自己的 frps）
- frps token 写入 `/mnt/workspace/.frps_token`（600），不要进脚本/文档
- ComfyUI 密码由脚本自动生成存 `.comfy_web_pass`

## 注意
- 创建环境需在 CANNLab 控制台手动选 `1×NPU 910C` + `CANN 9.0.0`（约 2 分钟），脚本不代建。
- 开机即按「卡数 × 小时」扣卡时；用完记得关机。

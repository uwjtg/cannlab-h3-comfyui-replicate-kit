# CANNLab A3 · MiniMax H3 + ComfyUI 复刻操作手册

> **目标**：在一个全新的 CANNLab 账号里，从零复刻出「MiniMax H3 视频 + 原生音频出片 → ComfyUI 图形界面 → 开机自启 → 文生图/图生图模型」的完整环境。
>
> **实测基线**：2026-11-14 ~ 11-15，CANNLab A3 / 1×NPU 910C / CANN 9.0.0 镜像。端到端出片成功（338–408 秒生成约 5.17 秒的 H.264 视频 + AAC 原生音频）。
>
> **配套文件**：`CANNLab_H3_Replication_Kit.zip`，内含本文档、全部脚本、33 个工作流 JSON/PNG。把 zip 解压到新环境的 `/mnt/workspace/` 即可开工。
>
> **文档约定**：`$ROOT` = `/mnt/workspace`；所有命令在 CANNLab Web IDE 的终端里执行；`⚠️` 标记的是踩过的坑。

---

## 0. 先看这五条，能省掉 90% 的返工

1. **环境选错必定失败**。必须用 CANNLab **A3** 环境 + `cann_9.0.0` 模板。GitCode Notebook（910B4 / 30GB HBM / CANN 8.5 / 50GB 且不持久化 / 单次 2 小时）与本项目硬件、版本、存储全不匹配。
2. **只有 `/mnt/workspace` 和 `/home` 是持久卷**。`/etc`、`/opt` 每次开机由镜像重建；所有脚本、权重、产物一律放 `/mnt/workspace`。
3. **开机即扣卡时**。1 卡时 = 卡数 × 运行小时，与 NPU 是否真的在算无关；新账号一次性赠送 100 卡时，空闲 30 分钟自动关机。关机不扣费且持久卷数据保留，**部署/测试完记得关机**。
4. **容器没有公网入站，也没有端口转发能力**。Web IDE 里搜「端口 / port」都找不到入口，浏览器打不开 `127.0.0.1:8188`；且无 `CAP_NET_ADMIN`、`TUNSETIFF` 报 `Operation not permitted`，**VNT / WireGuard 这类要 TUN 的 VPN 全部不可用**。
5. **本项目不是通用安装器**。上游 `OwenLittleWhite/cannlab-h3-ascend` 明确说「脚本针对测试过的 CANNLab 镜像」，作者靠 `constraints.txt` 把依赖全锁死。换镜像 = 要重新做依赖适配（本手册已包含 20261106 镜像的适配结果）。

---

## 1. 环境规格与版本对照（创建环境前确认）

| 项目 | 必须值 | 说明 |
|---|---|---|
| 平台 | CANNLab（`https://gitcode.com/org/cann/cannlab`） | 不是普通 Notebook |
| 环境类型 | **NPU A3** | 页面注明每类环境限建一个 |
| 模板 | `cann_9_0_0-py3.11-a3-arm-20261106` | ⚠️ 不要选 9.1.0 / lite-train 模板 |
| 规格 | `1*NPU 910C, 40vCPUs, 240GiB` | 910C 单卡暴露 **2 个逻辑 NPU**，项目要求 ≥2 |
| 数据盘 | 盘1 EVS 200GiB → `/mnt/workspace`；盘2 EVS 200GiB → `/home` | 脚本硬编码这些路径，不要改 |
| 权重空间 | ≥ 80GB 空闲 | 5 个权重合计 **67.7GB** |
| Python | 3.11 | 镜像自带 |
| torch / torch_npu | `2.7.1+cpu` / `2.7.1.post4` | 镜像预装，**不要覆盖** |
| torchaudio | `2.7.1` | 镜像自带 2.11，ABI 不符，需 `--no-deps` 强制装 2.7.1 |
| CANN | 9.0.0 | `set_env.sh` 在 `/home/developer/Ascend/cann-9.0.0/` |
| ComfyUI | commit `bd34f338ac505ea79e43968753968a464060e609` | 补丁只能打在这个 commit 上 |
| 权重 | 5 个 ≈ 67.7GB | FL2VA DiT INT8 34GB + Qwen3-VL TE INT8 27.1GB + video VAE 5.2GB + audio VAE 0.6GB + Turbo LoRA 0.78GB |

**卡时规则**（官方用户指南 + 账号实测）：状态「运行中」消耗卡时，「关机/休眠/异常」不消耗；额度耗尽自动关机并释放资源；初始 100 卡时是一次性赠送，不是每月发放；官方未公开初始额度的到期日。页面读数有结算延迟，刷新才更新。

---

## 2. 创建环境（控制台，约 2 分钟）

1. 打开 `https://gitcode.com/org/cann/cannlab/environment`，点「新建环境」。
2. 环境类型选 **NPU A3**；模板下拉选 `cann_9.0.0 py3.11-A3-arm-20261106`（默认项是 9.1.0 lite，务必改）。
3. 规格只有 `1*NPU 910C / 40vCPUs / 240GiB` 一种；实例名随意（本例 `DevEnvC_clzRc`）。
4. 创建后点「启动」→ 状态变「运行中」→ 点「连接」→ 选「Web IDE」，会打开 CodeArts IDE（VS Code Web fork），工作目录 `/mnt/workspace`。
5. 打开底部「终端」面板。

---

## 2.5 一键初始化脚本（推荐：自动完成上传 + 预检）

套件里新增了 `init_replicate.sh`，把「获取套件 + 解包 + 预检」三步合成一条命令，省去手动 `unzip` 和逐条核对。它会在跑 `deploy-h3-cannlab.sh precheck` 之前，先做一轮轻量自检（架构 / NPU / 持久卷可写性 / 磁盘空闲 / 下载工具 / 套件完整性），任何一项不达标就立即中止并给出修复提示，不会白白开始下载 67.7GB 权重。

**用法（四选一）：**

```bash
# 方式 A：已把 CANNLab_H3_Replication_Kit.zip 拖进 /mnt/workspace/，直接跑
bash /mnt/workspace/init_replicate.sh

# 方式 B：套件托管在直链 zip，自动下载（把 URL 换成你自己的）
KIT_URL=https://你的域名/CANNLab_H3_Replication_Kit.zip \
  bash <(curl -fsSL https://你的域名/init_replicate.sh)

# 方式 C：套件在 git 仓库（推荐分享给另一个账号的做法，见下）
KIT_REPO=https://gitcode.com/你的名/你的仓库.git \
  bash <(curl -fsSL https://你的域名/init_replicate.sh)

# 方式 D：把仓库 git clone 下来后，直接在 clone 目录里跑（无需再下载）
git clone https://gitcode.com/你的名/你的仓库.git ~/kit && cd ~/kit
bash init_replicate.sh          # 脚本会自动识别「自己就在套件目录里」
```

预检通过后，脚本会打印后续 5 步（部署 / 开公网 / 自启 / 下载文生图模型 / 关机）。如果你确定要直接开跑，**加 `--deploy`** 让它预检完立刻继续 `deploy-h3-cannlab.sh all`：

```bash
bash /mnt/workspace/init_replicate.sh --deploy
```

> ⚠️ 脚本只解决「获取 + 预检」，创建环境（2 分钟，选 1×NPU 910C + CANN 9.0.0）仍需在控制台手动做，见第 2 节。
> ⚠️ 若用 `bash <(curl ...)` 方式，请确保你托管 `init_replicate.sh` 的地址与 `KIT_URL` 都可达；否则退回方式 A（本地上传 zip）最稳妥。

### 套件托管到项目仓库（推荐，方便多账号共享）

**可以，而且能安全公开托管**——套件压缩包里**不含任何明文凭据**：frps token 与 ComfyUI 密码都在部署时运行时生成（写进 `/mnt/workspace/.frps_token`、`/.comfy_web_pass`，权限 600），从不在 zip 内。唯一露脸的是 `comfy_tunnel.sh` 里的 frps 主机名（`vnts2.770710712.xyz`，本就是占位符、文档要求复刻时 `sed` 替换成自己的），风险很低。

**把套件推上 GitCode 仓库（在你本机执行）：**

```bash
cd D:/WorkBuddy/2026-11-14-19-55-19
# 建仓后，把套件「解包后的文件」作为仓库内容（不要直接传那个 zip，init 走 git 路径要的是散文件）
rm -rf /tmp/kit_repo && mkdir -p /tmp/kit_repo && \
  unzip -o CANNLab_H3_Replication_Kit.zip -d /tmp/kit_repo && \
  cd /tmp/kit_repo && \
  git init -q && git add -A && git commit -qm "CANNLab H3 + ComfyUI replicate kit" && \
  git branch -M main && \
  git remote add origin https://gitcode.com/你的名/你的仓库.git && \
  git push -u origin main
```

- **公开仓库**最省事：另一个账号无需登录就能 clone。
- **私有仓库**：给另一个账号加 collaborator，或在 clone URL 里带只读 PAT：`https://<token>@gitcode.com/你的名/你的仓库.git`。
- GitCode 的 Raw 直链（`init_replicate.sh` 的托管地址，用于方式 C 那个 `curl`）在文件页面点「Raw」按钮复制即可，形如 `https://gitcode.com/你的名/你的仓库/-/raw/main/init_replicate.sh`。

**另一个账号消费（在 CANNLab Web IDE 终端）：**

```bash
# 最简单：clone 后直接跑（方式 D）
git clone https://gitcode.com/你的名/你的仓库.git ~/kit && cd ~/kit && bash init_replicate.sh

# 或一行流（方式 C，脚本自己再去 clone 一遍套件）：
KIT_REPO=https://gitcode.com/你的名/你的仓库.git \
  bash <(curl -fsSL https://gitcode.com/你的名/你的仓库/-/raw/main/init_replicate.sh)
```

---

## 3. 上传脚本包

把 `CANNLab_H3_Replication_Kit.zip` 的内容放到 `/mnt/workspace/`。两种方式：

**方式 A（推荐，Web IDE 有上传功能）**：在左侧资源管理器 `WORKSPACE` 上右键上传文件，或把本地文件直接拖进去，然后解压：

```bash
cd /mnt/workspace && unzip -o CANNLab_H3_Replication_Kit.zip
```

**方式 B（只有终端时，用 base64 传单个文件）**：在本地执行 `base64 -w0 文件名` 得到字符串，到 Web IDE 终端执行：

```bash
echo '这里粘贴base64字符串' | base64 -d > /mnt/workspace/文件名
```

> ⚠️ 多行 heredoc 在 CodeArts 终端里会卡住 shell（等结束标记）；要传多行脚本，一律 base64 单行上传。终端里 `!` 会触发 bash 历史扩展，命令里别带 `!`。

### 脚本包文件清单

| 文件 | 作用 |
|---|---|
| `deploy-h3-cannlab.sh` | **核心**：分阶段部署（预检/代码/依赖/权重/配置/启动/出片） |
| `gen_video.py` / `gen_video.sh` / `prompt.txt` | 改提示词一键出片，不依赖图形界面 |
| `comfy_tunnel_auth.py` | aiohttp 反向代理 `8189 → 8188`，带 HTTP Basic Auth + WebSocket 转发 |
| `comfy_tunnel.sh` | 公网入口管理（start/stop/status/url/restart） |
| `setup_autostart.sh` / `auto_start.sh` | 开机自启钩子与启动脚本 |
| `download_models.sh` | 追加文生图/图生图模型下载 |
| `init_replicate.sh` | **一键初始化**：获取套件 + 解包 + 预检（见 2.5 节） |
| `workflows_to_test/` | 33 个工作流（ready / official / community） |
| `CANNLab_H3_Replication_Guide.md` | 本文档 |

---

## 4. 一键部署（核心，约 30–60 分钟）

```bash
cd /mnt/workspace
bash deploy-h3-cannlab.sh precheck          # ① 必须先看这步全通过
nohup bash deploy-h3-cannlab.sh all > /mnt/workspace/_wb_all.log 2>&1 &
tail -f /mnt/workspace/_wb_all.log           # ② 看进度（Ctrl+C 只退出 tail，不中断任务）
```

`precheck` 会检查：NPU 设备、`torch.npu.device_count() >= 2`、`/mnt/workspace` 空闲 ≥80GB、CANN 9.0.0 `set_env.sh`、以及 hf-mirror / 清华 pip / GitCode 镜像的连通性。

### 阶段说明

| 阶段 | 做什么 | 断点后续跑 |
|---|---|---|
| `precheck` | 硬件/版本/磁盘/网络体检 | — |
| `code` | 拉项目源码、完整 clone ComfyUI 并锁定 commit、打 Ascend 补丁、装 custom_nodes、补齐路径 | 幂等 |
| `deps` | 建 venv、修 torchaudio ABI、装锁定版依赖、api-gateway 独立 venv、**静态 TLS 修复**、运行时自检 | 幂等 |
| `models` | 按 `model-manifest.json` 用 aria2 下载 67.7GB 权重并 sha256 校验 | `bash deploy-h3-cannlab.sh models`（续传） |
| `config` | 写 `api-gateway/config/ascend.json`、生成工作流模板 | 幂等 |
| `start` | 启动 ComfyUI(8188) + api-gateway(8191) | 每次开机跑一次 |
| `smoke` | 提交第一个视频任务 | — |
| `fix` | 单独重做静态 TLS 修复 | 幂等 |

其他常用命令：

```bash
bash deploy-h3-cannlab.sh models    # 权重下载中断后续传
bash deploy-h3-cannlab.sh fix       # 单独重做静态 TLS 修复
bash deploy-h3-cannlab.sh start     # 开机后启动服务
bash deploy-h3-cannlab.sh smoke     # 出第一个视频
```

### ⚠️ 30 分钟空闲自动关机

`all` 阶段下载 67.7GB 权重实测约 57MB/s、20 分钟左右，但环境「持续空闲 30 分钟」会自动关机并杀掉 nohup 进程。**长时间下载要保持 Web IDE 页面有操作**（隔十几分钟敲一条命令即可）。脚本所有阶段都是幂等的，被关机后重启环境、再跑一次 `all` 会自动跳过已完成步骤、续传权重。

> ⚠️ 保活 = 持续扣卡时。下载/测试结束后**务必撤销保活并关机**。曾因页面里残留一个 8 分钟一次的保活定时器，让环境永不空闲、白白烧掉卡时。

### 检查点

```bash
grep -E 'ALL_MODELS_VERIFIED|IMPORT_CHAIN_OK|TLS_FIX' /mnt/workspace/_wb_all.log
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8188/system_stats   # 期望 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8191/health        # 期望 200
```

---

## 5. 最关键的坑：sentencepiece 静态 TLS

**症状**：ComfyUI 启动即退出，日志里报
`libgomp-<hash>.so.1.0.0: cannot allocate memory in static TLS block`。

> 📌  bundled 库的真名是 **`libgomp-dcaa4144.so.1.0.0`**（auditwheel 的 `libgomp-<hash>` 命名）。早期靠截图 OCR 抄成 `libwgmp-…`，导致所有 `grep` / `patchelf` / `readelf` 排查全部落空。用 Python `repr()` 打印目录项才查实。

**根因**：`torch_npu` 导入时已加载系统 `libgomp.so.1`；而 pip 装的 `sentencepiece 0.2.3` wheel 的 `_sentencepiece*.so` 里 `DT_NEEDED` 指向自带的另一个 bundled `libgomp-<hash>.so.1.0.0`，`dlopen` 时作为新库申请静态 TLS ⇒ 失败。作者实跑镜像没这个问题。

**正解（脚本已自动做，`fix` 阶段 / `deps` 末尾 / `start` 开头都会幂等执行）**：在 `.dynstr` 里**原地等长改写**该字符串为 `libgomp.so.1`（后面补 NUL 填充）。`.gnu.version_r` 按偏移引用同一字符串，会自动同步，不破坏符号版本需求。

```bash
bash /mnt/workspace/deploy-h3-cannlab.sh fix
# 验证
/mnt/workspace/h3-ascend/.venv/bin/python -c \
  'import torch, torch_npu, torchaudio, sentencepiece; print("IMPORT_CHAIN_OK")'
```

**❌ 已实测无效 / 有害的做法，别再试**：

- `pip install --no-binary :all: sentencepiece==0.2.3` 源码编译 → setuptools 报 `project.license must be valid exactly by one definition`；
- `LD_PRELOAD`（bundled 库 / 系统 libgomp / 两者各种顺序）→ 静态 TLS 总量不够两个 libgomp 共存；
- 把 bundled 库软链到系统 libgomp → 仍按新库加载；
- ⛔ **`patchelf --remove-needed`** → 不更新 `.gnu.version_r`，触发 `_dl_check_map_versions: Assertion 'needed != NULL' failed`。

---

## 6. 服务端口与启动

```bash
cd /mnt/workspace && bash deploy-h3-cannlab.sh start
```

| 端口 | 服务 | 备注 |
|---|---|---|
| `8188` | ComfyUI | `/system_stats`、`/prompt`、`/history/{id}`、`/ws` |
| `8191` | api-gateway **真实 API** | `/health`、`/docs` |
| `8190` | api-gateway 反向代理 | ⚠️ `/health` 恒 404，**别拿它做健康检查**，否则每次 start 都误判并重复拉起进程 |
| `8189` | Basic Auth 认证代理 | 见第 8 节 |

所有服务只监听 `127.0.0.1`。日志：`/mnt/workspace/h3-ascend/logs/comfyui.log` 与 `api-gateway.log`。

> ⚠️ `nohup ... > log` 时 Python stdout 是全缓冲，出片脚本的 `prompt_id` 要等进程结束才刷出。期间用 `curl 127.0.0.1:8188/queue` 和 `logs/comfyui.log` 看进度更可靠；脚本里已用 `python3 -u` 规避。

---

## 7. 出片（视频 + 原生音频）

```bash
cp /mnt/workspace/prompt.txt /mnt/workspace/h3-ascend/prompt.txt   # 首次：放到脚本默认读取的位置
vi /mnt/workspace/h3-ascend/prompt.txt                              # 改提示词
bash /mnt/workspace/gen_video.sh                                    # 一键出片
```

> ⚠️ `gen_video.py` 默认读 `/mnt/workspace/h3-ascend/prompt.txt`，而脚本包里的模板在 `/mnt/workspace/prompt.txt`；也可以用 `--prompt-file /mnt/workspace/prompt.txt` 或 `--prompt "..."` 绕开。
>
> ⚠️ **不要提前手工创建 `/mnt/workspace/h3-ascend/` 目录**：`code` 阶段要 `git clone` 到该路径，目录已存在且非空会让 clone 直接失败。上面的 `cp` 必须在 `deploy-h3-cannlab.sh all` 跑完之后执行。

脚本会按 `class_type` 定位节点改参数后 POST `8188/prompt`，轮询 `/history/{pid}` 到完成并打印产物绝对路径。参数（也可用同名环境变量）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--prompt` / `--prompt-file` | `h3-ascend/prompt.txt` | 提示词，支持中文 |
| `--seed` | `-1` | 随机种子，-1 每次随机 |
| `--width` / `--height` | `736` / `416` | 分辨率 |
| `--length` | `124` | 帧数，24fps 时 ≈5.17 秒 |
| `--fps` | `24` | 帧率 |
| `--steps` | `6` | turbo LoRA 固定 6 步，不建议改 |
| `--prefix` | `video/my_h3` | 输出前缀，相对 `ComfyUI/output/` |
| `--no-wait` / `--timeout` | 1800s | 只提交 / 最长等待 |

示例：

```bash
SEED=20261115 PREFIX=video/demo bash /mnt/workspace/gen_video.sh --prompt "一个人在阳光下微笑"
```

**实测结果**：`Prompt executed in 338.58 seconds`，产物 `ComfyUI/output/video/..._00001_.mp4`，约 310KB，`av` 检查流为 `[('video','h264'), ('audio','aac')]`，时长 5.17 秒 —— 视频与原生音频都生成了。

> ⚠️ **`.api.json` 与 `.ui.json` 不能混用**：网页画布 Load 的是 UI 格式（有 `nodes`/`links`），命令行 POST `/prompt` 用的是 API 格式（`{"1":{"class_type":...}}`）。`gen_video.py` 用的是 `h3_larry_v4_6step_2npu.api.json`（16 节点）。

---

## 8. ComfyUI 图形界面（可选，三选一）

CANNLab Web IDE **没有端口转发**，浏览器无法直接访问 `127.0.0.1:8188`。给图形界面开通道有三条路：

### 路线 A：frpc（需要你自备 frps 服务端，地址固定）

适合有公网服务器/NAS 的情况。本例用 `frps 0.71.0`，`allowPorts 10000–20000`，`remotePort=18188`。

1. 在 frps 服务器取 `auth.token`，写到容器内 `/mnt/workspace/.frps_token`（权限 600），**不要写进任何脚本或文档**：

   ```bash
   printf '%s' '你的token' > /mnt/workspace/.frps_token
   chmod 600 /mnt/workspace/.frps_token
   ```

2. 把 `comfy_tunnel.sh` 里的 `vnts2.770710712.xyz` 换成你的 frps 域名、`18188` 换成你的远程端口（共 3 处：`PUBLIC_URL`、`ensure_frpc()` 内 `frpc.toml` 模板的 `serverAddr` 与 `remotePort`）：

   ```bash
   cd /mnt/workspace
   sed -i 's/vnts2\.770710712\.xyz/YOUR_FRPS_HOST/g; s/18188/YOUR_REMOTE_PORT/g' comfy_tunnel.sh
   ```

   端口必须落在 frps 的 `allowPorts` 范围内；`frpc.toml` 由脚本首次启动时自动生成，不用手写。若你的 frps 监听端口不是 `7000`，还要改模板里的 `serverPort = 7000`。
3. 启动：

```bash
bash /mnt/workspace/comfy_tunnel.sh start
bash /mnt/workspace/comfy_tunnel.sh status
bash /mnt/workspace/comfy_tunnel.sh url
```

链路：`ComfyUI 8188` ← `认证代理 8189` ← `frpc` ← `frps:18188`。用户名默认 `comfy`，密码由脚本自动生成并存 `/mnt/workspace/.comfy_web_pass`（首次生成后固定）。访问信息会写入 `/mnt/workspace/COMFY_ACCESS.txt`。

> ⚠️ frpc 与 frps **版本要一致**（本例 0.71.0）。若报 `token in login doesn't match token from configuration`，别急着换版本：先用 sha 比对 `.frps_token` 与 `frpc.toml` 里 `auth.token` 是否一致，多数情况是提取 token 时正则取错值。
>
> ⚠️ `ensure_frpc()` 会从 GitHub Releases 拉 `frp_0.71.0_linux_arm64.tar.gz`，而容器对 GitHub 的连通性不稳定（`git clone` 实测 `Empty reply from server`）。若下载失败，可在本机下载该包、只取 `frpc` 一个二进制，用 base64 上传到 `/mnt/workspace/bin/frp071/frpc` 并 `chmod +x` 即可。

### 路线 B：cloudflared Quick Tunnel（零服务端，代价是域名每次变）

不需要账号/域名/服务端，纯出站 TCP 7844 即可。缺点是 `*.trycloudflare.com` 域名**每次重启都会变**。本仓库的 `comfy_tunnel.sh` 已是 frpc 版；若要用 cloudflared，把 `start` 里的 frpc 段换成下载 `cloudflared-linux-arm64` 并 `tunnel --url http://127.0.0.1:8189`，从日志抓域名写入 `COMFY_URL.txt` 即可。认证代理照旧保留。

### 路线 C：本地 VS Code Remote SSH 转发

用 AtomGit Dev Space + Remote SSH 连上环境后转发 8188，再访问 `http://localhost:8188`。适合不想开公网入口的场景。

### 为什么必须加认证代理

ComfyUI 本身没有鉴权，直接暴露公网等于裸奔。`comfy_tunnel_auth.py` 在 `8189` 做 HTTP Basic Auth，并**完整双向转发 `/ws` WebSocket** —— 否则前端实时进度/预览会失效。验证：

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8189/system_stats          # 401 = 正确
curl -s -o /dev/null -w '%{http_code}\n' -u comfy:密码 http://127.0.0.1:8189/system_stats  # 200
```

> ⚠️ **本机 HTTP 代理会吃掉 WebSocket 的 Upgrade 头**，浏览器走代理时前端报 `400 No WebSocket UPGRADE hdr`。必须把公网域名加入直连/白名单；命令行验证要加 `curl --noproxy '*'`。正常表现是 `101 Switching Protocols` + 收到 `{"type":"status"}`。

> ⚠️ 无论哪条路线，**不要把 ComfyUI 地址和密码外传**。

---

## 9. 开机自启

平台启动链：`tini` → `/start_docker.sh` → supervisor（`bash -l -c`，user=developer）。**没有 systemd / cron / at**。

- ⚠️ `/start_docker.sh` 每次开机用 `/opt/home/developer/` **覆盖** `~/.bashrc` 和 `~/.profile` ⇒ 改这两个文件无效。
- ✅ 但它**不会创建 `~/.bash_profile`**，而 `bash -l` 优先读它 ⇒ 钩子放 `/home/developer/.bash_profile`（在持久卷 `/home` 上）。

```bash
bash /mnt/workspace/setup_autostart.sh      # 幂等；原文件存在会先备份为 .bash_profile.wbbak
bash -l -c true                            # 模拟登录 shell，验证钩子被触发
tail -30 /mnt/workspace/logs/auto_start.log
```

`auto_start.sh` 会：等持久卷挂载（最多 60s）→ 用锁目录 + 存活 pid 防并发 → ComfyUI 未起则执行 `deploy-h3-cannlab.sh start` 并轮询 8188（最多 270s）→ 执行 `comfy_tunnel.sh start` → 重写 `COMFY_ACCESS.txt`。

验证方法：把 ComfyUI 和隧道全停，再触发一次 `bash -l -c true`，应能自动恢复到 `8188=200`、frpc 运行中、认证代理运行中。

> ⚠️ 调用脚本一律用**硬编码绝对路径**（曾写成 `bash "$ROOT/comfy_tunnel.sh start"` 把参数包进引号，服务在跑时被幂等掩盖，全停才暴露）。开机自启只在本机验证过；真实「关机 → 开机」链路依赖 supervisor 同样用 `bash -l -c`，逻辑上是闭环的。

---

## 10. 文生图 / 图生图扩展（可选）

这套 ComfyUI 已打过 **Ascend NPU 补丁**（`comfy/model_management.py` 里有 `import torch_npu`、`torch.npu.is_available()`、`is_ascend_npu()`），所以标准 SD/FLUX checkpoint 有机会直接在 910C 上跑，不只能跑 H3。

```bash
bash /mnt/workspace/download_models.sh          # 幂等 + aria2 续传 + 字节数校验
cat /mnt/workspace/logs/models_dl.log           # 看 DONE / FAIL / ALL_FINISHED
```

| 模型 | 用途 | 落盘位置 | 大小 |
|---|---|---|---|
| `sd_xl_base_1.0.safetensors` | 文生图主力，也可 img2img | `models/checkpoints/` | 6.94 GB |
| `flux1-schnell-fp8.safetensors` | 热门 4 步出图（全合一 checkpoint） | `models/checkpoints/` | 17.24 GB |
| `v1-5-pruned-emaonly-fp16.safetensors` | 图生图 / LoRA / ControlNet 生态 | `models/checkpoints/` | 2.13 GB |
| `sdxl_vae_fp16fix.safetensors` | 修 SDXL 半精度黑图 | `models/vae/` | 335 MB |

> ⚠️ `madebyollin/sdxl-vae-fp16-fix` 仓库里的真实文件名是 `sdxl_vae.safetensors`，下载后另存为 `sdxl_vae_fp16fix.safetensors`；直接用后者拼 URL 会 404。

### 工作流包 `workflows_to_test/`

| 子目录 | 内容 |
|---|---|
| `ready/` | **6 个即开即用**：checkpoint 名已改成上面实际下载的文件名，links 校验 0 错误 —— `01` SD1.5 图生图、`02` SDXL 文生图、`03` FLUX schnell 文生图、`04` SD1.5 高清修复、`05` SD1.5 局部重绘、`06` SD1.5 ControlNet |
| `official/` | 10 组 ComfyUI 官方 `ComfyUI_examples`：PNG + 从 PNG `tEXt/iTXt` 元数据提取出的标准 UI JSON，全是内置节点 |
| `community/` | 7 个社区热门模板（SDXL Turbo、FLUX dev/schnell/FLUX2、Kandinsky5、FLUX 参考图等） |

**下次开机测试**：打开 ComfyUI 网页 → **Load** → 上传 `ready/*.json` → Queue Prompt。

风险提示：
- 社区 JSON 里带 UUID 节点的是**子图/自定义插件**，这个环境没装对应插件，加载会出红节点，建议后测。
- `ready_06` 还缺一份 ControlNet 权重，需要额外下载。
- **FLUX fp8** 在昇腾上可能回退 fp16，速度偏慢；若 SDXL 出黑图，手动加 `VAELoader` 选 `sdxl_vae_fp16fix`。
- 容器里 `raw.githubusercontent.com` 不通（返回 `000`），工作流从本地上传，别指望在容器内直接 clone GitHub。

---

## 11. 卡时管理与关机

1. 撤销一切页面/脚本保活（否则环境永不空闲，持续扣卡时）。
2. 确认文件都在持久卷：`ls /mnt/workspace/`、`cat /mnt/workspace/logs/models_dl.log`。
3. 环境页 `https://gitcode.com/org/cann/cannlab/environment` → 找到实例 → 点「**关机**」→ 确认。
4. 状态依次走「正在保存运行状态… → 正在停止服务… → 正在关闭系统…」，最终显示 **已关机 / 运行中实例 0**。

> ⚠️ 关机后页面可能残留一个可见的「启动实例」确认框模板，点「取消」清掉，**别误点「启动」**，否则又开始扣卡时。

> ⚠️ 关机会清掉 `/etc`、`/opt` 里的改动，但 `/mnt/workspace`、`/home` 权重/脚本/产物全部保留；下次开机跑一次 `deploy-h3-cannlab.sh start`（或让自启脚本代劳）即可恢复服务。

---

## 12. 故障排查速查表

| 症状 | 原因 | 处理 |
|---|---|---|
| `git clone` GitHub 报 `Empty reply from server` | 容器内 GitHub 不通 | 用 `https://gitcode.com/gh_mirrors/co/ComfyUI.git` 或 `https://gitee.com/mirrors/ComfyUI.git` |
| clone 成功但 checkout 时 `fatal: ...` | `--filter=blob:none` 惰性取 blob 回源 GitHub | 改**完整** `git clone --no-checkout`，校验 commit 后 `checkout --detach` |
| `git apply` 补丁预检失败 | ComfyUI 版本不对 | 必须锁 `bd34f338…`；脚本用 `--reverse --check` 保证幂等 |
| `libtorchaudio.abi3.so: undefined symbol` | 镜像自带 torchaudio 2.11 与 torch 2.7.1 ABI 不符 | `pip install --no-deps --force-reinstall 'torchaudio==2.7.1'` |
| `cannot allocate memory in static TLS block` | sentencepiece bundled libgomp | `bash deploy-h3-cannlab.sh fix`（见第 5 节） |
| `_dl_check_map_versions: Assertion 'needed != NULL'` | 用了 `patchelf --remove-needed` | 从 `.pre_tls_fix` 备份恢复 `.so`，改用等长改写 |
| `prepare_workflows.py` 找不到 `H2Videos_usage.log` | 脚本按 `ROOT=deployment/` 算相对路径 | 建 `deployment/upstream/` 软链到实际 clone 位置 |
| 工作流模板找不到 | `prepare_workflows.py` 写到 `deployment/workflows/` | 复制到 `ROOT/workflows/` |
| ComfyUI 起不来 / 启动参数报错 | 用了模板版 `start.sh` | 用作者验证版 `deployment/scripts/start.sh`（含 `LD_PRELOAD` + `--cache-classic`） |
| `8190/health` 恒 404 | 8190 只是反代 | 健康检查用 **`8191/health`** |
| `TUNSETIFF: Operation not permitted` | 容器无 `CAP_NET_ADMIN` | VNT/WireGuard 不可用，改走 frpc / cloudflared（纯出站） |
| frpc `token in login doesn't match` | 客户端 token 写错（多数） | sha 比对 `.frps_token` 与 `frpc.toml`，并确保 frpc/frps 同版本 |
| 前端 `400 No WebSocket UPGRADE hdr` | 本机 HTTP 代理吃了 Upgrade 头 | 域名加入直连白名单；curl 加 `--noproxy '*'` |
| 环境莫名关机 / nohup 被杀 | 单卡环境空闲 30 分钟自动关机 | 长任务保活；脚本幂等，重启后续跑 |
| 卡时掉得比预期快 | 页面残留保活 JS / 后台保活任务 | `clearInterval` 撤销；不用就关机 |
| 网页 Load JSON 报错 | 把 `.api.json` 当 UI 工作流用了 | 画布用 UI 格式，命令行提交用 API 格式 |
| 终端卡住等输入 | 多行 heredoc 卡 shell | Ctrl+C 解围；多行脚本一律 base64 单行上传 |

---

## 13. 换账号时必须替换／确认的清单

| 项目 | 说明 |
|---|---|
| **CANNLab 账号与实例** | 新账号需自行注册认证并领取初始 100 卡时；环境名/实例 ID 脚本里没有硬编码 |
| **frps 服务端**（若用路线 A） | 改 `comfy_tunnel.sh` 里的 `serverAddr`、`remotePort`、`PUBLIC_URL`；把服务端 `auth.token` 写入 `/mnt/workspace/.frps_token`，权限 600。**token 与密码不要写进文档、脚本或截图** |
| **没有 frps 怎么办** | 改走路线 B（cloudflared Quick Tunnel，域名每次变）或路线 C（本地 VS Code 转发） |
| **ComfyUI 用户名/密码** | 由 `comfy_tunnel.sh` 首次启动自动生成，存 `/mnt/workspace/.comfy_web_pass`；可用环境变量 `COMFY_WEB_USER` 改用户名 |
| **持久卷路径** | 默认 `/mnt/workspace`、`/home`。脚本里全是硬编码，改路径要同步改所有脚本，不建议 |
| **镜像版本** | 若平台模板升级（CANN 9.1 / Python 3.12 / torch 2.10），本手册的依赖锁定与静态 TLS 修复可能不再适用，需重新跑 `precheck` 并逐项验证 |
| **模型与权重** | 67.7GB H3 权重 + 26.6GB 文生图模型共约 95GB，200GiB 数据盘足够；换账号要重新下载（不跨账号共享） |
| **工作流** | 从 `CANNLab_H3_Replication_Kit.zip` 本地上传；`ready/` 里的 checkpoint 名与第 10 节下载的文件名一一对应，若改了模型文件名要同步改 JSON |

---

## 附录 A：常用命令速查

```bash
# —— 部署 ——
cd /mnt/workspace
bash deploy-h3-cannlab.sh precheck|all|models|deps|config|start|smoke|fix

# —— 服务 ——
curl -s http://127.0.0.1:8188/system_stats
curl -s http://127.0.0.1:8191/health
curl -s http://127.0.0.1:8188/queue
tail -f /mnt/workspace/h3-ascend/logs/comfyui.log

# —— 出片 ——
bash /mnt/workspace/gen_video.sh
bash /mnt/workspace/gen_video.sh --prompt "..." --seed 42 --prefix video/demo

# —— 公网入口 ——
bash /mnt/workspace/comfy_tunnel.sh start|stop|status|url|restart
cat /mnt/workspace/COMFY_ACCESS.txt

# —— 自启 ——
bash /mnt/workspace/setup_autostart.sh
bash -l -c true && tail -30 /mnt/workspace/logs/auto_start.log

# —— 文生图模型 ——
bash /mnt/workspace/download_models.sh
cat /mnt/workspace/logs/models_dl.log
```

## 附录 B：参考来源

- 上游项目：`https://github.com/OwenLittleWhite/cannlab-h3-ascend`（MiniMax H3 视频+音频在昇腾的 ComfyUI 适配源码与补丁快照）
- 上游权重/工作流：`https://gitcode.com/Ascend-SACT/MiniMax-H3-Comfy-NPU`
- ComfyUI 官方示例工作流：`https://github.com/comfyanonymous/ComfyUI_examples`
- 平台：`https://gitcode.com/org/cann/cannlab`（用户指南、卡时规则、帮助文档）
- 模型下载镜像：`https://hf-mirror.com`、`https://www.modelscope.cn`；pip 用清华源 `https://pypi.tuna.tsinghua.edu.cn/simple`

---

**最后一句**：这套环境开机就在扣卡时。部署完成后先确认所有文件落在 `/mnt/workspace`，然后去环境页点「关机」；下次要用再启动，自启脚本会把 ComfyUI 和公网入口拉回来。

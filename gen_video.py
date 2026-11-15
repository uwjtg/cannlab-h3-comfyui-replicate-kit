#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MiniMax H3 视频 + 原生音频：一键生成。

改提示词就出片，不需要打开 ComfyUI 网页。
模板: h3-ascend/workflows/h3_larry_v4_6step_2npu.api.json
"""
import argparse
import json
import os
import pathlib
import random
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path('/mnt/workspace/h3-ascend')
TEMPLATE = ROOT / 'workflows/h3_larry_v4_6step_2npu.api.json'
BASE = 'http://127.0.0.1:8188'


def api(path, obj=None, timeout=30):
    data = json.dumps(obj).encode() if obj is not None else None
    headers = {'Content-Type': 'application/json'} if data else {}
    req = urllib.request.Request(BASE + path, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def node_by_class(wf, class_type):
    for k, v in wf.items():
        if v.get('class_type') == class_type:
            return k, v
    return None, None


def main():
    p = argparse.ArgumentParser(description='MiniMax H3 视频+音频生成')
    p.add_argument('--prompt', help='提示词（优先级最高，支持中文）')
    p.add_argument('--prompt-file', default=str(ROOT / 'prompt.txt'),
                   help='提示词文件，默认 h3-ascend/prompt.txt')
    p.add_argument('--seed', type=int, default=int(os.environ.get('SEED', '-1')),
                   help='随机种子，-1 表示每次随机')
    p.add_argument('--width', type=int, default=int(os.environ.get('WIDTH', '736')))
    p.add_argument('--height', type=int, default=int(os.environ.get('HEIGHT', '416')))
    p.add_argument('--length', type=int, default=int(os.environ.get('LENGTH', '124')),
                   help='帧数；24fps 时 124 帧约 5.17 秒')
    p.add_argument('--fps', type=float, default=float(os.environ.get('FPS', '24')))
    p.add_argument('--steps', type=int, default=int(os.environ.get('STEPS', '6')),
                   help='turbo LoRA 固定 6 步，不建议改')
    p.add_argument('--prefix', default=os.environ.get('PREFIX', 'video/my_h3'),
                   help='输出文件名前缀，相对 ComfyUI/output/')
    p.add_argument('--timeout', type=int, default=1800, help='最长等待秒数')
    p.add_argument('--no-wait', action='store_true', help='只提交任务，不等待完成')
    a = p.parse_args()

    if not TEMPLATE.exists():
        sys.exit(f'缺少工作流模板: {TEMPLATE}\n先执行: bash /mnt/workspace/deploy-h3-cannlab.sh config')
    try:
        api('/system_stats', timeout=5)
    except Exception as e:
        sys.exit(f'ComfyUI 未就绪 ({e})\n先执行: bash /mnt/workspace/deploy-h3-cannlab.sh start')

    wf = json.loads(TEMPLATE.read_text(encoding='utf-8'))

    prompt = a.prompt
    if prompt is None:
        pf = pathlib.Path(a.prompt_file)
        if pf.exists():
            prompt = pf.read_text(encoding='utf-8').strip()
    if prompt is None:
        _, n = node_by_class(wf, 'MiniMaxImageToVideo')
        prompt = n['inputs'].get('prompt', '') if n else ''
    if not prompt:
        sys.exit('提示词为空：写 h3-ascend/prompt.txt 或用 --prompt "..."')

    k, n = node_by_class(wf, 'MiniMaxImageToVideo')
    if n:
        n['inputs']['prompt'] = prompt
        n['inputs']['width'] = a.width
        n['inputs']['height'] = a.height
        n['inputs']['length'] = a.length
    k, n = node_by_class(wf, 'CreateVideo')
    if n:
        n['inputs']['fps'] = a.fps
    k, n = node_by_class(wf, 'RandomNoise')
    seed = random.randint(1, 2 ** 31 - 1) if a.seed < 0 else a.seed
    if n:
        n['inputs']['noise_seed'] = seed
    k, n = node_by_class(wf, 'BasicScheduler')
    if n:
        n['inputs']['steps'] = a.steps
    k, n = node_by_class(wf, 'SaveVideo')
    if n:
        n['inputs']['filename_prefix'] = a.prefix

    print(f'提示词  : {prompt[:100]}{"..." if len(prompt) > 100 else ""}')
    print(f'参数    : {a.width}x{a.height} / {a.length}帧 / {a.fps}fps / {a.steps}步 / seed={seed}')
    print(f'输出前缀: ComfyUI/output/{a.prefix}')
    r = api('/prompt', {'prompt': wf})
    pid = r['prompt_id']
    print(f'已提交  : prompt_id = {pid}', flush=True)
    if a.no_wait:
        print('用 curl http://127.0.0.1:8188/history/' + pid + ' 查询结果')
        return 0

    t0 = time.time()
    while time.time() - t0 < a.timeout:
        time.sleep(10)
        try:
            h = api('/history/' + pid, timeout=30)
        except Exception as e:
            print('查询历史失败(重试):', str(e)[:80], flush=True)
            continue
        if pid not in h:
            el = int(time.time() - t0)
            if el % 60 < 11:
                print(f'生成中... 已等待 {el}s', flush=True)
            continue
        rec = h[pid]
        st = rec.get('status', {})
        if st.get('status_str') == 'error' or st.get('completed') is False:
            print('任务失败，消息:', json.dumps(st.get('messages', []), ensure_ascii=False)[:1500])
            return 1
        print(f'完成    : 耗时 {int(time.time() - t0)}s')
        found = False
        for nid, out in (rec.get('outputs') or {}).items():
            for key in ('images', 'videos', 'gifs', 'audio'):
                for item in out.get(key, []) or []:
                    sub = item.get('subfolder', '')
                    fn = item.get('filename', '')
                    full = ROOT / 'ComfyUI/output' / sub / fn
                    print(f'产物    : {full}')
                    if full.exists():
                        print(f'大小    : {full.stat().st_size} 字节')
                    found = True
        if not found:
            print('未解析到产物节点，原始 outputs:',
                  json.dumps(rec.get('outputs'), ensure_ascii=False)[:800])
        return 0
    print(f'等待超过 {a.timeout}s 未完成，查看日志: {ROOT}/logs/comfyui.log')
    return 2


if __name__ == '__main__':
    sys.exit(main())

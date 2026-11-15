"""ComfyUI 认证反向代理：127.0.0.1:8189 -> 127.0.0.1:8188
带 HTTP Basic Auth，并完整转发 ComfyUI 前端所需的 WebSocket (/ws)。
"""
import asyncio
import base64
import hmac
import os
import sys

import aiohttp
from aiohttp import ClientSession, WSMsgType, web

UPSTREAM_HTTP = "http://127.0.0.1:8188"
UPSTREAM_WS = "ws://127.0.0.1:8188"
USER = os.environ.get("COMFY_WEB_USER", "comfy")
PASS = os.environ.get("COMFY_WEB_PASS", "")
SKIP_REQ = {"host", "authorization", "content-length", "connection", "accept-encoding"}
SKIP_RESP = {"content-length", "transfer-encoding", "content-encoding",
             "connection", "keep-alive"}


def authorized(req):
    h = req.headers.get("Authorization", "")
    if not h.lower().startswith("basic "):
        return False
    try:
        raw = base64.b64decode(h[6:].strip()).decode("utf-8")
    except Exception:
        return False
    return hmac.compare_digest(raw, USER + ":" + PASS)


async def http_proxy(req):
    url = UPSTREAM_HTTP + req.path_qs
    body = await req.read()
    fwd = {k: v for k, v in req.headers.items() if k.lower() not in SKIP_REQ}
    timeout = aiohttp.ClientTimeout(total=900)
    async with ClientSession(timeout=timeout) as s:
        async with s.request(req.method, url, headers=fwd, data=body,
                             allow_redirects=False) as r:
            data = await r.read()
            hdrs = {k: v for k, v in r.headers.items() if k.lower() not in SKIP_RESP}
            return web.Response(status=r.status, body=data, headers=hdrs)


async def ws_proxy(req):
    ws = web.WebSocketResponse(heartbeat=None, max_msg_size=0)
    await ws.prepare(req)
    target = UPSTREAM_WS + req.path
    if req.query_string:
        target += "?" + req.query_string
    async with ClientSession() as s:
        try:
            up = await s.ws_connect(target, max_msg_size=0, heartbeat=None)
        except Exception as e:
            await ws.close(message=("upstream error: %s" % e)[:110].encode())
            return ws

        async def client_to_upstream():
            async for m in ws:
                if m.type == WSMsgType.TEXT:
                    await up.send_str(m.data)
                elif m.type == WSMsgType.BINARY:
                    await up.send_bytes(m.data)
                else:
                    break

        async def upstream_to_client():
            async for m in up:
                if m.type == WSMsgType.TEXT:
                    await ws.send_str(m.data)
                elif m.type == WSMsgType.BINARY:
                    await ws.send_bytes(m.data)
                else:
                    break

        tasks = [asyncio.create_task(client_to_upstream()),
                 asyncio.create_task(upstream_to_client())]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for t in tasks:
                t.cancel()
            try:
                await up.close()
            except Exception:
                pass
            try:
                await ws.close()
            except Exception:
                pass
    return ws


async def handle(req):
    if not authorized(req):
        return web.Response(
            status=401, text="Unauthorized",
            headers={"WWW-Authenticate": 'Basic realm="ComfyUI"'})
    if req.headers.get("Upgrade", "").lower() == "websocket":
        return await ws_proxy(req)
    return await http_proxy(req)


def main():
    if not PASS:
        print("COMFY_WEB_PASS is required", file=sys.stderr)
        sys.exit(2)
    app = web.Application(client_max_size=1024 ** 3)
    app.router.add_route("*", "/", handle)
    app.router.add_route("*", "/{tail:.*}", handle)
    print("AUTH_PROXY_READY 127.0.0.1:8189 -> 127.0.0.1:8188 user=%s" % USER,
          flush=True)
    web.run_app(app, host="127.0.0.1", port=8189, access_log=None)


if __name__ == "__main__":
    main()

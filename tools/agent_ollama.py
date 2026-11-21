"""
雁书 · 本地 AI Agent（A2A Server，背后接 Ollama）

用法：
    # 1) 先装 Ollama 并拉模型
    #    ollama pull qwen2.5:3b
    # 2) 启动本 Agent
    python tools/agent_ollama.py
    # 默认监听 127.0.0.1:9999，模型可用 --model 指定

它实现了 A2A 0.3 协议（message/send 与 message/stream），
雁书会通过 /.well-known/agent.json 自动发现它。
"""

import argparse
import json
import re
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

OLLAMA = "http://127.0.0.1:11434"

SYSTEM_PROMPT = (
    "你是「雁书」的本地助手，负责帮助用户理解和整理他们的录音与笔记。"
    "用户的输入可能包含多段带标题的语料，请：\n"
    "1. 提炼核心观点，按重要程度排序\n"
    "2. 指出不同内容之间的共同点与分歧\n"
    "3. 如果提到待办或决定，单独列出\n"
    "要求：用简体中文，条理清晰，不要复述原文，不要编造语料里没有的信息。"
)


def collect_texts(node, out):
    if isinstance(node, dict):
        t = node.get("text")
        if isinstance(t, str) and t.strip():
            out.append(t)
        for v in node.values():
            collect_texts(v, out)
    elif isinstance(node, list):
        for v in node:
            collect_texts(v, out)


def ollama_stream(model, prompt):
    """逐块产出 Ollama 的回复文本"""
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "stream": True,
        "options": {"temperature": 0.3, "num_ctx": 8192},
    }
    req = urllib.request.Request(
        OLLAMA + "/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        for line in resp:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get("message") or {}
            piece = msg.get("content") or ""
            if piece:
                yield piece
            if obj.get("done"):
                break


def ollama_alive():
    try:
        with urllib.request.urlopen(OLLAMA + "/api/tags", timeout=3) as r:
            return r.status == 200
    except Exception:
        return False


def available_models():
    try:
        with urllib.request.urlopen(OLLAMA + "/api/tags", timeout=5) as r:
            data = json.loads(r.read().decode("utf-8"))
        return [m.get("name", "") for m in data.get("models", [])]
    except Exception:
        return []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    model = "qwen2.5:3b"

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if "agent-card.json" in self.path or "agent.json" in self.path:
            self._json(200, self._card())
        elif self.path.startswith("/health"):
            self._json(200, {
                "ok": ollama_alive(),
                "model": self.model,
                "models": available_models(),
            })
        else:
            self._json(404, {"error": "not found"})

    def _card(self):
        return {
            "name": "雁书 Agent",
            "description": "本地运行的 AI 助手，背后接 Ollama，可总结录音与笔记",
            "version": "0.1.0",
            "protocolVersion": "0.3",
            "url": f"http://127.0.0.1:{self.server.server_port}",
            "preferredTransport": "JSONRPC",
            "capabilities": {"streaming": True},
            "defaultInputModes": ["text/plain"],
            "defaultOutputModes": ["text/plain"],
            "skills": [
                {
                    "id": "summarize",
                    "name": "总结语料",
                    "description": "把多段录音或笔记归纳为要点、分歧与待办",
                }
            ],
        }

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode("utf-8", "ignore")
        try:
            req = json.loads(raw)
        except Exception:
            self._json(400, {"error": "invalid json"})
            return

        method = req.get("method", "")
        params = req.get("params") or {}
        message = params.get("message") or {}
        ctx = message.get("contextId") or "ctx-ollama"

        texts = []
        collect_texts(message if message else req, texts)
        prompt = "\n".join(texts).strip()

        if not prompt:
            self._json(200, {
                "jsonrpc": "2.0",
                "id": req.get("id"),
                "error": {"code": -32600, "message": "没有收到内容"},
            })
            return

        if not ollama_alive():
            msg = ("Ollama 没在运行。请先启动 Ollama（开始菜单里打开），"
                   "并确认已拉取模型：" + self.model)
            if method in ("message/stream", "SendStreamingMessage"):
                self._sse_emit(req, msg, done_only=True)
            else:
                self._json(200, {
                    "jsonrpc": "2.0",
                    "id": req.get("id"),
                    "result": {
                        "id": "task-err",
                        "contextId": ctx,
                        "status": {"state": "failed"},
                        "artifacts": [{"parts": [{"type": "text", "text": msg}]}],
                    },
                })
            return

        print(f"[agent] method={method} chars={len(prompt)} model={self.model}", flush=True)

        if method in ("message/stream", "SendStreamingMessage"):
            self._stream(req, prompt, ctx)
        else:
            self._once(req, prompt, ctx)

    def _stream(self, req, prompt, ctx):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        acc = ""
        try:
            for piece in ollama_stream(self.model, prompt):
                acc += piece
                event = {
                    "jsonrpc": "2.0",
                    "id": req.get("id"),
                    "result": {
                        "id": "task-1",
                        "contextId": ctx,
                        "artifact": {"parts": [{"type": "text", "text": acc}]},
                    },
                }
                self.wfile.write(
                    ("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode("utf-8")
                )
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except Exception as e:
            try:
                err = {"error": f"生成失败：{e}"}
                self.wfile.write(
                    ("data: " + json.dumps(err, ensure_ascii=False) + "\n\n").encode("utf-8")
                )
                self.wfile.flush()
            except Exception:
                pass

    def _sse_emit(self, req, text, done_only=False):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.end_headers()
        event = {
            "jsonrpc": "2.0",
            "id": req.get("id"),
            "result": {"artifact": {"parts": [{"type": "text", "text": text}]}},
        }
        self.wfile.write(("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode("utf-8"))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def _once(self, req, prompt, ctx):
        acc = ""
        try:
            for piece in ollama_stream(self.model, prompt):
                acc += piece
        except Exception as e:
            acc = f"生成失败：{e}"
        self._json(200, {
            "jsonrpc": "2.0",
            "id": req.get("id"),
            "result": {
                "id": "task-1",
                "contextId": ctx,
                "status": {"state": "completed"},
                "artifacts": [{"parts": [{"type": "text", "text": acc}]}],
            },
        })

    def log_message(self, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--model", default="qwen2.5:3b")
    args = ap.parse_args()

    if not ollama_alive():
        print("⚠ Ollama 未运行。请先打开 Ollama，或执行 `ollama serve`。", flush=True)
    else:
        models = available_models()
        print(f"Ollama 在线，已有模型：{models or '（空）'}", flush=True)
        if models and not any(m.startswith(args.model.split(':')[0]) for m in models):
            print(f"⚠ 没找到模型 {args.model}，请执行：ollama pull {args.model}", flush=True)

    Handler.model = args.model
    srv = HTTPServer(("127.0.0.1", args.port), Handler)
    print(f"雁书 Agent 运行在 http://127.0.0.1:{args.port}  模型={args.model}", flush=True)
    print(f"Agent Card: http://127.0.0.1:{args.port}/.well-known/agent.json", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

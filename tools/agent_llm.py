"""
雁书 · AI Agent（A2A Server，统一走 OpenAI 兼容接口）

支持这些后端（改 agent_config.json 即可切换）：
  DeepSeek   base_url=https://api.deepseek.com/v1        model=deepseek-chat
  通义千问    base_url=https://dashscope.aliyuncs.com/compatible-mode/v1  model=qwen-plus
  Kimi       base_url=https://api.moonshot.cn/v1         model=moonshot-v1-8k
  OpenAI     base_url=https://api.openai.com/v1          model=gpt-4o-mini
  本地Ollama  base_url=http://127.0.0.1:11434/v1         model=qwen2.5:3b   api_key=ollama

用法：
    1) 编辑 tools/agent_config.json，填 base_url / api_key / model
    2) python tools/agent_llm.py
    3) 雁书会自动发现（127.0.0.1:9999）

它实现了 A2A 0.3 协议（message/send 与 message/stream）。
"""

import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Windows 控制台默认 GBK，遇到非 GBK 字符会直接崩，这里强制 UTF-8
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "agent_config.json")

DEFAULT_CONFIG = {
    "base_url": "https://api.deepseek.com/v1",
    "api_key": "",
    "model": "deepseek-chat",
    "temperature": 0.3,
    "max_tokens": 1200,
    "port": 9999,
}

SYSTEM_PROMPT = (
    "你是「雁书」的本地助手，帮用户理解和整理他们的录音与笔记。"
    "用户输入可能包含多段带【】标题的语料，请：\n"
    "1. 提炼核心观点，按重要程度排序\n"
    "2. 指出不同内容之间的共同点与分歧\n"
    "3. 如果提到待办、决定或时间节点，单独列出\n"
    "要求：用简体中文，条理清晰，直接给结论，不要复述原文，不要编造语料里没有的信息。"
)


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception as e:
            print(f"⚠ 配置文件解析失败：{e}", flush=True)
    cfg["api_key"] = os.environ.get("GAGGLE_LLM_KEY", cfg.get("api_key", ""))
    return cfg


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


def llm_stream(cfg, prompt):
    """向 OpenAI 兼容接口发起流式请求，逐块产出文本"""
    url = cfg["base_url"].rstrip("/") + "/chat/completions"
    payload = {
        "model": cfg["model"],
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "stream": True,
        "temperature": cfg.get("temperature", 0.3),
        "max_tokens": cfg.get("max_tokens", 1200),
    }
    headers = {"Content-Type": "application/json"}
    if cfg.get("api_key"):
        headers["Authorization"] = "Bearer " + cfg["api_key"]

    req = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"), headers=headers
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
                choice = (obj.get("choices") or [{}])[0]
                delta = (choice.get("delta") or {}).get("content") or ""
                if delta:
                    yield delta
            except Exception:
                continue


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    cfg = dict(DEFAULT_CONFIG)

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
                "ok": bool(self.cfg.get("api_key")) or "127.0.0.1" in self.cfg.get("base_url", ""),
                "base_url": self.cfg.get("base_url"),
                "model": self.cfg.get("model"),
                "has_key": bool(self.cfg.get("api_key")),
            })
        else:
            self._json(404, {"error": "not found"})

    def _card(self):
        return {
            "name": "雁书 Agent",
            "description": f"本地代理，背后接 {self.cfg.get('model')}",
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
        ctx = message.get("contextId") or "ctx-llm"

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

        need_key = "127.0.0.1" not in self.cfg.get("base_url", "") and not self.cfg.get("api_key")
        if need_key:
            hint = ("还没配置 API Key。请编辑 tools/agent_config.json，"
                    "填入 base_url 与 api_key（也可以指向本地 Ollama："
                    "http://127.0.0.1:11434/v1）")
            if method in ("message/stream", "SendStreamingMessage"):
                self._sse(req, hint)
            else:
                self._json(200, {
                    "jsonrpc": "2.0", "id": req.get("id"),
                    "result": {"id": "task-x", "contextId": ctx,
                               "status": {"state": "failed"},
                               "artifacts": [{"parts": [{"type": "text", "text": hint}]}]},
                })
            return

        print(f"[agent] method={method} chars={len(prompt)} model={self.cfg.get('model')}", flush=True)

        if method in ("message/stream", "SendStreamingMessage"):
            self._stream(req, prompt, ctx)
        else:
            acc = ""
            try:
                for piece in llm_stream(self.cfg, prompt):
                    acc += piece
            except Exception as e:
                acc = f"生成失败：{e}"
            self._json(200, {
                "jsonrpc": "2.0", "id": req.get("id"),
                "result": {"id": "task-1", "contextId": ctx,
                           "status": {"state": "completed"},
                           "artifacts": [{"parts": [{"type": "text", "text": acc}]}]},
            })

    def _sse(self, req, text):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.end_headers()
        event = {"jsonrpc": "2.0", "id": req.get("id"),
                 "result": {"artifact": {"parts": [{"type": "text", "text": text}]}}}
        self.wfile.write(("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode("utf-8"))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def _stream(self, req, prompt, ctx):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        acc = ""
        try:
            for piece in llm_stream(self.cfg, prompt):
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
            self.close_connection = True
        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8", "ignore")[:200]
            except Exception:
                pass
            self._err(f"接口返回 {e.code}：{body}")
        except Exception as e:
            self._err(f"生成失败：{e}")

    def _err(self, msg):
        try:
            self.wfile.write(
                ("data: " + json.dumps({"error": msg}, ensure_ascii=False) + "\n\n").encode("utf-8")
            )
            self.wfile.flush()
        except Exception:
            pass

    def log_message(self, *args):
        pass


def main():
    cfg = load_config()
    Handler.cfg = cfg

    if not os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(DEFAULT_CONFIG, f, ensure_ascii=False, indent=2)
        print(f"已生成配置模板：{CONFIG_PATH}", flush=True)

    base = cfg.get("base_url", "")
    if "127.0.0.1" not in base and not cfg.get("api_key"):
        print("⚠ 还没填 api_key，Agent 会返回提示而不是真实回答", flush=True)

    port = int(cfg.get("port", 9999))
    # 多线程：一次慢请求（等大模型）不能把整个 Agent 卡死
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    print(f"雁书 Agent 运行在 http://127.0.0.1:{port}", flush=True)
    print(f"  api_key: {'已填写' if cfg.get('api_key') else '未填写'}", flush=True)
    print(f"  后端: {base}  模型: {cfg.get('model')}", flush=True)
    print(f"  Agent Card: http://127.0.0.1:{port}/.well-known/agent.json", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

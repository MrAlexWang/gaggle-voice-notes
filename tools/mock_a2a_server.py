"""
最小可用的 A2A Server（仅用于本地联调，不产出真实智能总结）

用法：
    python tools/mock_a2a_server.py
    # 默认监听 127.0.0.1:9999

验证点：
    1. GET /.well-known/agent-card.json   → 雁书能自动发现这个 Agent
    2. POST / (JSON-RPC message/send)     → 雁书能把语料发过来并收到回复

接入真实 Agent 时，只需替换成本地 Ollama 驱动的服务，雁书端无需改动。
"""

import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 9999

AGENT_CARD = {
    "name": "Mock Agent",
    "description": "本地联调用的 A2A Server（背后没有真实模型）",
    "version": "0.1.0",
    "protocolVersion": "0.3",
    "url": f"http://127.0.0.1:{PORT}",
    "preferredTransport": "JSONRPC",
    "capabilities": {"streaming": False},
    "defaultInputModes": ["text/plain"],
    "defaultOutputModes": ["text/plain"],
    "skills": [
        {"id": "summarize", "name": "总结语料", "description": "把多段文本归纳为要点"},
    ],
}


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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if "agent-card.json" in self.path or "agent.json" in self.path:
            self._send(200, AGENT_CARD)
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode("utf-8", "ignore")
        try:
            req = json.loads(raw)
        except Exception:
            self._send(400, {"error": "invalid json"})
            return

        texts = []
        collect_texts(req, texts)
        corpus = "\n".join(texts)
        method = req.get("method", "")

        print(f"[mock] method={method} chars={len(corpus)}", flush=True)

        reply = (
            "【Mock Agent】已收到内容（共 %d 字）。\n\n"
            "这是一条联调回复，说明 A2A 链路已经打通：\n"
            "1. 雁书读取了 Agent Card\n"
            "2. 雁书把选中的语料发到了本地 Agent\n"
            "3. Agent 的回复成功回到对话面板\n\n"
            "把 mock 换成本地 Ollama 驱动的 A2A Server，就能得到真实总结。\n\n"
            "你发来的开头是：%s" % (len(corpus), corpus[:60].replace("\n", " "))
        )

        params = req.get("params") or {}
        message = params.get("message") or {}
        ctx = message.get("contextId") or "ctx-mock"

        # 流式：按词逐步发送全量快照，模拟真实 Agent 的增量输出
        if method in ("message/stream", "SendStreamingMessage"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            acc = ""
            # 按 2~3 个字符切块，让前端能看到逐字效果
            step = 4
            for i in range(0, len(reply), step):
                acc = reply[: i + step]
                event = {
                    "jsonrpc": "2.0",
                    "id": req.get("id"),
                    "result": {
                        "artifact": {
                            "parts": [{"type": "text", "text": acc}]
                        }
                    },
                }
                line = "data: " + json.dumps(event, ensure_ascii=False) + "\n\n"
                try:
                    self.wfile.write(line.encode("utf-8"))
                    self.wfile.flush()
                except Exception:
                    return
                time.sleep(0.02)
            try:
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except Exception:
                pass
            return

        result = {
            "id": "task-mock-1",
            "contextId": ctx,
            "status": {"state": "completed"},
            "artifacts": [{"parts": [{"type": "text", "text": reply}]}],
        }
        self._send(200, {"jsonrpc": "2.0", "id": req.get("id"), "result": result})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"Mock A2A Server 运行在 http://127.0.0.1:{PORT}")
    print(f"Agent Card: http://127.0.0.1:{PORT}/.well-known/agent-card.json")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

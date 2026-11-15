#!/usr/bin/env python3
"""Mock OpenAI-compatible endpoint for verify.sh (port 8902).

Modes (by request shape):
- GET  /v1/models                  → model list (mock-7b)
- POST /v1/chat/completions
  - messages contain tool role        → final text (tool result consumed)
  - prompt mentions "echo tool"       → shell tool_call (drives the local tool loop)
  - prompt mentions "code"            → python code block (drives TUI tree-sitter highlight test)
  - otherwise                         → plain text PONG
Supports streaming (SSE) and non-streaming.
"""
import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer

TOOLCALL = [{"index": 0, "id": "call_1", "type": "function",
             "function": {"name": "shell",
                          "arguments": json.dumps({"command": "echo hello-from-local-tool"})}}]
FINAL = "Tool ran and printed: hello-from-local-tool"
CODE_BLOCK = "```python\nprint('highlight-check-ok')\n```"

def saw_tool_result(body):
    return any(m.get("role") == "tool" for m in body.get("messages", []))

def wants_tool(body):
    last = next((m for m in reversed(body.get("messages", [])) if m.get("role") == "user"), {})
    return "echo tool" in json.dumps(last.get("content", ""))

def wants_code(body):
    last = next((m for m in reversed(body.get("messages", [])) if m.get("role") == "user"), {})
    return "python code sample" in json.dumps(last.get("content", ""))

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        if self.path.startswith("/v1/models") or self.path.startswith("/models"):
            self._send(200, {"object": "list", "data": [
                {"id": "mock-7b", "object": "model", "owned_by": "local"}]})
        else:
            self._send(404, {"error": "nf"})

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        if "chat/completions" not in self.path:
            self._send(404, {"error": "nf"}); return
        has_tools = bool(body.get("tools"))
        if saw_tool_result(body):
            msg, finish = {"role": "assistant", "content": FINAL}, "stop"
        elif has_tools and wants_tool(body):
            msg, finish = {"role": "assistant", "content": None, "tool_calls": TOOLCALL}, "tool_calls"
        elif wants_code(body):
            msg, finish = {"role": "assistant", "content": CODE_BLOCK}, "stop"
        else:
            msg, finish = {"role": "assistant", "content": "PONG from mock local model"}, "stop"

        if body.get("stream"):
            self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
            if finish == "tool_calls":
                chunks = [{"delta": {"role": "assistant", "tool_calls": TOOLCALL}, "finish_reason": None},
                          {"delta": {}, "finish_reason": "tool_calls"}]
            else:
                chunks = [{"delta": {"role": "assistant", "content": msg["content"]}, "finish_reason": None},
                          {"delta": {}, "finish_reason": "stop"}]
            for c in chunks:
                chunk = {"id": "c1", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": body.get("model", "mock"), "choices": [{"index": 0, **c}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode()); self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            return
        self._send(200, {"id": "chatcmpl-1", "object": "chat.completion", "created": int(time.time()),
                         "model": body.get("model", "mock"),
                         "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
                         "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})

HTTPServer(("127.0.0.1", 8902), H).serve_forever()

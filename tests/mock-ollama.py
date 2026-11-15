#!/usr/bin/env python3
"""Fake Ollama API on port 11434: /api/tags, /api/show, /v1/chat/completions, /v1/models."""
import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer

MODELS = [{"name": "qwen3:8b", "model": "qwen3:8b", "modified_at": "2025-01-01T00:00:00Z", "size": 5000000000,
           "digest": "abc123", "details": {"format": "gguf", "family": "qwen3", "parameter_size": "8B",
           "quantization_level": "Q4_K_M"}}]
SHOW = {"capabilities": ["completion", "tools"], "model_info": {"qwen3.context_length": 131072},
        "details": {"family": "qwen3", "format": "gguf", "parameter_size": "8B", "quantization_level": "Q4_K_M"}}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        if self.path == "/api/tags":
            self._send(200, {"models": MODELS})
        elif self.path.startswith("/v1/models"):
            self._send(200, {"object": "list", "data": [{"id": "qwen3:8b", "object": "model"}]})
        else:
            self._send(404, {"error": "nf"})

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/api/show":
            self._send(200, SHOW)
        elif "chat/completions" in self.path:
            if body.get("stream"):
                self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
                for c in [{"id": "c", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"role": "assistant"}}]},
                          {"id": "c", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": "PONG from fake ollama"}}]},
                          {"id": "c", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}]:
                    self.wfile.write(f"data: {json.dumps(c)}\n\n".encode()); self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
                return
            self._send(200, {"id": "chatcmpl-1", "object": "chat.completion", "created": int(time.time()),
                             "model": body.get("model", "qwen3:8b"),
                             "choices": [{"index": 0, "message": {"role": "assistant", "content": "PONG from fake ollama"}, "finish_reason": "stop"}],
                             "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})
        else:
            self._send(404, {"error": "nf"})

HTTPServer(("127.0.0.1", 11434), H).serve_forever()

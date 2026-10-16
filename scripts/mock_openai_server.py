#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""로컬 흐름 검증용 mock OpenAI 호환 서버 (모델·가속기 없음).
/v1/models, /v1/chat/completions, /health 만 제공. --startup-delay 로 '모델 적재 시간'을 흉내낸다."""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8000)
ap.add_argument("--model", default="Llama-3.1-8B-Instruct")
ap.add_argument("--startup-delay", type=float, default=0)
a = ap.parse_args()

READY_AT = time.time() + a.startup_delay


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # 조용히
        print(f"[mock] {self.address_string()} {fmt % args}", flush=True)

    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if time.time() < READY_AT:
            return self._send(503, {"error": "model loading"})
        if self.path.startswith("/v1/models"):
            return self._send(200, {"object": "list", "data": [{"id": a.model, "object": "model", "owned_by": "mock"}]})
        if self.path.startswith("/health"):
            return self._send(200, {"status": "ok"})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if time.time() < READY_AT:
            return self._send(503, {"error": "model loading"})
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        if not self.path.startswith("/v1/chat/completions"):
            return self._send(404, {"error": "not found"})
        q = body.get("messages", [{}])[-1].get("content", "")
        ans = f"[mock answer] 질문 요약: {q[:40]}... (이 응답은 로컬 시뮬레이션입니다)"
        time.sleep(0.02)
        self._send(200, {
            "id": "chatcmpl-mock", "object": "chat.completion", "created": int(time.time()), "model": body.get("model", a.model),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": ans}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": max(1, len(q) // 3), "completion_tokens": max(1, len(ans) // 3), "total_tokens": 0},
        })


print(f"[mock] starting on 0.0.0.0:{a.port} model={a.model} (ready in {a.startup_delay}s)", flush=True)
ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()

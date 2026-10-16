#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TEST ONLY (fake-furiosa-llm 패키지에 포함된 사본) — 시나리오 테스트용 OpenAI 호환 가짜 서버 (시험 당일 사용 안 함).
scripts/mock_openai_server.py 와 같은 API 에 고장 주입 스위치를 더했다 (환경변수):
  STUB_CHAT=ok|badjson|500|empty   chat 응답 형태
  STUB_FAIL_EVERY=k                k 번째 chat 요청마다 500
  STUB_CHAT_DELAY=s                chat 응답 지연(초)"""
import argparse
import itertools
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8000)
ap.add_argument("--model", default="Llama-3.1-8B-Instruct")
ap.add_argument("--startup-delay", type=float, default=0)
a = ap.parse_args()

READY_AT = time.time() + a.startup_delay
MODE = os.environ.get("STUB_CHAT", "ok")
FAIL_EVERY = int(os.environ.get("STUB_FAIL_EVERY", "0") or 0)
DELAY = float(os.environ.get("STUB_CHAT_DELAY", "0.02") or 0)
COUNTER = itertools.count(1)


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[fake] {fmt % args}", flush=True)

    def _send(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if time.time() < READY_AT:
            return self._send(503, {"error": "model loading"})
        if self.path.startswith("/v1/models"):
            return self._send(200, {"object": "list", "data": [{"id": a.model, "object": "model", "owned_by": "stub"}]})
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
        i = next(COUNTER)
        time.sleep(DELAY)
        if FAIL_EVERY and i % FAIL_EVERY == 0:
            return self._send(500, {"error": f"injected failure #{i}"})
        if MODE == "badjson":
            return self._send(200, b"<html>502 Bad Gateway</html>", "text/html")
        if MODE == "500":
            return self._send(500, {"error": "internal error"})
        q = body.get("messages", [{}])[-1].get("content", "")
        ans = "" if MODE == "empty" else f"[stub answer #{i}] {q[:30]}"
        self._send(200, {
            "id": f"chatcmpl-stub-{i}", "object": "chat.completion", "created": int(time.time()),
            "model": body.get("model", a.model),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": ans}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": max(1, len(ans) // 3), "total_tokens": 0},
        })


print(f"[fake] listening 0.0.0.0:{a.port} model={a.model} ready-in={a.startup_delay}s mode={MODE}", flush=True)
ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()

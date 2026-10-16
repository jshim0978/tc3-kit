#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TC3 연속 요청(운영 가능성) 시험 스크립트
- OpenAI 호환 API(/v1/chat/completions)에 N회 순차 요청을 보내 성공률과 응답시간(p50/p95/max)을 집계한다.
- vLLM(1안 L40S)과 furiosa-llm(2안 RNGD) 모두 동일하게 사용 가능.
- 의존성: python3 (3.8+), requests  (pip install requests)

사용 예:
  python3 tc3_soak.py --url http://<VM_IP>:8000 --n 100
  python3 tc3_soak.py --url http://<VM_IP>:8000 --n 100 --model Llama-3.1-8B-Instruct --out tc3_soak_result.csv
"""
import argparse
import csv
import datetime as dt
import json
import math
import statistics
import sys
import time

try:
    import requests
except ImportError:
    sys.exit("requests 모듈이 필요합니다: pip install requests")

TOPICS = ["서울", "부산", "대전", "광주", "인천", "대구", "울산", "세종", "제주", "수원"]


def percentile(sorted_vals, p):
    """nearest-rank 백분위: N=100 → 95번째 값, N=10 → 10번째(최댓값)."""
    if not sorted_vals:
        return float("nan")
    k = max(0, min(len(sorted_vals) - 1, math.ceil(p / 100.0 * len(sorted_vals)) - 1))
    return sorted_vals[k]


def main():
    ap = argparse.ArgumentParser(description="TC3 연속 요청 시험")
    ap.add_argument("--url", required=True, help="서버 주소, 예: http://10.0.0.12:8000")
    ap.add_argument("--model", default="Llama-3.1-8B-Instruct", help="served-model-name")
    ap.add_argument("--n", type=int, default=100, help="요청 횟수 (기본 100)")
    ap.add_argument("--max-tokens", type=int, default=64)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out", default="tc3_soak_result.csv", help="요청별 결과 CSV")
    ap.add_argument("--summary-json", default="", help="요약(JSON) 저장 경로 — 시도마다 새로 씀")
    a = ap.parse_args()
    if a.n < 1:
        sys.exit("--n 은 1 이상이어야 합니다")

    endpoint = a.url.rstrip("/") + "/v1/chat/completions"
    started = dt.datetime.now()
    print(f"# TC3 soak test  start={started:%Y-%m-%d %H:%M:%S}  url={endpoint}  model={a.model}  n={a.n}", flush=True)
    sess = requests.Session()
    if "//127.0.0.1" in endpoint or "//localhost" in endpoint:
        sess.trust_env = False  # 로컬 서버 호출이 http_proxy 로 새지 않도록

    rows, lat, lat_ok, ok = [], [], [], 0
    for i in range(a.n):
        q = f"{TOPICS[i % len(TOPICS)]}의 대표 명소 하나를 한 문장으로 소개해 주세요. (요청 #{i + 1})"
        payload = {
            "model": a.model,
            "temperature": 0,
            "max_tokens": a.max_tokens,
            "messages": [{"role": "user", "content": q}],
        }
        t0 = time.perf_counter()
        status, text, ctoks, err = None, "", 0, ""
        try:
            r = sess.post(endpoint, json=payload, timeout=a.timeout)
            status = r.status_code
            j = r.json()
            text = ((((j.get("choices") or [{}])[0]).get("message") or {}).get("content") or "").strip()
            ctoks = (j.get("usage") or {}).get("completion_tokens") or 0
            if status != 200:
                err = f"HTTP {status}"
        except Exception as e:  # noqa: BLE001
            err = f"{type(e).__name__}: {e}"
        el = time.perf_counter() - t0
        good = (status == 200) and len(text) > 0
        ok += good
        lat.append(el)
        if good:
            lat_ok.append(el)
        rows.append([i + 1, status, "OK" if good else "ERR", f"{el:.3f}", ctoks, text[:60].replace("\n", " "), err])
        print(f"[{i + 1:3d}/{a.n}] {'OK ' if good else 'ERR'} {el:7.3f}s  tokens={ctoks:3d}  {text[:40]!r}{('  ' + err) if err else ''}", flush=True)

    # 응답시간 통계는 성공한 요청 기준 (즉시 실패한 요청이 p50/p95 를 왜곡하지 않도록) — 성공이 없으면 전체
    base = lat_ok if lat_ok else lat
    ls = sorted(base)
    p50, p95, mx, mean = statistics.median(base), percentile(ls, 95), ls[-1], statistics.mean(base)
    finished = dt.datetime.now()
    summary = (
        "\n=== TC3 soak result ===\n"
        f"requests      : {a.n}\n"
        f"success       : {ok}/{a.n} ({100.0 * ok / a.n:.1f}%)\n"
        f"latency p50   : {p50:.3f} s\n"
        f"latency p95   : {p95:.3f} s\n"
        f"latency max   : {mx:.3f} s\n"
        f"latency mean  : {mean:.3f} s\n"
        f"elapsed total : {sum(lat):.1f} s\n"
        f"finished      : {finished:%Y-%m-%d %H:%M:%S}\n"
    )
    print(summary, flush=True)

    with open(a.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["idx", "http_status", "result", "latency_s", "completion_tokens", "response_head", "error"])
        w.writerows(rows)
    print(f"per-request log -> {a.out}", flush=True)
    if a.summary_json:
        with open(a.summary_json, "w", encoding="utf-8") as f:
            json.dump({"n": a.n, "ok": ok, "success_pct": 100.0 * ok / a.n, "p50": p50, "p95": p95, "max": mx,
                       "mean": mean, "elapsed_s": sum(lat), "latency_basis": "success" if lat_ok else "all",
                       "started": f"{started:%Y-%m-%dT%H:%M:%S}", "finished": f"{finished:%Y-%m-%dT%H:%M:%S}"},
                      f, indent=2)
    sys.exit(0 if ok == a.n else 1)


if __name__ == "__main__":
    main()

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
import statistics
import sys
import time

try:
    import requests
except ImportError:
    sys.exit("requests 모듈이 필요합니다: pip install requests")

TOPICS = ["서울", "부산", "대전", "광주", "인천", "대구", "울산", "세종", "제주", "수원"]


def percentile(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = max(0, min(len(sorted_vals) - 1, int(round(p / 100.0 * len(sorted_vals) + 0.5)) - 1))
    return sorted_vals[k]


def main():
    ap = argparse.ArgumentParser(description="TC3 연속 요청 시험")
    ap.add_argument("--url", required=True, help="서버 주소, 예: http://10.0.0.12:8000")
    ap.add_argument("--model", default="Llama-3.1-8B-Instruct", help="served-model-name")
    ap.add_argument("--n", type=int, default=100, help="요청 횟수 (기본 100)")
    ap.add_argument("--max-tokens", type=int, default=64)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out", default="tc3_soak_result.csv", help="요청별 결과 CSV")
    a = ap.parse_args()

    endpoint = a.url.rstrip("/") + "/v1/chat/completions"
    started = dt.datetime.now()
    print(f"# TC3 soak test  start={started:%Y-%m-%d %H:%M:%S}  url={endpoint}  model={a.model}  n={a.n}")

    rows, lat, ok = [], [], 0
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
            r = requests.post(endpoint, json=payload, timeout=a.timeout)
            status = r.status_code
            j = r.json()
            text = j["choices"][0]["message"]["content"].strip()
            ctoks = j.get("usage", {}).get("completion_tokens", 0)
        except Exception as e:  # noqa: BLE001
            err = f"{type(e).__name__}: {e}"
        el = time.perf_counter() - t0
        good = (status == 200) and len(text) > 0
        ok += good
        lat.append(el)
        rows.append([i + 1, status, "OK" if good else "ERR", f"{el:.3f}", ctoks, text[:60].replace("\n", " "), err])
        print(f"[{i + 1:3d}/{a.n}] {'OK ' if good else 'ERR'} {el:7.3f}s  tokens={ctoks:3d}  {text[:40]!r}{('  ' + err) if err else ''}")

    ls = sorted(lat)
    summary = (
        f"\n=== TC3 soak result ===\n"
        f"requests      : {a.n}\n"
        f"success       : {ok}/{a.n} ({100.0 * ok / a.n:.1f}%)\n"
        f"latency p50   : {statistics.median(lat):.3f} s\n"
        f"latency p95   : {percentile(ls, 95):.3f} s\n"
        f"latency max   : {ls[-1]:.3f} s\n"
        f"latency mean  : {statistics.mean(lat):.3f} s\n"
        f"elapsed total : {sum(lat):.1f} s\n"
        f"finished      : {dt.datetime.now():%Y-%m-%d %H:%M:%S}\n"
    )
    print(summary)

    with open(a.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["idx", "http_status", "result", "latency_s", "completion_tokens", "response_head", "error"])
        w.writerows(rows)
    print(f"per-request log -> {a.out}")
    sys.exit(0 if ok == a.n else 1)


if __name__ == "__main__":
    main()

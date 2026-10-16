#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""evidence run 디렉터리의 status.tsv + step 로그 → report.md / summary.json
판정 증빙 4종: (A) 플랫폼 [1~4] (B) 모델 크기 [5] (C) 실행 [6~9] (D) 운영 [10]"""
import argparse
import csv
import glob
import json
import os
import re
import socket
import datetime as dt

ap = argparse.ArgumentParser()
ap.add_argument("run_dir")
ap.add_argument("--backend", default="")
ap.add_argument("--describe", default="")
ap.add_argument("--model", default="")
a = ap.parse_args()

rows = []
with open(os.path.join(a.run_dir, "status.tsv"), encoding="utf-8") as f:
    for r in csv.DictReader(f, delimiter="\t"):
        rows.append(r)
by_step = {int(r["step"]): r for r in rows}

STEP_TITLES = {
    1: "플랫폼 증빙 (하이퍼바이저/flavor/VM 배치) [절차 1~3]",
    4: "가속기 PCI·드라이버·실행환경 확인 [절차 4]",
    5: "모델 파라미터 수 산출 [절차 5]",
    6: "추론 서버 기동·준비 완료·가속기 적재 [절차 6]",
    7: "/v1/models 모델 ID 확인 [절차 7]",
    8: "한국어 고정 프롬프트 추론 [절차 8]",
    9: "영어 고정 프롬프트 추론 [절차 9]",
    10: "연속 요청 시험 (성공률·응답시간) [절차 10]",
    11: "서버 정지·원복 [절차 11]",
}
CRITERIA = {
    "A. 플랫폼 증빙": [1, 4],
    "B. 모델 크기 증빙 (≥ 8B)": [5],
    "C. 실행 증빙": [6, 7, 8, 9],
    "D. 운영 증빙 (연속 100회)": [10],
}


def verdict(steps):
    res = [by_step[s]["result"] for s in steps if s in by_step]
    if not res:
        return "NOT RUN"
    if any(r == "FAIL" for r in res):
        return "FAIL"
    if all(r == "PASS" for r in res):
        return "PASS"
    if any(r == "SIMULATED" for r in res):
        return "SIMULATED"
    if any(r == "MANUAL" for r in res):
        return "PASS (MANUAL 캡처 필요)"
    return "/".join(sorted(set(res)))


# 핵심 수치 추출
total_params = None
for fn in glob.glob(os.path.join(a.run_dir, "step05_model_params.log")):
    m = re.findall(r"total parameters = ([\d,]+)", open(fn, encoding="utf-8").read())
    if m:
        total_params = int(m[-1].replace(",", ""))
soak = {}
for fn in glob.glob(os.path.join(a.run_dir, "step10_soak.log")):
    t = open(fn, encoding="utf-8").read()
    for key, pat in [("success", r"success\s*:\s*(\S+)"), ("p50", r"latency p50\s*:\s*(\S+)"),
                     ("p95", r"latency p95\s*:\s*(\S+)"), ("max", r"latency max\s*:\s*(\S+)")]:
        m = re.findall(pat, t)
        if m:
            soak[key] = m[-1]

simulated = any(r["result"] == "SIMULATED" for r in rows)
overall = "FAIL" if any(r["result"] == "FAIL" for r in rows) else ("SIMULATED" if simulated else "PASS")

lines = []
lines.append(f"# TC3 초거대AI 모델 검증 수 — 수행 결과 ({'로컬 시뮬레이션' if simulated else '시험'})")
lines.append("")
lines.append(f"- 생성: {dt.datetime.now():%Y-%m-%d %H:%M:%S}  host: {socket.gethostname()}")
lines.append(f"- 백엔드: `{a.backend}` — {a.describe}")
lines.append(f"- 모델: {a.model}" + (f" (파라미터 {total_params:,} ≈ {total_params/1e9:.2f}B)" if total_params else ""))
lines.append(f"- 종합: **{overall}**" + ("  ← 로컬 시뮬레이션 결과는 공인시험 증빙으로 사용 불가" if simulated else ""))
lines.append("")
lines.append("## 판정 증빙 4종")
lines.append("")
lines.append("| 증빙 | 단계 | 판정 | 근거 |")
lines.append("|---|---|---|---|")
for name, steps in CRITERIA.items():
    note = "; ".join(f"[{s:02d}] {by_step[s]['note']}" for s in steps if s in by_step and by_step[s]["note"])
    lines.append(f"| {name} | {', '.join(str(s) for s in steps)} | {verdict(steps)} | {note} |")
lines.append("")
if soak:
    lines.append(f"연속 요청: success {soak.get('success','-')}, p50 {soak.get('p50','-')} s, p95 {soak.get('p95','-')} s, max {soak.get('max','-')} s")
    lines.append("")
lines.append("## 단계별 결과")
lines.append("")
lines.append("| 단계 | 내용 | 결과 | 비고 | 시각 |")
lines.append("|---|---|---|---|---|")
for r in sorted(rows, key=lambda x: int(x["step"])):
    s = int(r["step"])
    lines.append(f"| {s:02d} | {STEP_TITLES.get(s, r['name'])} | {r['result']} | {r['note']} | {r['time']} |")
lines.append("")
lines.append("## 증빙 파일")
lines.append("")
for fn in sorted(glob.glob(os.path.join(a.run_dir, "step*"))):
    lines.append(f"- `{os.path.basename(fn)}`")
for extra in ["server.log", "soak_result.csv"]:
    if os.path.exists(os.path.join(a.run_dir, extra)):
        lines.append(f"- `{extra}`")
lines.append("")
lines.append("## 결론")
lines.append("")
if overall == "PASS":
    lines.append(f"시험결과, AI반도체 클라우드 플랫폼 시제품(DUT1) 위에서 실행 및 운영 가능한 오픈소스 초거대 모델 1종({a.model}"
                 + (f", {total_params/1e9:.2f}B" if total_params else "") + ")을 확인함 — 2차년도 목표(1종 이상) 충족.")
elif overall == "SIMULATED":
    lines.append("로컬 시뮬레이션 실행: 절차·스크립트·증빙 생성 흐름이 정상 동작함을 확인. 실제 판정은 DUT1 VM 에서 `furiosa`/`vllm` 백엔드로 재수행.")
else:
    lines.append("일부 단계 실패 — 해당 step 로그를 확인하고 재수행.")

open(os.path.join(a.run_dir, "report.md"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
json.dump({"overall": overall, "simulated": simulated, "backend": a.backend, "model": a.model,
           "total_params": total_params, "soak": soak,
           "criteria": {k: verdict(v) for k, v in CRITERIA.items()},
           "steps": {int(r["step"]): {"name": r["name"], "result": r["result"], "note": r["note"], "time": r["time"]} for r in rows}},
          open(os.path.join(a.run_dir, "summary.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("\n".join(lines[:12]))

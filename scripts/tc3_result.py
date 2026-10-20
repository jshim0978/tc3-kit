#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""시험 결과 저장·확인 — evidence/<run> → RESULT.md (+ SHA256SUMS) 생성 후 출력.

  tc3_result.py RUN_DIR [--backend B --describe D --model M --kit-rev R]          RESULT.md 생성 + 출력
  tc3_result.py RUN_DIR --files                                                   주요 로그를 정해진 순서로 출력
  tc3_result.py RUN_DIR --zip                                                     evidence/<run>.zip (제출용)
  tc3_result.py RUN_DIR --quiet                                                   생성만 (bin/tc3 run 끝에서 사용)
"""
import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import platform
import socket
import sys
import zipfile

ap = argparse.ArgumentParser()
ap.add_argument("run_dir")
ap.add_argument("--backend", default="")
ap.add_argument("--describe", default="")
ap.add_argument("--model", default="")
ap.add_argument("--kit-rev", default="")
ap.add_argument("--files", action="store_true")
ap.add_argument("--only", default="", help="--files 와 함께: 이 이름(glob)의 파일만 출력, 예: step10_soak.log, 'step04_*'")
ap.add_argument("--zip", action="store_true")
ap.add_argument("--quiet", action="store_true")
a = ap.parse_args()
R = os.path.normpath(a.run_dir)
RUN = os.path.basename(R)


def p(*names):
    return os.path.join(R, *names)


def load_json(name):
    try:
        return json.load(open(p(name), encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def read(name):
    try:
        return open(p(name), encoding="utf-8", errors="replace").read()
    except OSError:
        return None


# ---------- --files: 주요 로그를 정해진 순서로 ----------
if a.files:
    import glob
    pats = ["prep_check.log", "step04_*.log", "step05_model_params.log", "step06_serve_log.log", "step06_*status.log",
            "step07_models.log", "step08_chat_ko.log", "step09_chat_en.log", "step10_soak.log", "step11_stop.log", "step11_*status.log",
            "npu_summary.txt", "npu_utilization.txt"]
    order = []
    for pat in pats:
        for fn in sorted(glob.glob(p(pat))):
            if os.path.basename(fn) not in order:
                order.append(os.path.basename(fn))
    if a.only:
        import fnmatch
        order = [n for n in order if fnmatch.fnmatch(n, a.only)]
    shown = 0
    for name in order:
        t = read(name)
        if t is None:
            continue
        if name == "step10_soak.log":   # 100줄 진행 기록 대신 요약 블록 + 한/영 질의응답 표본
            lines = t.splitlines()
            keys = ("requests", "success", "latency", "by language", "elapsed", "finished", "per-request", "answers (full)")
            keep = [ln for ln in lines if ln.startswith("#") or ln.startswith(keys) or " ERR " in ln]
            t = "\n".join(keep[-40:]) + "\n"
            samples = []
            for ln in (read("soak_answers.jsonl") or "").splitlines()[:12]:
                try:
                    j = json.loads(ln)
                except ValueError:
                    continue
                ans = " ".join(str(j.get("answer", "")).split())
                samples.append(f"[{j['idx']:3d}] {j['lang']}·{j['category']}  Q: {j['prompt'][:70]}\n      A: {ans[:110]}")
            if samples:
                t += "\n# 질의응답 표본 (처음 12건, 전문: soak_answers.jsonl)\n" + "\n".join(samples) + "\n"
        print(f"===== {name} =====")
        print(t.rstrip())
        print()
        shown += 1
    if not shown:
        sys.exit(f"표시할 로그가 없습니다: {R}")
    sys.exit(0)

# ---------- --zip ----------
if a.zip:
    out = R + ".zip"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(R):
            for fn in sorted(files):
                full = os.path.join(root, fn)
                z.write(full, os.path.join(RUN, os.path.relpath(full, R)))
    print(f"[tc3] 제출용 압축: {out} ({os.path.getsize(out) / 1e6:.1f} MB)")
    sys.exit(0)

# ---------- RESULT.md ----------
summary = load_json("summary.json") or {}
# 백엔드 설명은 report 때(그 run 을 실제로 돌린 백엔드가) 남긴 값을 우선 — 다른 설정의 셸에서 result 를 실행해도 run 의 백엔드로 표시
_rep = read("report.md") or ""
for _ln in _rep.splitlines():
    if _ln.startswith("- 백엔드: `"):
        _be, _, _desc = _ln[len("- 백엔드: `"):].partition("` — ")
        a.backend, a.describe = _be or a.backend, _desc.strip() or a.describe
        break
if summary.get("model"):
    a.model = summary["model"]
npu = load_json("npu_summary.json")
soak = load_json("soak_summary.json")
prep = load_json("prep_check.json")
status = []
if os.path.exists(p("status.tsv")):
    status = list(csv.DictReader(open(p("status.tsv"), encoding="utf-8"), delimiter="\t"))
timing = []
if os.path.exists(p("run_timing.tsv")):
    timing = list(csv.DictReader(open(p("run_timing.tsv"), encoding="utf-8"), delimiter="\t"))
overall = summary.get("overall") or ("미생성 — bin/tc3 report" if not status else "?")


def md(x):
    return str(x).replace("|", "\\|").replace("\n", " ")


def osname():
    try:
        for ln in open("/etc/os-release", encoding="utf-8"):
            if ln.startswith("PRETTY_NAME="):
                return ln.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.platform()


def tparse(s):
    try:
        return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S%z")
    except (TypeError, ValueError):
        return None


ran = [t for t in timing if t.get("start", "-") != "-"]
t_start = tparse(ran[0]["start"]) if ran else None
t_end = tparse(ran[-1]["end"]) if ran else None
elapsed = ""
if t_start and t_end:
    s = int((t_end - t_start).total_seconds())
    elapsed = f"{s // 60}분 {s % 60:02d}초"

L = []
L.append(f"# TC3 시험 결과 — 초거대AI 모델 추론 서비스 검증 ({RUN})")
L.append("")
L.append("| 항목 | 내용 |")
L.append("|---|---|")
L.append("| 시험항목 | TC3 AI반도체 클라우드 플랫폼(DUT1) 위 오픈소스 초거대 모델 실행·운영 검증 |")
L.append(f"| VM / OS | {socket.gethostname()} / {osname()} (kernel {platform.release()}) |")
L.append(f"| 가속기 백엔드 | {md(a.describe or a.backend)} |")
tp = summary.get("total_params")
L.append(f"| 모델 | {md(a.model or summary.get('model', ''))}" + (f" — 파라미터 {tp:,} ({tp / 1e9:.2f} B)" if tp else "") + " |")
L.append(f"| 키트 | 커밋 {a.kit_rev or '-'} |")
if t_start:
    L.append(f"| 재생 | {t_start:%Y-%m-%d %H:%M:%S} ~ {t_end:%H:%M:%S} (총 {elapsed}) |" if t_end else f"| 재생 시작 | {t_start:%Y-%m-%d %H:%M:%S} |")
if prep:
    L.append(f"| 사전준비 확인 | {prep.get('result')} (문제 {prep.get('bad')}건, 주의 {prep.get('warn')}건) — prep_check.log |")
L.append(f"| 증빙 디렉터리 | evidence/{RUN} |")
L.append("")
L.append(f"## 종합 판정: {overall}" + ("  (로컬 시뮬레이션 — 공인시험 증빙 아님)" if summary.get("simulated") else ""))
L.append("")
crit = summary.get("criteria") or {}
if crit:
    steps = summary.get("steps") or {}
    L.append("| 판정 증빙 | 판정 | 근거 |")
    L.append("|---|---|---|")
    groups = {"A": ["1", "4"], "B": ["5"], "C": ["6", "7", "8", "9"], "D": ["10"]}
    for name, v in crit.items():
        nums = groups.get(name[:1], [])
        note = "; ".join(f"[{int(n):02d}] {steps[n]['note']}" for n in nums if n in steps and steps[n].get("note"))
        L.append(f"| {md(name)} | {v} | {md(note)} |")
    L.append("")
if npu:
    o = npu.get("overall", {})
    L.append("## E. NPU 점유 (참고 — 판정 기준 아님)")
    L.append("")
    txt = read("npu_summary.txt")
    if txt:
        L.append("```")
        L.extend(ln for ln in txt.rstrip().splitlines())
        L.append("```")
    L.append("")
if soak:
    L.append("## 연속 요청 (D)")
    L.append("")
    L.append(f"- 요청 {soak.get('n')}회 · 성공 {soak.get('ok')}회 ({soak.get('success_pct')}%) · "
             f"응답시간 p50 {soak.get('p50', 0):.3f} s · p95 {soak.get('p95', 0):.3f} s · 최대 {soak.get('max', 0):.3f} s")
    L.append("")
if status:
    L.append("## 단계별 결과")
    L.append("")
    tby = {}
    for t in timing:
        tby[t.get("step")] = t
    L.append("| 절차 | 단계 | 결과 | 비고 |")
    L.append("|---|---|---|---|")
    for r in sorted(status, key=lambda x: int(x["step"])):
        L.append(f"| {int(r['step']):02d} | {r['name']} | {r['result']} | {md(r['note'])} |")
    L.append("")
if ran:
    L.append("## 단계별 경과 (재생)")
    L.append("")
    L.append("| 절차 | 단계 | 시작 | 소요(s) | 결과 |")
    L.append("|---|---|---|---|---|")
    for t in timing:
        st = t.get("start", "-")
        L.append(f"| {t.get('step')} | {t.get('phase')} | {st[11:19] if len(st) > 18 else st} | {t.get('seconds')} | {t.get('result')} |")
    L.append("")

# 증빙 파일 목록 (+ SHA256SUMS)
entries = []
for root, _, files in os.walk(R):
    for fn in sorted(files):
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, R).replace(os.sep, "/")
        if rel in ("RESULT.md", "SHA256SUMS", "phase") or rel.startswith("fixture-model/"):
            continue
        h = hashlib.sha256()
        with open(full, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        entries.append((rel, os.path.getsize(full), h.hexdigest()))
entries.sort()
with open(p("SHA256SUMS"), "w", encoding="utf-8") as f:
    for rel, _, hx in entries:
        f.write(f"{hx}  {rel}\n")
L.append(f"## 증빙 파일 ({len(entries)}개, 전체 해시: SHA256SUMS)")
L.append("")
L.append("| 파일 | 크기 | sha256 (앞 16자) |")
L.append("|---|---:|---|")
for rel, size, hx in entries:
    L.append(f"| {rel} | {size:,} | {hx[:16]} |")
L.append("")
L.append("## 결론")
L.append("")
model = a.model or summary.get("model", "")
if overall == "PASS":
    L.append(f"AI반도체 클라우드 플랫폼 시제품(DUT1)의 VM 에서 오픈소스 초거대 모델 {model}" + (f"({tp / 1e9:.2f}B)" if tp else "")
             + " 을 추론 서비스로 실행하고 연속 요청까지 운영됨을 확인함 — 판정 증빙 A~D 충족, 종합 PASS.")
elif overall == "SIMULATED":
    L.append("로컬 시뮬레이션: 절차·스크립트·증빙 흐름이 정상 동작함을 확인. 실제 판정은 DUT1 VM 에서 수행.")
else:
    L.append(f"종합 {overall} — 단계별 결과와 해당 step 로그를 확인 후 재수행 (bin/tc3 run --from <단계>).")
L.append("")
L.append(f"_생성: {dt.datetime.now():%Y-%m-%d %H:%M:%S} · tc3 result_")
open(p("RESULT.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
if not a.quiet:
    print("\n".join(L))
    # 화면 끝 요약 — RESULT.md 가 한 화면보다 길어도 마지막 화면(캡처)에 판정이 보이도록
    print("\n" + "=" * 72)
    print(f"[tc3] 종합 판정: {overall}" + ("  (로컬 시뮬레이션)" if summary.get("simulated") else "") + (f"   · 재생 총 {elapsed}" if elapsed else ""))
    for name, v in crit.items():
        print(f"       {name}: {v}")
    if npu:
        o = npu.get("overall", {})
        print(f"       E. NPU 점유(참고): 평균 {o.get('util_avg')}% / 최대 {o.get('util_max')}% · 메모리 최대 {o.get('mem_max_gib')} GiB"
              + (" [SIMULATED]" if npu.get("simulated") else ""))
    print(f"[tc3] 저장: evidence/{RUN}/RESULT.md  (전체 파일 해시: evidence/{RUN}/SHA256SUMS)")
    print("=" * 72)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""가속기 점유 샘플러 — bin/tc3 run 이 백그라운드로 띄우고, 끝나면 SIGTERM 으로 정리한다.

  tc3_npu_monitor.py --backend furiosa|vllm|cpu --out RUN_DIR [--interval 1] [--inline 5]
  tc3_npu_monitor.py --backend furiosa --once        # 현재 상태를 한 번 표로 (live 패널·점검용)

출력  RUN_DIR/npu_samples.csv  ts,phase,device,util_pct,mem_used_mb,mem_total_mb,power_w,temp_c,source
      RUN_DIR/npu_raw.log      원본 출력 (처음 3회 + 해석 실패할 때마다, 최대 200건) — 실기기 형식 확인용
phase 는 RUN_DIR/phase 파일(run 이 현재 단계명을 써 둠)을 매 샘플마다 읽어 붙인다.

소스
  furiosa  `furiosa-smi status` (Liveness·Memory·Core N: x.xx%) + `furiosa-smi info` (Temp.·Power) 표를 해석.
           (2026.1~2026.4 문서의 표 형식. JSON 출력은 없음. 코어가 쉬면 '-' → 0 % 로 계산)
  vllm     nvidia-smi --query-gpu
  cpu      /proc/stat·/proc/meminfo (mock/llamacpp 로컬 시뮬레이션 — SIMULATED)
샘플 실패는 기록만 하고 계속한다 (모니터 때문에 시험이 멈추지 않도록).
"""
import argparse
import csv
import datetime as dt
import os
import re
import signal
import subprocess
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("--backend", required=True, choices=["furiosa", "vllm", "cpu"])
ap.add_argument("--out", help="run 디렉터리")
ap.add_argument("--interval", type=float, default=1.0)
ap.add_argument("--inline", type=float, default=0, help="N 초마다 화면에 한 줄 요약 (0 = 끔)")
ap.add_argument("--once", action="store_true")
ap.add_argument("--duration", type=float, default=0, help="테스트용: N 초 후 종료")
a = ap.parse_args()

FIELDS = ["ts", "phase", "device", "util_pct", "mem_used_mb", "mem_total_mb", "power_w", "temp_c", "source"]
STOP = False


def on_term(*_):
    global STOP
    STOP = True


signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)


def run(cmd, timeout=5.0):
    p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace")


# ---------- furiosa-smi 표 해석 ----------
def table_blocks(text):
    """'+---' 줄로 나뉜 블록마다 [셀 목록] 줄들을 돌려준다."""
    blocks, cur = [], []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("+"):
            if cur:
                blocks.append(cur)
                cur = []
        elif s.startswith("|"):
            cur.append([c.strip() for c in s.strip().strip("|").split("|")])
    if cur:
        blocks.append(cur)
    return blocks


def table_records(text):
    """헤더(‘Device’ 칸이 있는 블록) 기준으로 블록마다 {열이름: 여러 줄을 이은 값}."""
    blocks = table_blocks(text)
    hi = next((i for i, b in enumerate(blocks) if any(c == "Device" for c in b[0])), None)
    if hi is None:
        return []
    head = blocks[hi][0]
    recs = []
    for b in blocks[hi + 1:]:
        rec = {}
        for i, name in enumerate(head):
            vals = [ln[i] for ln in b if i < len(ln) and ln[i]]
            rec[name] = " ".join(vals)
        if rec.get("Device"):
            recs.append(rec)
    return recs


def to_mb(v, unit):
    v = float(v)
    return round(v * {"GiB": 1024, "GB": 1000, "MiB": 1, "MB": 1, "TiB": 1048576}.get(unit, 1), 1)


def parse_status(text):
    out = {}
    for r in table_records(text):
        dev = r["Device"].split()[0]
        d = {"device": dev}
        mem = re.search(r"([\d.]+)\s*/\s*([\d.]+)\s*(GiB|MiB|GB|MB|TiB)", r.get("Memory", ""))
        if mem:
            d["mem_used_mb"], d["mem_total_mb"] = to_mb(mem.group(1), mem.group(3)), to_mb(mem.group(2), mem.group(3))
        util_col = r.get("Core Utilization", r.get("Utilization", ""))
        cores = re.findall(r"Core\s*\d+\s*:\s*([\d.]+%|-)", util_col)
        if cores:   # 2026.x: 코어별 'Core N: x.xx%' (쉬는 코어는 '-')
            vals = [float(c[:-1]) if c.endswith("%") else 0.0 for c in cores]
            d["util_pct"] = round(sum(vals) / len(vals), 2)
        else:       # 이전 형식: 한 칸에 'x.xx%'
            m = re.search(r"([\d.]+)\s*%", util_col)
            if m:
                d["util_pct"] = float(m.group(1))
        if "util_pct" in d or "mem_used_mb" in d:
            out[dev] = d
    return out


def parse_info(text):
    out = {}
    for r in table_records(text):
        dev = r["Device"].split()[0]
        t = re.search(r"([\d.]+)\s*°?\s*C", r.get("Temp.", r.get("Temp", "")))
        p = re.search(r"([\d.]+)\s*W", r.get("Power", ""))
        out[dev] = {"temp_c": float(t.group(1)) if t else "", "power_w": float(p.group(1)) if p else ""}
    return out


RAW_N = 0


def raw_log(tag, text):
    global RAW_N
    if not a.out or RAW_N >= 200:
        return
    RAW_N += 1
    with open(os.path.join(a.out, "npu_raw.log"), "a", encoding="utf-8") as f:
        f.write(f"===== {dt.datetime.now().isoformat(timespec='seconds')} {tag}\n{text.rstrip()}\n")


N_SAMPLE = 0


def sample_furiosa():
    rc, st = run(["furiosa-smi", "status"])
    devs = parse_status(st) if rc == 0 else {}
    rc2, inf = run(["furiosa-smi", "info"])
    info = parse_info(inf) if rc2 == 0 else {}
    if N_SAMPLE < 3 or not devs:
        raw_log(f"furiosa-smi status (rc={rc}, parsed={len(devs)})", st)
        raw_log(f"furiosa-smi info (rc={rc2}, parsed={len(info)})", inf)
    rows = []
    for dev, d in devs.items():
        d.update(info.get(dev, {}))
        d["source"] = "furiosa-smi"
        rows.append(d)
    return rows


def sample_vllm():
    rc, out = run(["nvidia-smi", "--query-gpu=index,utilization.gpu,memory.used,memory.total,power.draw,temperature.gpu",
                   "--format=csv,noheader,nounits"])
    rows = []
    for line in out.splitlines() if rc == 0 else []:
        p = [x.strip() for x in line.split(",")]
        if len(p) < 6:
            continue
        num = lambda x: float(x) if re.fullmatch(r"[\d.]+", x) else ""   # noqa: E731
        rows.append({"device": f"gpu{p[0]}", "util_pct": num(p[1]), "mem_used_mb": num(p[2]), "mem_total_mb": num(p[3]),
                     "power_w": num(p[4]), "temp_c": num(p[5]), "source": "nvidia-smi"})
    if N_SAMPLE < 3 or not rows:
        raw_log(f"nvidia-smi (rc={rc})", out)
    return rows


_PREV = None


def sample_cpu():
    global _PREV
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    idle, total = v[3] + (v[4] if len(v) > 4 else 0), sum(v)
    util = ""
    if _PREV:
        dt_total, dt_idle = total - _PREV[1], idle - _PREV[0]
        util = round(100.0 * (dt_total - dt_idle) / dt_total, 2) if dt_total > 0 else 0.0
    _PREV = (idle, total)
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, val = line.split(":", 1)
            mem[k] = int(val.split()[0]) / 1024.0
    used = mem.get("MemTotal", 0) - mem.get("MemAvailable", 0)
    return [{"device": "cpu", "util_pct": util, "mem_used_mb": round(used, 1), "mem_total_mb": round(mem.get("MemTotal", 0), 1),
             "power_w": "", "temp_c": "", "source": "proc(SIMULATED)"}]


SAMPLERS = {"furiosa": sample_furiosa, "vllm": sample_vllm, "cpu": sample_cpu}


def phase():
    if not a.out:
        return ""
    try:
        with open(os.path.join(a.out, "phase"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def fmt_row(r):
    u = r.get("util_pct", "")
    s = f"{r['device']:<6} util {u:>6}%" if u != "" else f"{r['device']:<6} util      -"
    if r.get("mem_used_mb", "") != "" and r.get("mem_total_mb"):
        s += f"  mem {r['mem_used_mb'] / 1024:6.2f}/{r['mem_total_mb'] / 1024:.2f} GiB"
    if r.get("power_w", "") != "":
        s += f"  {r['power_w']:6.2f} W"
    if r.get("temp_c", "") != "":
        s += f"  {r['temp_c']:5.1f}°C"
    return s


if a.once:
    sample = SAMPLERS[a.backend]
    if a.backend == "cpu":
        sample()
        time.sleep(0.5)
    rows = sample()
    print(f"TC3 accelerator monitor ({a.backend}) {dt.datetime.now():%H:%M:%S}" + ("  [SIMULATED: CPU]" if a.backend == "cpu" else ""))
    for r in rows:
        print("  " + fmt_row(r))
    if not rows:
        print("  (샘플 없음 — npu_raw.log / furiosa-smi 출력 확인)")
    sys.exit(0 if rows else 1)

if not a.out:
    sys.exit("--out 이 필요합니다")
path = os.path.join(a.out, "npu_samples.csv")
new = not os.path.exists(path)
f = open(path, "a", newline="", encoding="utf-8")
w = csv.DictWriter(f, fieldnames=FIELDS, extrasaction="ignore", lineterminator="\n")
if new:
    w.writeheader()
t_start = time.monotonic()
last_inline = 0.0
fails = 0
warned = False
while not STOP:
    t0 = time.monotonic()
    try:
        rows = SAMPLERS[a.backend]()
    except Exception as e:  # noqa: BLE001 — 어떤 오류도 시험을 멈추지 않게
        rows = []
        raw_log(f"sample error {type(e).__name__}", str(e))
    N_SAMPLE += 1
    ts = dt.datetime.now().isoformat(timespec="milliseconds")
    ph = phase()
    for r in rows:
        r.update({"ts": ts, "phase": ph})
        w.writerow(r)
    f.flush()
    fails = 0 if rows else fails + 1
    if fails >= 10 and not warned:
        print(f"[tc3] WARN NPU 모니터: 연속 {fails}회 샘플 실패 — npu_raw.log 확인 (시험은 계속)", flush=True)
        warned = True
    if a.inline and rows and t0 - last_inline >= a.inline:
        last_inline = t0
        print("  \033[2m▸ NPU " + " | ".join(fmt_row(r) for r in rows) + (f"  [{ph}]" if ph else "") + "\033[0m", flush=True)
    if a.duration and time.monotonic() - t_start >= a.duration:
        break
    rest = a.interval - (time.monotonic() - t0)
    while rest > 0 and not STOP:
        time.sleep(min(rest, 0.2))
        rest = a.interval - (time.monotonic() - t0)
f.close()

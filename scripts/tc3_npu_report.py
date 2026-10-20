#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""npu_samples.csv → npu_summary.json / npu_summary.txt / npu_utilization.png (matplotlib 없으면 npu_utilization.txt ASCII 그래프)

  tc3_npu_report.py RUN_DIR [--backend furiosa] [--simulated]
구간(phase)별 평균·최대 사용률, 메모리 최대, 전력·온도, 샘플 수, 시작·끝을 요약한다. 판정 기준이 아닌 참고 증빙(E).
"""
import argparse
import csv
import datetime as dt
import json
import os
import sys

ap = argparse.ArgumentParser()
ap.add_argument("run_dir")
ap.add_argument("--backend", default="")
ap.add_argument("--simulated", action="store_true")
a = ap.parse_args()
src = os.path.join(a.run_dir, "npu_samples.csv")
if not os.path.exists(src):
    sys.exit(f"샘플 없음: {src}")


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


rows = []
for r in csv.DictReader(open(src, encoding="utf-8")):
    try:
        r["_t"] = dt.datetime.fromisoformat(r["ts"])
    except (KeyError, ValueError):
        continue
    for k in ("util_pct", "mem_used_mb", "mem_total_mb", "power_w", "temp_c"):
        r[k] = num(r.get(k))
    rows.append(r)
if not rows:
    sys.exit("유효한 샘플 없음")
rows.sort(key=lambda r: r["_t"])
devices = sorted({r["device"] for r in rows})
order = []
for r in rows:
    ph = r["phase"] or "-"
    if ph not in order:
        order.append(ph)


def stats(rs):
    u = [r["util_pct"] for r in rs if r["util_pct"] is not None]
    m = [r["mem_used_mb"] for r in rs if r["mem_used_mb"] is not None]
    p = [r["power_w"] for r in rs if r["power_w"] is not None]
    t = [r["temp_c"] for r in rs if r["temp_c"] is not None]
    return {
        "samples": len(rs),
        "start": rs[0]["ts"], "end": rs[-1]["ts"],
        "seconds": round((rs[-1]["_t"] - rs[0]["_t"]).total_seconds(), 1),
        "util_avg": round(sum(u) / len(u), 2) if u else None, "util_max": max(u) if u else None,
        "mem_max_gib": round(max(m) / 1024, 2) if m else None,
        "power_avg_w": round(sum(p) / len(p), 2) if p else None, "power_max_w": max(p) if p else None,
        "temp_max_c": max(t) if t else None,
    }


total_mb = max((r["mem_total_mb"] or 0) for r in rows)
summary = {
    "backend": a.backend, "simulated": bool(a.simulated), "devices": devices,
    "source": sorted({r.get("source", "") for r in rows}),
    "mem_total_gib": round(total_mb / 1024, 2) if total_mb else None,
    "overall": stats(rows),
    "phases": [{"phase": ph, **stats([r for r in rows if (r["phase"] or "-") == ph])} for ph in order],
}
json.dump(summary, open(os.path.join(a.run_dir, "npu_summary.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)


def f(v, unit="", nd=1):
    return "-" if v is None else f"{v:.{nd}f}{unit}"


import unicodedata  # noqa: E402


def wid(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in str(s))


def cell(s, w, left=False):   # 터미널 표시 폭 기준 정렬 (한글 2칸)
    s = str(s)
    return s + " " * (w - wid(s)) if left else " " * (w - wid(s)) + s


COLS = [("구간", 12, True), ("시간(s)", 9, False), ("평균 사용률", 13, False), ("최대 사용률", 13, False),
        ("메모리 최대", 13, False), ("평균 전력", 11, False), ("최고 온도", 11, False)]


def row(vals):
    return "  " + "".join(cell(v, w, left) for v, (_, w, left) in zip(vals, COLS))


lines = [f"NPU 점유 요약 (참고 증빙 E) — backend {a.backend or '?'}  장치 {', '.join(devices)}" + ("  [SIMULATED: CPU 사용률로 대체]" if a.simulated else ""),
         f"  기간 {summary['overall']['start'][:19]} ~ {summary['overall']['end'][11:19]}  ({summary['overall']['seconds']} s, 샘플 {summary['overall']['samples']})"
         + (f"  메모리 총량 {summary['mem_total_gib']} GiB" if summary["mem_total_gib"] else ""),
         "",
         row([c[0] for c in COLS])]
for p in summary["phases"] + [{"phase": "전체", **summary["overall"]}]:
    lines.append(row([p["phase"], p["seconds"], f(p["util_avg"], " %"), f(p["util_max"], " %"),
                      f(p["mem_max_gib"], " GiB", 2), f(p["power_avg_w"], " W"), f(p["temp_max_c"], " °C")]))
txt = "\n".join(lines) + "\n"

png = os.path.join(a.run_dir, "npu_utilization.png")
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    t0 = rows[0]["_t"]
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 6.5), sharex=True, gridspec_kw={"height_ratios": [3, 2]})
    for d in devices:
        rs = [r for r in rows if r["device"] == d]
        xs = [(r["_t"] - t0).total_seconds() for r in rs]
        ax1.plot(xs, [r["util_pct"] if r["util_pct"] is not None else float("nan") for r in rs], lw=1.4, label=d)
        ax2.plot(xs, [r["mem_used_mb"] / 1024 if r["mem_used_mb"] is not None else float("nan") for r in rs], lw=1.4, label=d)
    colors = ["#e8eef9", "#f6efe3"]
    for i, ph in enumerate(order):
        rs = [r for r in rows if (r["phase"] or "-") == ph]
        x0, x1 = (rs[0]["_t"] - t0).total_seconds(), (rs[-1]["_t"] - t0).total_seconds()
        for ax in (ax1, ax2):
            ax.axvspan(x0, max(x1, x0 + 0.5), color=colors[i % 2], zorder=0)
        ax1.text((x0 + x1) / 2, 103, ph, ha="center", va="bottom", fontsize=8)
    ax1.set_ylim(0, 110)
    ax1.set_ylabel("utilization (%)" + (" [CPU, simulated]" if a.simulated else ""))
    ax2.set_ylabel("device memory (GiB)" if a.backend != "cpu" else "host memory (GiB)")
    if total_mb:
        ax2.axhline(total_mb / 1024, color="gray", ls="--", lw=0.8)
        ax2.set_ylim(0, total_mb / 1024 * 1.08)
    ax2.set_xlabel("elapsed (s)")
    ax1.legend(loc="upper right", fontsize=8)
    run_id = os.path.basename(os.path.normpath(a.run_dir))
    fig.suptitle(f"TC3 run {run_id} — {a.backend or 'accelerator'} utilization ({', '.join(devices)})", fontsize=11)
    fig.tight_layout()
    fig.savefig(png, dpi=110)
    graph = f"그래프: {png}"
except Exception as e:  # noqa: BLE001 — matplotlib 이 없거나 그리기 실패: ASCII 그래프로 대체
    W, H = 100, 10
    us = [r["util_pct"] or 0.0 for r in rows if r["device"] == devices[0]]
    step = max(1, len(us) / W)
    cols = [max(us[int(i * step):int((i + 1) * step)] or [0.0]) for i in range(min(W, len(us)))]
    art = []
    for lvl in range(H, 0, -1):
        art.append(f"{lvl * 100 // H:>4}% |" + "".join("█" if c >= lvl * 100 / H - 100 / H / 2 else " " for c in cols))
    art.append("      +" + "-" * len(cols))
    ph_line = [" "] * len(cols)
    t0 = rows[0]["_t"]
    tot = max(1e-9, (rows[-1]["_t"] - t0).total_seconds())
    for ph in order:
        rs = [r for r in rows if (r["phase"] or "-") == ph]
        x = int((rs[0]["_t"] - t0).total_seconds() / tot * (len(cols) - 1)) if cols else 0
        for j, ch in enumerate("^" + ph):
            if x + j < len(ph_line):
                ph_line[x + j] = ch
    art.append("       " + "".join(ph_line))
    open(os.path.join(a.run_dir, "npu_utilization.txt"), "w", encoding="utf-8").write(
        f"{devices[0]} 사용률(%) — 시간 →  (matplotlib 없음: {type(e).__name__})\n" + "\n".join(art) + "\n")
    graph = f"그래프: {os.path.join(a.run_dir, 'npu_utilization.txt')} (ASCII — matplotlib 없음)"
txt += "\n  " + graph + "\n"
open(os.path.join(a.run_dir, "npu_summary.txt"), "w", encoding="utf-8").write(txt)
print(txt, end="")

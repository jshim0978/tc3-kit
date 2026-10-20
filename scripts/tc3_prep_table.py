#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""사전준비 확인(preflight) 결과 표 — bin/tc3 preflight 가 점검 행을 stdin 으로 넘긴다.

  행 형식: 결과(ok|bad|warn) \\x1f 항목 \\x1f 기대 \\x1f 실제 \\x1f 조치   (행마다 줄바꿈)
  tc3_prep_table.py --title T --meta M [--color] [--log prep_check.log] [--json prep_check.json] [--key=value ...]
화면과 같은 표를 prep_check.log 에, 행 전체를 prep_check.json 에 남긴다 (증빙 1건).
"""
import argparse
import json
import sys
import unicodedata

ap = argparse.ArgumentParser()
ap.add_argument("--title", default="사전준비 확인")
ap.add_argument("--meta", default="")
ap.add_argument("--color", action="store_true")
ap.add_argument("--log")
ap.add_argument("--json")
ap.add_argument("--info", action="append", default=[], help="json 에 넣을 key=value")
a = ap.parse_args()

rows = []
for line in sys.stdin.read().split("\n"):
    if not line.strip():
        continue
    f = (line.split("\x1f") + [""] * 5)[:5]
    rows.append({"result": f[0], "item": f[1], "expected": f[2], "actual": f[3], "hint": f[4]})


def wid(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def fit(s, w):
    """표시 폭 w 에 맞춰 자르고(…) 채운다."""
    if wid(s) > w:
        out = ""
        for c in s:
            if wid(out + c) > w - 1:
                break
            out += c
        s = out + "…"
    return s + " " * (w - wid(s))


SYM = {"ok": "✓", "bad": "✗", "warn": "!"}
COL = {"ok": "\033[32m", "bad": "\033[31m", "warn": "\033[33m"}
CAP = {"item": 30, "expected": 30, "actual": 52}
W = {k: min(CAP[k], max([wid(h)] + [wid(r[k]) for r in rows])) for k, h in (("item", "항목"), ("expected", "기대"), ("actual", "실제"))}
sep = "+---+" + "+".join("-" * (W[k] + 2) for k in ("item", "expected", "actual")) + "+"


def line(sym, item, exp, act, color=""):
    s = f"| {sym} " + "".join(f"| {fit(v, W[k])} " for k, v in (("item", item), ("expected", exp), ("actual", act))) + "|"
    return s, (s.replace(f"| {sym} ", f"| {color}{sym}\033[0m ", 1) if color else s)


plain, shown = [], []


def emit(p, s=None):
    plain.append(p)
    shown.append(p if s is None else s)


emit(f"[tc3] {a.title}")
if a.meta:
    emit(f"  {a.meta}")
emit(sep)
emit(line(" ", "항목", "기대", "실제")[0])
emit(sep)
for r in rows:
    p, s = line(SYM.get(r["result"], "?"), r["item"], r["expected"], r["actual"], COL.get(r["result"], "") if a.color else "")
    emit(p, s)
emit(sep)
todo = [r for r in rows if r["result"] in ("bad", "warn") and (r["hint"] or wid(r["item"]) > W["item"] or wid(r["actual"]) > W["actual"])]
if todo:
    emit("  확인·조치:")
    for r in todo:
        text = r["item"] + (f" — {r['actual']}" if r["actual"] else "") + (f" → {r['hint']}" if r["hint"] else "")
        p = f"   {SYM[r['result']]} {text}"
        emit(p, p.replace(SYM[r["result"]], COL[r["result"]] + SYM[r["result"]] + "\033[0m", 1) if a.color else p)
n_bad = sum(r["result"] == "bad" for r in rows)
n_warn = sum(r["result"] == "warn" for r in rows)
print("\n".join(shown))
if a.log:
    with open(a.log, "w", encoding="utf-8") as f:
        f.write("\n".join(plain) + "\n")
        f.write(f"결과: {'FAIL' if n_bad else 'PASS'} (문제 {n_bad}건, 주의 {n_warn}건)\n")
if a.json:
    info = dict(kv.split("=", 1) for kv in a.info if "=" in kv)
    json.dump({**info, "result": "FAIL" if n_bad else "PASS", "bad": n_bad, "warn": n_warn, "rows": rows},
              open(a.json, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

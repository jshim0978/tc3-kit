#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""기록된 터미널 세션(.ansi.txt)의 일부 구간을 같은 터미널 창 양식으로 PNG 렌더링 (실제 기록을 자르기만 함).
사용: render_ansi.py <ansi.txt> <out_dir> <name> --title T [--from REGEX] [--to REGEX] [--prompt-line TEXT] [--note TEXT]"""
import argparse, asyncio, html, os, re, time
from ansi2html import Ansi2HTMLConverter

ap = argparse.ArgumentParser()
ap.add_argument("ansi"); ap.add_argument("out_dir"); ap.add_argument("name")
ap.add_argument("--title", required=True); ap.add_argument("--from", dest="frm", default=None); ap.add_argument("--to", default=None)
ap.add_argument("--prompt-line", default=None, help="구간 앞에 붙일 프롬프트 줄(기록의 첫 줄을 그대로 쓰려면 생략)")
ap.add_argument("--note", default="로컬 시뮬레이션(CPU llama.cpp) — 공인시험 증빙 아님 · 원본 기록의 일부 구간")
ap.add_argument("--cols", type=int, default=120)
a = ap.parse_args()

raw = open(a.ansi, encoding="utf-8").read().replace("\x1b]0;TC3SENTINEL", "").replace("]0;TC3SENTINEL", "").replace("\x07", "")
plain = lambda s: re.sub(r"\x1b\[[0-9;]*m", "", s)
lines = raw.split("\n")
first_prompt = lines[0]
start = 0; end = len(lines)
if a.frm:
    for i, ln in enumerate(lines):
        if re.search(a.frm, plain(ln)): start = i; break
if a.to:
    for i in range(start + 1, len(lines)):
        if re.search(a.to, plain(lines[i])): end = i; break
seg = lines[start:end]
# 마지막 프롬프트 줄(원본 마지막 줄) 유지
if end == len(lines) and seg and plain(seg[-1]).strip() == "":
    seg = seg[:-1]
head = [a.prompt_line] if a.prompt_line else ([first_prompt] if start > 0 else [])
body_txt = "\n".join(head + seg)

conv = Ansi2HTMLConverter(dark_bg=True, scheme="xterm", inline=True, linkify=False)
body = conv.convert(body_txt, full=False)
html_doc = f"""<!doctype html><html><head><meta charset="utf-8">
<style>
body{{margin:0;background:#1e1e1e;}}
.win{{width:{a.cols * 8.45 + 40:.0f}px;background:#0c0c0c;border:1px solid #3a3a3a;border-radius:8px;overflow:hidden;font-family:'DejaVu Sans Mono','Noto Sans Mono','Noto Sans CJK KR',monospace;}}
.bar{{background:#2d2d2d;color:#cfcfcf;font:13px 'Noto Sans CJK KR',sans-serif;padding:7px 12px;display:flex;align-items:center;gap:8px;border-bottom:1px solid #3a3a3a}}
.dot{{width:11px;height:11px;border-radius:50%;display:inline-block}}
pre{{margin:0;padding:12px 14px;color:#d4d4d4;font-size:13.5px;line-height:1.38;white-space:pre-wrap;word-break:break-all;font-family:inherit}}
.foot{{background:#2d2d2d;color:#9a9a9a;font:11px 'Noto Sans CJK KR',sans-serif;padding:4px 12px;border-top:1px solid #3a3a3a}}
</style></head><body><div class="win">
<div class="bar"><span class="dot" style="background:#ff5f57"></span><span class="dot" style="background:#febc2e"></span><span class="dot" style="background:#28c840"></span>
<span style="margin-left:8px">{html.escape(a.title)}</span></div>
<pre>{body}</pre>
<div class="foot">{html.escape(a.name)} · {time.strftime('%Y-%m-%d %H:%M:%S %Z')} · {html.escape(a.note)}</div>
</div></body></html>"""
os.makedirs(a.out_dir, exist_ok=True)
hp = os.path.join(a.out_dir, a.name + ".html"); open(hp, "w", encoding="utf-8").write(html_doc)

async def render():
    from playwright.async_api import async_playwright
    async with async_playwright() as p:
        b = await p.chromium.launch(); pg = await b.new_page(device_scale_factor=2)
        await pg.goto("file://" + os.path.abspath(hp)); await pg.wait_for_timeout(300)
        el = await pg.query_selector(".win"); await el.screenshot(path=os.path.join(a.out_dir, a.name + ".png")); await b.close()
asyncio.run(render())
print(f"rendered {a.name}: lines {start}-{end} ({end-start}) -> {a.out_dir}/{a.name}.png")

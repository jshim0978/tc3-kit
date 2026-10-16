#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""실제 터미널 세션(pty)에서 명령을 실행하고, 화면에 표시된 그대로(ANSI 색 포함)를 기록한 뒤 PNG 로 렌더링한다.
사용: term_capture.py <out_dir> <name> <cwd> <command> [--title T] [--cols 120] [--timeout 3600]"""
import argparse, asyncio, html, os, re, sys, time
import pexpect
from ansi2html import Ansi2HTMLConverter

ap = argparse.ArgumentParser()
ap.add_argument("out_dir"); ap.add_argument("name"); ap.add_argument("cwd"); ap.add_argument("command")
ap.add_argument("--title", default=None); ap.add_argument("--cols", type=int, default=120)
ap.add_argument("--timeout", type=int, default=3600); ap.add_argument("--max-lines", type=int, default=90)
ap.add_argument("--env", action="append", default=[])
a = ap.parse_args()
os.makedirs(a.out_dir, exist_ok=True)

env = dict(os.environ); env.update({"GIT_PAGER": "cat", "PAGER": "cat", "TERM": "xterm-256color", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "COLUMNS": str(a.cols), "LINES": "60"})
for kv in a.env:
    k, v = kv.split("=", 1); env[k] = v
PS1 = r"\[\e]0;TC3SENTINEL\a\]\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ "
child = pexpect.spawn("/bin/bash", ["--norc", "--noprofile", "-i"], cwd=a.cwd, env=env, encoding="utf-8", codec_errors="replace",
                      dimensions=(60, a.cols), timeout=a.timeout)
child.setecho(True)
child.expect(r"[#$] ")             # 초기 프롬프트
child.sendline("PS1='" + PS1.replace("TC3SENTINEL", "TC3''SENTINEL") + "'; clear")
child.expect("TC3SENTINEL"); child.expect(r"[#$] ")
prompt_text = child.before.split("\n")[-1] + child.after   # 첫 프롬프트(색 포함) 보존
# 이제부터 기록
buf = [prompt_text]
child.logfile_read = type("L", (), {"write": lambda self, s: buf.append(s), "flush": lambda self: None})()
t0 = time.time()
child.sendline(a.command)
child.expect("TC3SENTINEL", timeout=a.timeout); child.expect(r"[#$] ")   # 명령 종료 후 프롬프트
elapsed = time.time() - t0
child.sendline("exit"); child.close()

raw = "".join(buf)
# 터미널 제어문자 정리 (CR, 커서 이동 등)
raw = raw.replace("\r\r\n", "\n").replace("\r\n", "\n").replace("\r", "\n")
raw = re.sub(r"\x1b\[\?[0-9;]*[hl]", "", raw)           # private modes (bracketed paste, keypad 등)
raw = re.sub(r"\x1b[=>]", "", raw); raw = re.sub(r"\x1b\[K", "", raw); raw = raw.replace("\x1b]0;TC3SENTINEL", "").replace("]0;TC3SENTINEL", "").replace("\x07", "")
raw = re.sub(r"\x1b\][^\x07]*\x07", "", raw)           # OSC titles
raw = re.sub(r"^.*?\x1b\[3J", "", raw, count=1, flags=re.S)  # clear 이전 내용 제거
raw = raw.replace("\x1b[H", "").replace("\x1b[2J", "").replace("\x1b[3J", "")
lines = raw.split("\n")
# 마지막 프롬프트 줄 유지, 너무 길면 중간 생략
if len(lines) > a.max_lines:
    head = lines[: a.max_lines // 2]; tail = lines[-(a.max_lines // 2):]
    lines = head + [f"\x1b[2m... ({len(lines) - a.max_lines} lines omitted) ...\x1b[0m"] + tail
raw = "\n".join(lines)
open(os.path.join(a.out_dir, a.name + ".ansi.txt"), "w", encoding="utf-8").write(raw)

conv = Ansi2HTMLConverter(dark_bg=True, scheme="xterm", inline=True, linkify=False)
body = conv.convert(raw, full=False)
title = a.title or f"터미널 — {a.command}"
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
<span style="margin-left:8px">{html.escape(title)}</span></div>
<pre>{body}</pre>
<div class="foot">{html.escape(a.name)} · 실행 {elapsed:.1f}s · {time.strftime('%Y-%m-%d %H:%M:%S %Z')} · 로컬 시뮬레이션(CPU llama.cpp) — 공인시험 증빙 아님</div>
</div></body></html>"""
hp = os.path.join(a.out_dir, a.name + ".html")
open(hp, "w", encoding="utf-8").write(html_doc)

async def render():
    from playwright.async_api import async_playwright
    async with async_playwright() as p:
        b = await p.chromium.launch(); pg = await b.new_page(device_scale_factor=2)
        await pg.goto("file://" + os.path.abspath(hp)); await pg.wait_for_timeout(300)
        el = await pg.query_selector(".win"); await el.screenshot(path=os.path.join(a.out_dir, a.name + ".png"))
        await b.close()
asyncio.run(render())
print(f"captured {a.name}: {elapsed:.1f}s, {len(lines)} lines -> {a.out_dir}/{a.name}.png")

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tc3 허용 목록 HTTP 프록시 — 인터넷이 없는 VM 이 master3(인터넷 가능)를 통해 설치·다운로드하도록 (표준 라이브러리만, 설치·sudo 불필요).

  python3 tc3-proxy.py --listen 192.168.90.153:3128 --client <VM IP> --log ~/tc3-proxy.log   # Ctrl+C 로 종료
  VM 쪽: tc3.env 에 TC3_PROXY=http://192.168.90.153:3128  (git clone 은 git -c http.proxy=... clone ...)

- HTTPS 는 CONNECT 터널(내용은 암호화된 채 통과, 443 만), HTTP(apt 저장소 등, 80 만)는 그대로 중계한다.
- 허용 목록(--allow, 접미사 일치) 밖의 목적지, --client 밖의 접속은 403. 평문 HTTP 의 Host 헤더는 확인한 호스트로 다시 쓴다. 목적지 이름은 프록시가 풀므로 VM 에 외부 DNS 가 없어도 된다.
- 모든 요청을 한 줄씩 기록(--log). 시험·리허설 동안만 띄우고 끝나면 종료한다.
"""
import argparse
import datetime as dt
import ipaddress
import select
import socket
import socketserver
import sys
import threading
from urllib.parse import urlsplit

DEFAULT_ALLOW = [
    "github.com", "githubusercontent.com",                       # git clone
    "huggingface.co", "hf.co",                                    # HF API·LFS·xet (cdn-lfs*.hf.co, *.xethub.hf.co)
    "pypi.org", "pythonhosted.org",                               # pip / uv
    "pytorch.org",                                                # uv --torch-backend=auto: 인덱스 download.pytorch.org, 휠 download-r2.pytorch.org
    "ubuntu.com",                                                 # apt (archive/security/미러)
    "pkg.dev", "packages.cloud.google.com",                       # Furiosa APT 저장소 + 서명 키
]

ap = argparse.ArgumentParser(description="tc3 allow-list HTTP proxy")
ap.add_argument("--listen", default="127.0.0.1:3128", help="host:port (예: 192.168.90.153:3128)")
ap.add_argument("--allow", action="append", default=None, help="허용 도메인 접미사 (반복 가능, 생략 시 기본 목록)")
ap.add_argument("--allow-extra", action="append", default=[], help="기본 목록에 더할 도메인 접미사 (예: VM 이미지의 apt 미러)")
ap.add_argument("--client", action="append", default=[], help="접속 허용 IP 또는 CIDR (반복 가능, 생략 시 모두 허용 — 경고)")
ap.add_argument("--log", default="-", help="요청 로그 파일 (- = 표준출력)")
ap.add_argument("--timeout", type=float, default=30.0, help="연결 시도·무응답 상한(초)")
a = ap.parse_args()
ALLOW = [d.lower().strip(".") for d in (a.allow or DEFAULT_ALLOW) + a.allow_extra]
CLIENTS = [ipaddress.ip_network(c, strict=False) for c in a.client]
LOG = sys.stdout if a.log == "-" else open(a.log, "a", buffering=1, encoding="utf-8")
LOCK = threading.Lock()


def log(client, verb, target, result):
    with LOCK:
        LOG.write(f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {client} {verb} {target} {result}\n")
        LOG.flush()


def allowed(host):
    h = (host or "").lower().rstrip(".")
    return any(h == d or h.endswith("." + d) for d in ALLOW)


def client_ok(ip):
    if not CLIENTS:
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in n for n in CLIENTS)


def pipe(a_sock, b_sock, idle):
    socks = [a_sock, b_sock]
    while True:
        r, _, x = select.select(socks, [], socks, idle)
        if x or not r:
            return
        for s in r:
            try:
                data = s.recv(65536)
                if not data:
                    return
                (b_sock if s is a_sock else a_sock).sendall(data)
            except OSError:
                return


class Handler(socketserver.StreamRequestHandler):
    rbufsize = 0   # 버퍼 없이 읽어 헤더 뒤 바이트(요청 본문 등)가 파이썬 버퍼에 남아 유실되지 않게
    timeout = a.timeout

    def handle(self):
        client = self.client_address[0]
        if not client_ok(client):
            log(client, "-", "-", "DENY-CLIENT")
            return self.reply(403, "tc3-proxy: client not allowed")
        try:
            line = self.rfile.readline(65537).decode("latin-1").strip()
        except OSError:
            return
        if not line:
            return
        try:
            verb, target, version = line.split(" ", 2)
        except ValueError:
            return self.reply(400, "bad request line")
        headers = []
        while True:
            h = self.rfile.readline(65537)
            if h in (b"\r\n", b"\n", b""):
                break
            headers.append(h)
            if len(headers) > 100:
                return self.reply(431, "too many headers")
        if verb.upper() == "CONNECT":
            host, _, port = target.rpartition(":")
            host = host.strip("[]")
            if port != "443":
                log(client, verb, target, "DENY-PORT")
                return self.reply(403, "tc3-proxy: CONNECT only to port 443")
            if not allowed(host):
                log(client, verb, target, "DENY")
                return self.reply(403, f"tc3-proxy: {host} not in allow-list")
            try:
                up = socket.create_connection((host, 443), timeout=a.timeout)
            except OSError as e:
                log(client, verb, target, f"ERR {e}")
                return self.reply(502, str(e))
            self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            log(client, verb, target, "OK")
            with up:
                pipe(self.connection, up, a.timeout * 4)
            return
        # 평문 HTTP (예: http://archive.ubuntu.com/..., http://asia-northeast3-apt.pkg.dev/...)
        try:
            u = urlsplit(target)
            uport = u.port or 80
        except ValueError:
            return self.reply(400, "bad URL")
        if u.scheme != "http" or not u.hostname:
            return self.reply(400, "absolute http:// URL required")
        if uport != 80:
            log(client, verb, target, "DENY-PORT")
            return self.reply(403, "tc3-proxy: plain HTTP only to port 80")
        if not allowed(u.hostname):
            log(client, verb, target, "DENY")
            return self.reply(403, f"tc3-proxy: {u.hostname} not in allow-list")
        path = (u.path or "/") + (("?" + u.query) if u.query else "")
        try:
            up = socket.create_connection((u.hostname, 80), timeout=a.timeout)
        except OSError as e:
            log(client, verb, target, f"ERR {e}")
            return self.reply(502, str(e))
        # Host 는 허용 목록으로 확인한 URL 의 호스트로 다시 쓴다 (공유 프런트엔드에서 다른 사이트로 새지 않도록)
        drop = (b"proxy-", b"connection", b"keep-alive", b"host:")
        keep = [h for h in headers if not h.lower().startswith(drop)]
        hosthdr = f"Host: {u.hostname}\r\n".encode("latin-1")
        up.sendall(f"{verb} {path} {version}\r\n".encode("latin-1") + hosthdr + b"".join(keep) + b"Connection: close\r\n\r\n")
        log(client, verb, target, "OK")
        with up:
            pipe(self.connection, up, a.timeout * 4)

    def reply(self, code, msg):
        body = (msg + "\n").encode()
        try:
            self.wfile.write(f"HTTP/1.1 {code} tc3-proxy\r\nContent-Type: text/plain\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128   # uv 는 동시에 수십 개 연결을 연다


host, _, port = a.listen.rpartition(":")
srv = Server((host, int(port)), Handler)
print(f"tc3-proxy listening on {host}:{port}  allow={','.join(ALLOW)}  clients={','.join(a.client) or 'ANY'}", flush=True)
if not CLIENTS and host not in ("127.0.0.1", "localhost", "::1"):
    print("  경고: --client 가 없어 이 망의 누구나 프록시를 쓸 수 있음 — --client <VM IP> 권장", flush=True)
try:
    srv.serve_forever()
except KeyboardInterrupt:
    print("tc3-proxy stopped", flush=True)

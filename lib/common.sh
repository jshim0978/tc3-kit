#!/usr/bin/env bash
# tc3-kit 공통 함수 — 로그, 증빙(evidence) 캡처, 상태 기록
# shellcheck disable=SC2034

# ---------- 색상/로그 ----------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_BLUE=$'\e[34m'; C_DIM=$'\e[2m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_RED=""; C_YEL=""; C_BLUE=""; C_DIM=""
fi
log()  { printf '%s[tc3]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[tc3] PASS%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[tc3] WARN%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
fail() { printf '%s[tc3] FAIL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { fail "$*"; exit 1; }
now_iso() { date +%Y-%m-%dT%H:%M:%S%z; }

# ---------- 증빙 디렉터리 ----------
# TC3_RUN_DIR: evidence/<YYYYMMDD-HHMMSS>-<backend>/ (tc3 all 이 한 번 만들고 하위 단계가 공유)
evidence_root() { echo "${TC3_EVIDENCE_DIR:-$TC3_HOME/evidence}"; }
evidence_init() {
  local root; root="$(evidence_root)"
  if [[ -z "${TC3_RUN_DIR:-}" ]]; then
    TC3_RUN_DIR="$root/$(date +%Y%m%d-%H%M%S)-${TC3_BACKEND}"
    export TC3_RUN_DIR
  fi
  # 증빙을 못 남기면 화면에 PASS 가 떠도 무의미 → 즉시 중단
  mkdir -p "$TC3_RUN_DIR" 2>/dev/null && touch "$TC3_RUN_DIR/.w" 2>/dev/null \
    || die "증빙 디렉터리에 쓸 수 없습니다: $TC3_RUN_DIR (권한·디스크 확인)"
  rm -f "$TC3_RUN_DIR/.w"
  # 현재 run 포인터 (단계를 따로따로 실행할 때 같은 run 에 쌓이도록)
  echo "$TC3_RUN_DIR" > "$root/.current_run" || die "run 포인터 기록 실패: $root/.current_run"
  [[ -f "$TC3_RUN_DIR/status.tsv" ]] || printf 'step\tname\tresult\tnote\ttime\n' > "$TC3_RUN_DIR/status.tsv"
}
evidence_resume() {
  # 개별 단계 실행 시: 오늘·같은 백엔드로 만든 최근 run 을 이어서 쓴다. 아니면 새 run.
  #  - 날짜가 다름(리허설 때 남은 run) / 백엔드가 다름(본선→예비 전환) / 다른 위치에서 복사된 포인터 → 새 run
  local root; root="$(evidence_root)"
  if [[ -z "${TC3_RUN_DIR:-}" && -f "$root/.current_run" ]]; then
    local prev base; prev="$(cat "$root/.current_run")"; base="$(basename "$prev")"
    if [[ -d "$prev" && "$prev" == "$root/"* && "$base" == "$(date +%Y%m%d)-"* && "$base" == *"-$TC3_BACKEND" ]]; then
      TC3_RUN_DIR="$prev"; export TC3_RUN_DIR
    else
      warn "이전 run($base)은 오늘·현재 백엔드($TC3_BACKEND)의 run 이 아니므로 새 run 을 시작합니다"
    fi
  fi
  evidence_init
}

# ---------- 단계 캡처 ----------
# capture <step#> <slug> <title> -- <command...>
#  - 명령을 실행하고 stdout/stderr 를 evidence/stepNN_slug.log 에 헤더와 함께 저장
#  - 화면에도 그대로 출력 (시험원이 보는 터미널 화면이 곧 캡처 대상)
#  - 종료코드를 반환 (set -e 영향 받지 않도록 호출측에서 || 처리)
capture() {
  local step="$1" slug="$2" title="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  local f; f="$TC3_RUN_DIR/step$(printf '%02d' "$step")_${slug}.log"
  {
    echo "# TC3 step $(printf '%02d' "$step") — $title"
    echo "# time: $(now_iso)  host: $(hostname)  user: $(id -un)  backend: $TC3_BACKEND"
    echo "# cmd: $*"
    echo "# ----"
  } >> "$f"
  printf '%s%s$ %s%s\n' "$C_DIM" "$C_BOLD" "$*" "$C_RESET"
  local rc=0
  # bash -c 로 실행해 파이프/리다이렉션 포함 명령도 그대로 기록
  bash -o pipefail -c "$*" 2>&1 | tee -a "$f"
  local ps=("${PIPESTATUS[@]}")
  rc=${ps[0]}
  (( ps[1] != 0 )) && warn "증빙 로그 기록 실패: $f"
  echo "# exit: $rc" >> "$f"
  echo >> "$f"
  return "$rc"
}

# record <step#> <name> <PASS|FAIL|SIMULATED|MANUAL|SKIP> [note]
#  - status.tsv: 단계별 마지막 결과 (report 판정 기준)
#  - attempts.tsv: 모든 시도 기록 (재수행 이력 — 지우지 않음)
record() {
  local step="$1" name="$2" result="$3" note="${4:-}"
  note="${note//$'\t'/ }"; note="${note//$'\n'/ }"; note="${note//$'\r'/}"   # TSV 깨짐 방지
  local s t; s="$(printf '%02d' "$step")"; t="$(now_iso)"
  local st="$TC3_RUN_DIR/status.tsv"
  # 같은 step 재실행 시 마지막 결과만 남김 (awk 성공 시에만 교체 — 실패해도 기존 기록 보존)
  if [[ -f "$st" ]]; then
    awk -F'\t' -v s="$s" '$1 != s' "$st" > "$st.tmp" && mv "$st.tmp" "$st"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$name" "$result" "$note" "$t" >> "$st"
  printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$name" "$result" "$note" "$t" >> "$TC3_RUN_DIR/attempts.tsv"
  case "$result" in
    PASS) ok "[step $s] $name ${note:+— $note}" ;;
    SIMULATED|MANUAL|SKIP) warn "[step $s] $name: $result ${note:+— $note}" ;;
    *) fail "[step $s] $name ${note:+— $note}" ;;
  esac
}

# ---------- 유틸 ----------
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 명령이 필요합니다. ($2)"; }
have() { command -v "$1" >/dev/null 2>&1; }

# wait_http <url> <timeout_sec> [pid] : 200 응답까지 대기
#   0 = 준비됨, 1 = 시간 초과, 2 = 서버 프로세스(pid)가 먼저 종료됨 (즉시 실패 처리용)
wait_http() {
  local url="$1" timeout="${2:-300}" pid="${3:-}" t0=$SECONDS el=0 last=0
  while (( el < timeout )); do
    if curl -fsS -m 5 "$url" >/dev/null 2>&1; then return 0; fi
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      curl -fsS -m 5 "$url" >/dev/null 2>&1 && return 0
      return 2
    fi
    sleep 2; el=$((SECONDS - t0))
    if (( el - last >= 30 )); then last=$el; log "서버 준비 대기 중... (${el}s/${timeout}s) $url"; fi
  done
  return 1
}

# wait_down <url> <timeout_sec> : 서버가 완전히 내려갈 때까지 대기 (0 = 내려감)
#   "연결 거부"(curl exit 7) + tc3 가 띄운 프로세스 종료 둘 다 만족해야 함 — 503(종료 중)·응답 지연은 아직 살아 있는 것
wait_down() {
  local url="$1" timeout="${2:-60}" t0=$SECONDS rc
  while (( SECONDS - t0 < timeout )); do
    curl -sS -m 3 -o /dev/null "$url" 2>/dev/null; rc=$?
    if (( rc == 7 )) && ! server_alive; then return 0; fi
    sleep 1
  done
  return 1
}

# port_in_use <port> : 127.0.0.1:<port> 에 누군가 listen 중이면 0
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# port_owner_cmd <port> : 포트를 잡은 프로세스를 보여주는 명령 문자열 (ss/netstat/lsof 중 있는 것)
port_owner_cmd() {
  if have ss; then echo "ss -ltnp 'sport = :$1'"
  elif have netstat; then echo "netstat -ltnp | grep ':$1 '"
  elif have lsof; then echo "lsof -nP -iTCP:$1 -sTCP:LISTEN"
  else echo "echo '127.0.0.1:$1 에 이미 listen 중인 프로세스가 있음 (ss/netstat/lsof 없음)'"; fi
}

# hf_download <repo> <dir> [revision] [pattern...] : huggingface_hub.snapshot_download 로 받는다.
#   CLI 는 버전마다 --include 문법이 달라(1.x 는 패턴마다 --include 반복, 0.x 는 반복 시 덮어씀)
#   "패턴 일부가 조용히 무시되는" 사고가 있어 파이썬 API(allow_patterns)를 쓴다. HF_TOKEN 은 환경변수로 자동 사용.
hf_download() {
  python3 - "$@" <<'PYEOF'
import sys
try:
    from huggingface_hub import snapshot_download
except ImportError:
    sys.exit("huggingface_hub 가 없습니다: python3 -m pip install -U 'huggingface_hub[cli]'")
repo, d, rev, *pats = (sys.argv[1:] + ["", ""])[:max(3, len(sys.argv) - 1)]
p = snapshot_download(repo_id=repo, local_dir=d, revision=rev or None, allow_patterns=pats or None)
print(f"downloaded {repo}{'@' + rev if rev else ''} -> {p}")
PYEOF
}

# hf_pick_tag <repo> <sdk_version> : furiosa-ai 저장소에서 SDK 버전에 맞는 릴리스 태그 선택
#   후보 순서: vX.Y.Z → vX.Y → vX.Y.0 (예: 2026.3.0 → v2026.3, 2025.3.1 → v2025.3.0)
hf_pick_tag() {
  [[ -n "${2:-}" ]] || return 1
  python3 - "$1" "$2" <<'PYEOF'
import re, sys
from huggingface_hub import HfApi
repo, ver = sys.argv[1], sys.argv[2]
m = re.match(r"(\d+)\.(\d+)(?:\.(\d+))?", ver)
if not m:
    sys.exit(1)
ma, mi, pa = m.group(1), m.group(2), m.group(3) or "0"
tags = {t.name for t in HfApi().list_repo_refs(repo).tags}
for c in (f"v{ma}.{mi}.{pa}", f"v{ma}.{mi}", f"v{ma}.{mi}.0"):
    if c in tags:
        print(c); sys.exit(0)
sys.exit(1)
PYEOF
}

# check_weights <dir> : config.json + index 의 모든 shard 가 있는지 확인 (부분 다운로드 감지)
check_weights() {
  python3 - "$1" <<'PYEOF'
import json, os, sys
d = sys.argv[1]
if not os.path.isdir(d):
    sys.exit(f"no such directory: {d}")
miss = [f for f in ("config.json",) if not os.path.exists(os.path.join(d, f))]
idx = os.path.join(d, "model.safetensors.index.json")
if os.path.exists(idx):
    shards = sorted(set(json.load(open(idx, encoding="utf-8"))["weight_map"].values()))
    miss += [s for s in shards if not os.path.exists(os.path.join(d, s))]
elif not any(f.endswith(".safetensors") for f in os.listdir(d)):
    miss.append("*.safetensors")
if miss:
    sys.exit("missing: " + ", ".join(miss))
print(f"weights complete: {d}")
PYEOF
}

# py_deps_install : 증빙 스크립트용 파이썬 패키지 (pip 없으면 설치, PEP 668 환경이면 --break-system-packages)
py_deps_install() {
  local pkgs=(requests safetensors numpy "huggingface_hub[cli]")
  if ! python3 -m pip --version >/dev/null 2>&1; then
    warn "pip 가 없습니다 → python3-pip 설치"
    sudo apt-get update -y && sudo apt-get install -y python3-pip
  fi
  python3 -m pip install --quiet --upgrade "${pkgs[@]}" 2>/dev/null \
    || python3 -m pip install --quiet --upgrade --break-system-packages "${pkgs[@]}"
  if python3 -c 'import requests, safetensors, numpy' 2>/dev/null; then ok "파이썬 패키지 확인 (requests, safetensors, numpy, huggingface_hub)"
  else fail "파이썬 패키지 설치 실패 — python3 -m pip install requests safetensors numpy"; return 1; fi
}

# json_get <jq-filter> : stdin JSON 에서 값 추출 (jq 없으면 python 대체)
json_get() {
  if have jq; then jq -r "$1"; else
    python3 -c 'import sys,json; d=json.load(sys.stdin); f=sys.argv[1]
# 아주 단순한 필터만 지원: .a.b[0].c
cur=d
for part in f.strip(".").replace("[",".").replace("]","").split("."):
    if part=="": continue
    cur = cur[int(part)] if isinstance(cur,list) else cur.get(part)
print(cur if cur is not None else "null")' "$1"
  fi
}

# ---------- 서버 프로세스 관리 ----------
#  - pid 파일은 evidence 루트에 하나 (run 이 바뀌어도 이전 서버를 찾아 정지할 수 있도록)
#  - "pid 시작시각" 을 함께 저장 → 재부팅 등으로 pid 가 재사용돼도 엉뚱한 프로세스를 죽이지 않음
#  - 서버는 setsid 로 별도 프로세스 그룹에서 띄우고, 정지할 때 그룹 전체(워커 포함)를 종료한다
pid_file() { echo "$(evidence_root)/.server.pid"; }
proc_start() { [[ -r "/proc/$1/stat" ]] && sed 's/.*) //' "/proc/$1/stat" | awk '{print $20}'; }
save_pid() { echo "$1 $(proc_start "$1")" > "$(pid_file)"; cp "$(pid_file)" "$TC3_RUN_DIR/server.pid" 2>/dev/null || true; }
server_pid() { local pf; pf="$(pid_file)"; [[ -f "$pf" ]] && awk '{print $1}' "$pf"; }
server_alive() {
  local pf p st; pf="$(pid_file)"; [[ -f "$pf" ]] || return 1
  read -r p st < "$pf"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null || return 1
  [[ -z "$st" || "$(proc_start "$p")" == "$st" ]]
}
# start_bg <logfile> <cmd...> : 새 프로세스 그룹에서 백그라운드 실행, pid 저장
start_bg() {
  local logf="$1"; shift
  if have setsid; then nohup setsid "$@" >> "$logf" 2>&1 < /dev/null &
  else nohup "$@" >> "$logf" 2>&1 < /dev/null & fi
  save_pid $!
}
kill_pid_file() {
  if server_alive; then
    local pid; pid="$(server_pid)"
    local pgid; pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    local target="$pid"
    [[ -n "$pgid" && "$pgid" == "$pid" ]] && target="-$pid"   # 그룹 리더면 그룹 전체(워커 포함)
    kill -TERM -- "$target" 2>/dev/null || true
    local t0=$SECONDS
    while kill -0 "$pid" 2>/dev/null && (( SECONDS - t0 < ${TC3_KILL_GRACE:-20} )); do sleep 0.5; done
    kill -KILL -- "$target" 2>/dev/null || true
  fi
  rm -f "$(pid_file)"
}

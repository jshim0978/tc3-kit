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
evidence_init() {
  local root="${TC3_EVIDENCE_DIR:-$TC3_HOME/evidence}"
  if [[ -z "${TC3_RUN_DIR:-}" ]]; then
    TC3_RUN_DIR="$root/$(date +%Y%m%d-%H%M%S)-${TC3_BACKEND}"
    export TC3_RUN_DIR
  fi
  mkdir -p "$TC3_RUN_DIR"
  # 현재 run 포인터 (단계를 따로따로 실행할 때 같은 run 에 쌓이도록)
  echo "$TC3_RUN_DIR" > "$root/.current_run"
  [[ -f "$TC3_RUN_DIR/status.tsv" ]] || printf 'step\tname\tresult\tnote\ttime\n' > "$TC3_RUN_DIR/status.tsv"
}
evidence_resume() {
  # 개별 단계 실행 시: 최근 run 디렉터리 재사용
  local root="${TC3_EVIDENCE_DIR:-$TC3_HOME/evidence}"
  if [[ -z "${TC3_RUN_DIR:-}" && -f "$root/.current_run" ]]; then
    TC3_RUN_DIR="$(cat "$root/.current_run")"
    export TC3_RUN_DIR
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
  rc=${PIPESTATUS[0]}
  echo "# exit: $rc" >> "$f"
  echo >> "$f"
  return "$rc"
}

# record <step#> <name> <PASS|FAIL|SIMULATED|MANUAL|SKIP> [note]
record() {
  local step="$1" name="$2" result="$3" note="${4:-}"
  # 같은 step 재실행 시 마지막 결과만 남김
  if [[ -f "$TC3_RUN_DIR/status.tsv" ]]; then
    grep -v -P "^$(printf '%02d' "$step")\t" "$TC3_RUN_DIR/status.tsv" > "$TC3_RUN_DIR/status.tsv.tmp" || true
    mv "$TC3_RUN_DIR/status.tsv.tmp" "$TC3_RUN_DIR/status.tsv"
  fi
  printf '%02d\t%s\t%s\t%s\t%s\n' "$step" "$name" "$result" "$note" "$(now_iso)" >> "$TC3_RUN_DIR/status.tsv"
  case "$result" in
    PASS) ok "[step $(printf '%02d' "$step")] $name ${note:+— $note}" ;;
    SIMULATED|MANUAL|SKIP) warn "[step $(printf '%02d' "$step")] $name: $result ${note:+— $note}" ;;
    *) fail "[step $(printf '%02d' "$step")] $name ${note:+— $note}" ;;
  esac
}

# ---------- 유틸 ----------
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 명령이 필요합니다. ($2)"; }
have() { command -v "$1" >/dev/null 2>&1; }

# wait_http <url> <timeout_sec> : 200 응답까지 대기
wait_http() {
  local url="$1" timeout="${2:-300}" t=0
  while (( t < timeout )); do
    if curl -fsS -m 5 "$url" >/dev/null 2>&1; then return 0; fi
    sleep 3; t=$((t+3))
    (( t % 30 == 0 )) && log "서버 준비 대기 중... (${t}s/${timeout}s) $url"
  done
  return 1
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

# pid 파일 기반 백그라운드 프로세스 관리
pid_file() { echo "$TC3_RUN_DIR/server.pid"; }
save_pid() { echo "$1" > "$(pid_file)"; }
kill_pid_file() {
  local pf; pf="$(pid_file)"
  if [[ -f "$pf" ]]; then
    local pid; pid="$(cat "$pf")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true; sleep 2
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
  fi
}

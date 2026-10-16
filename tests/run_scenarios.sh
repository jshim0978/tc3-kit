#!/usr/bin/env bash
# tc3-kit 시나리오 테스트 — 시험 당일과 같은 Ubuntu 22.04 (docker/Dockerfile.tester) 안에서 실행한다.
#   docker compose -f docker/compose.local.yml run --rm --no-deps -T --entrypoint bash tester /kit/tests/run_scenarios.sh [필터]
# 가속기 명령(furiosa-llm, furiosa-smi, lspci, docker, nvidia-smi)은 tests/stubs 의 가짜로 대체해
# furiosa/vllm 백엔드의 스크립트 경로를 하드웨어 없이 끝까지 실행한다. 실제 가중치가 /models 에 있으면 그것을 쓴다.
set -uo pipefail
KIT="${KIT:-/kit}"
TC3="$KIT/bin/tc3"
STUBS="$KIT/tests/stubs"
OUT="${OUT:-/tmp/tc3-scen}"
FILTER="${1:-}"
REAL_MODEL="${REAL_MODEL:-/models/Llama-3.1-8B-Instruct}"
PORT_BASE=18100
mkdir -p "$OUT"
RESULTS=()
# 컨테이너 준비: 가짜 furiosa-llm 의 버전 메타데이터(importlib.metadata 로 읽힘), /kit 저장소 소유자 경고 해제
SP="$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
mkdir -p "$SP/furiosa_llm-2026.4.0.dist-info"
printf 'Metadata-Version: 2.1\nName: furiosa-llm\nVersion: 2026.4.0\n' > "$SP/furiosa_llm-2026.4.0.dist-info/METADATA"
mkdir -p "$SP/furiosa_llm"; echo '__version__ = "2026.4.0"  # tc3 test stub' > "$SP/furiosa_llm/__init__.py"
git config --global --add safe.directory '*' 2>/dev/null
NPASS=0; NFAIL=0; NSKIP=0

# ---------- 공통 ----------
cleanup_procs() {
  pkill -f fake_openai.py 2>/dev/null; pkill -f mock_openai_server.py 2>/dev/null
  pkill -f 'sleep 100000' 2>/dev/null; pkill -f 'http.server' 2>/dev/null
  rm -rf /tmp/tc3-stub-docker; sleep 0.3
}
fresh() { # fresh <name> <backend>
  SC="$1"; SC_DIR="$OUT/$SC"; rm -rf "$SC_DIR"; mkdir -p "$SC_DIR"
  SC_LOG="$SC_DIR/out.log"; : > "$SC_LOG"
  SC_ENV="$SC_DIR/tc3.env"; cp "$KIT/tc3.env.example" "$SC_ENV"      # 당일: cp tc3.env.example tc3.env
  PORT=$((PORT_BASE + ${SC_NUM:-0}))
  export TC3_EVIDENCE_DIR="$SC_DIR/evidence" TC3_BACKEND="$2" TC3_PORT="$PORT" TC3_API_URL="http://127.0.0.1:$PORT"
  export TC3_MODEL_NAME="Llama-3.1-8B-Instruct" TC3_SOAK_N=5 TC3_SOAK_TIMEOUT=10 TC3_READY_TIMEOUT=60
  export TC3_FIXTURE=1 TC3_MOCK_STARTUP_DELAY=1 TC3_MODEL_DIR="$SC_DIR/no-model" TC3_ARTIFACT_DIR="$SC_DIR/artifact"
  export TC3_FURIOSA_LLM_PIN=2026.4.0   # 테스트용 가짜 furiosa-llm 메타데이터 버전과 일치 (tc3.env.example 의 실제 고정값 대신)
  unset TC3_RUN_DIR
  OK=1
}
t() { # t <tc3 args...> : 실행, 출력은 out.log, 종료코드 반환
  echo "\$ tc3 $*" >> "$SC_LOG"
  "$TC3" "$@" --env "$SC_ENV" >> "$SC_LOG" 2>&1
}
run_dir() { cat "$TC3_EVIDENCE_DIR/.current_run" 2>/dev/null; }
st()   { awk -F'\t' -v s="$(printf '%02d' "$1")" '$1==s{print $3}' "$(run_dir)/status.tsv" 2>/dev/null; }
nt()   { awk -F'\t' -v s="$(printf '%02d' "$1")" '$1==s{print $4}' "$(run_dir)/status.tsv" 2>/dev/null; }
rows() { awk -F'\t' -v s="$(printf '%02d' "$1")" '$1==s' "$(run_dir)/status.tsv" 2>/dev/null | wc -l; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
chk() { # chk <설명> <명령...>
  local d="$1"; shift
  if "$@"; then echo "    ok   $d" >> "$SC_LOG"; else echo "    FAIL $d" >> "$SC_LOG"; echo "      ✗ $d"; OK=0; fi
}
is()    { [[ "$1" == "$2" ]] || { echo "        expected [$2] got [$1]" >> "$SC_LOG"; return 1; }; }
has()   { grep -qF -- "$2" "$1" || { echo "        [$2] not found in $1" >> "$SC_LOG"; return 1; }; }
hasnt() { ! grep -qF -- "$2" "$1" || { echo "        [$2] unexpectedly in $1" >> "$SC_LOG"; return 1; }; }
lt()    { (( $1 < $2 )) || { echo "        $1 !< $2" >> "$SC_LOG"; return 1; }; }
noproc() { ! pgrep -f "$1" >/dev/null || { echo "        process [$1] still running: $(pgrep -af "$1" | head -3)" >> "$SC_LOG"; return 1; }; }
closed() { ! port_open "$1" || { echo "        port $1 still open" >> "$SC_LOG"; return 1; }; }
skip()  { echo "    SKIP $*" >> "$SC_LOG"; OK=2; }
make_artifact() {
  mkdir -p "$TC3_ARTIFACT_DIR"; echo '{"model":"Llama-3.1-8B-Instruct","note":"stub artifact"}' > "$TC3_ARTIFACT_DIR/artifact.json"
  echo "stub" > "$TC3_ARTIFACT_DIR/model.fxb"
}
furiosa_env() { export PATH="$STUBS/furiosa:$PATH"; make_artifact; }

# ---------- 시나리오 ----------
sc_mock_all() {
  fresh mock_all mock
  t all; chk "tc3 all exit 0" is $? 0
  chk "04 SIMULATED" is "$(st 4)" SIMULATED; chk "05 SIMULATED (fixture)" is "$(st 5)" SIMULATED
  chk "06 SIMULATED" is "$(st 6)" SIMULATED
  for s in 7 8 9 10 11; do chk "$s PASS" is "$(st $s)" PASS; done
  chk "report overall SIMULATED" has "$(run_dir)/summary.json" '"overall": "SIMULATED"'
  chk "server stopped" closed "$PORT"
}

sc_mock_steps() {
  fresh mock_steps mock
  local rc=0
  for c in env model-size serve verify soak stop report status; do t "$c" || { rc=1; echo "    step $c rc!=0" >> "$SC_LOG"; }; done
  chk "every step exit 0" is "$rc" 0
  chk "one run dir" is "$(find "$TC3_EVIDENCE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" 1
  chk "8 status rows" is "$(($(wc -l < "$(run_dir)/status.tsv") - 1))" 8
}

sc_furiosa_full() {
  fresh furiosa_full furiosa; furiosa_env
  if [[ -f "$REAL_MODEL/config.json" ]]; then export TC3_MODEL_DIR="$REAL_MODEL" TC3_FIXTURE=0; else skip "실제 가중치 없음 ($REAL_MODEL)"; return; fi
  export TC3_SOAK_N=100
  local rc=0
  for c in env model-size serve verify soak stop report; do t "$c" || { rc=1; echo "    step $c rc!=0" >> "$SC_LOG"; }; done
  chk "every step exit 0" is "$rc" 0
  for s in 4 5 6 7 8 9 10 11; do chk "$s PASS" is "$(st $s)" PASS; done
  chk "params 8,030,261,248" has "$(run_dir)/step05_model_params.log" "total parameters = 8,030,261,248"
  chk "report overall PASS" has "$(run_dir)/summary.json" '"overall": "PASS"'
  chk "soak 100/100" has "$(run_dir)/step10_soak.log" "success       : 100/100"
  chk "server cmd logged" has "$(run_dir)/server.log" "furiosa-llm serve"
  chk "--served-model-name passed (SDK>=2026.2)" has "$(run_dir)/server.log" "--served-model-name Llama-3.1-8B-Instruct"
  chk "--devices npu:0" has "$(run_dir)/server.log" "--devices npu:0 "
  chk "NPU ps captured after serve" has "$(run_dir)/step06_npu_status.log" "furiosa-llm serve (stub)"
  chk "kit rev in report" has "$(run_dir)/report.md" "kit: "
  chk "soak_summary.json" has "$(run_dir)/soak_summary.json" '"ok": 100'
  chk "port closed after stop" closed "$PORT"
  chk "no orphan workers" noproc "[f]ake_openai.py --port $PORT"
}

sc_serve_dies_fast() {
  fresh serve_dies_fast furiosa; furiosa_env; export STUB_SERVE_MODE=die TC3_READY_TIMEOUT=120
  local t0=$SECONDS; t serve; local rc=$?
  chk "serve exit != 0" is "$((rc != 0))" 1
  chk "06 FAIL" is "$(st 6)" FAIL
  chk "fails fast (<20s, got $((SECONDS - t0))s)" lt $((SECONDS - t0)) 20
  chk "server error shown in evidence" has "$(run_dir)/step06_serve_log.log" "failed to acquire device"
}

sc_serve_timeout() {
  fresh serve_timeout furiosa; furiosa_env; export STUB_SERVE_MODE=hang TC3_READY_TIMEOUT=9
  local t0=$SECONDS; t serve; local rc=$?
  chk "serve exit != 0" is "$((rc != 0))" 1
  chk "06 FAIL" is "$(st 6)" FAIL
  chk "respects timeout (<25s)" lt $((SECONDS - t0)) 25
  t stop; chk "stop cleans hung server" noproc '[s]leep 100000'
}

sc_serve_twice() {
  fresh serve_twice furiosa; furiosa_env
  t serve; chk "first serve ok" is $? 0
  t serve; chk "second serve ok" is $? 0
  chk "06 PASS" is "$(st 6)" PASS
  chk "single server process" is "$(pgrep -fc "fake_openai.py --port $PORT")" 1
  t verify; chk "verify after double serve" is $? 0
  t stop; chk "stop ok" is $? 0; chk "11 PASS" is "$(st 11)" PASS
  chk "port closed" closed "$PORT"
}

sc_port_foreign() {
  fresh port_foreign furiosa; furiosa_env
  (cd /tmp && exec python3 -m http.server "$PORT" >/dev/null 2>&1) & local fpid=$!
  sleep 1
  local t0=$SECONDS; t serve; local rc=$?
  chk "serve exit != 0" is "$((rc != 0))" 1
  chk "06 FAIL" is "$(st 6)" FAIL
  chk "fails fast (<15s)" lt $((SECONDS - t0)) 15
  chk "port-in-use explained" has "$SC_LOG" "$PORT"
  chk "foreign process untouched" kill -0 "$fpid"
  kill "$fpid" 2>/dev/null
}

sc_wrong_model_name() {
  fresh wrong_model_name furiosa; furiosa_env; export STUB_FORCE_MODEL=meta-llama/whatever
  t serve; t verify; local rc=$?
  chk "verify exit != 0" is "$((rc != 0))" 1
  chk "07 FAIL" is "$(st 7)" FAIL
  chk "07 note shows id" has "$(run_dir)/status.tsv" "meta-llama/whatever"
  t stop
}

sc_bad_json_chat() {
  fresh bad_json_chat furiosa; furiosa_env; export STUB_CHAT=badjson
  t serve; t verify; local rc=$?
  chk "verify exit != 0" is "$((rc != 0))" 1
  chk "08 recorded FAIL" is "$(st 8)" FAIL
  chk "09 recorded FAIL" is "$(st 9)" FAIL
  t stop; t report
  chk "report overall FAIL" has "$(run_dir)/summary.json" '"overall": "FAIL"'
}

sc_empty_answer() {
  fresh empty_answer furiosa; furiosa_env; export STUB_CHAT=empty
  t serve; t verify
  chk "08 FAIL on empty content" is "$(st 8)" FAIL
  t stop
}

sc_soak_flaky() {
  fresh soak_flaky furiosa; furiosa_env; export STUB_FAIL_EVERY=3 TC3_SOAK_N=6
  t serve; t soak; local rc=$?
  chk "soak exit != 0" is "$((rc != 0))" 1
  chk "10 FAIL" is "$(st 10)" FAIL
  chk "note shows 4/6" has "$(run_dir)/status.tsv" "4/6"
  t stop
}

sc_server_dies_midsoak() {
  fresh server_dies_midsoak furiosa; furiosa_env; export TC3_SOAK_N=30 STUB_CHAT_DELAY=0.2 TC3_SOAK_TIMEOUT=3
  t serve
  ( sleep 2; pkill -f "fake_openai.py --port $PORT" ) &
  t soak; local rc=$?
  chk "soak exit != 0" is "$((rc != 0))" 1
  chk "10 FAIL" is "$(st 10)" FAIL
  t stop; chk "stop ok after crash" is $? 0
}

sc_weights_missing() {
  fresh weights_missing furiosa; furiosa_env; export TC3_FIXTURE=0 TC3_MODEL_DIR=/models/does-not-exist
  t model-size; local rc=$?
  chk "model-size exit != 0" is "$((rc != 0))" 1
  chk "05 FAIL" is "$(st 5)" FAIL
  chk "note names the path" has "$(run_dir)/status.tsv" "/models/does-not-exist"
}

sc_params_below_min() {
  fresh params_below_min furiosa; furiosa_env
  python3 "$KIT/scripts/make_fixture_model.py" "$SC_DIR/tiny" >/dev/null
  export TC3_FIXTURE=0 TC3_MODEL_DIR="$SC_DIR/tiny"
  t model-size; chk "model-size exit != 0" is "$(( $? != 0 ))" 1
  chk "05 FAIL" is "$(st 5)" FAIL
}

sc_env_crlf() {
  fresh env_crlf mock
  unset TC3_BACKEND TC3_PORT TC3_API_URL TC3_SOAK_N TC3_MODEL_NAME
  sed -e "s/^TC3_BACKEND=.*/TC3_BACKEND=mock/" -e "s/^TC3_PORT=.*/TC3_PORT=$PORT/" \
      -e "s#^TC3_API_URL=.*#TC3_API_URL=http://127.0.0.1:$PORT  \# trailing comment#" -e "s/^TC3_SOAK_N=.*/TC3_SOAK_N=3/" \
      "$KIT/tc3.env.example" | sed 's/$/\r/' > "$SC_ENV"
  t env; chk "env ok with CRLF tc3.env" is $? 0
  t serve; t verify; chk "verify ok (url/model parsed)" is $? 0
  t soak; chk "soak used N=3" has "$(run_dir)/step10_soak.log" "requests      : 3"
  t stop
}

sc_env_quotes_nonl() {
  fresh env_quotes_nonl mock
  unset TC3_BACKEND TC3_PORT TC3_API_URL TC3_MODEL_NAME
  grep -vE '^(TC3_BACKEND|TC3_PORT|TC3_API_URL|TC3_MODEL_NAME)=' "$KIT/tc3.env.example" > "$SC_ENV"
  printf 'TC3_PORT="%s"\nTC3_API_URL='"'"'http://127.0.0.1:%s'"'"'\nTC3_MODEL_NAME="Llama-3.1-8B-Instruct"\n   \nnot a setting line\nTC3_BACKEND=mock' "$PORT" "$PORT" >> "$SC_ENV"
  t serve; chk "serve ok (quoted values, last line without newline)" is $? 0
  t verify; chk "07 PASS (model name unquoted)" is "$(st 7)" PASS
  t stop
}

sc_symlink_and_cwd() {
  fresh symlink_and_cwd mock
  ln -sf "$TC3" /usr/local/bin/tc3
  (cd / && tc3 env --env "$SC_ENV") >> "$SC_LOG" 2>&1; chk "tc3 via symlink from /" is $? 0
  rm -f /usr/local/bin/tc3
}

sc_no_jq() {
  fresh no_jq mock
  if [[ -x /usr/bin/jq ]]; then mv /usr/bin/jq /usr/bin/jq.off; fi
  t serve; t verify; chk "verify ok without jq" is $? 0
  chk "07 PASS" is "$(st 7)" PASS
  t stop
  [[ -x /usr/bin/jq.off ]] && mv /usr/bin/jq.off /usr/bin/jq
}

sc_lang_c() {
  fresh lang_c mock
  LANG=C LC_ALL=C t all; chk "tc3 all under LANG=C" is $? 0
  chk "korean in report" has "$(run_dir)/report.md" "판정 증빙"
}

sc_rerun_step() {
  fresh rerun_step mock
  t serve; t verify; t verify
  chk "single 07 row" is "$(rows 7)" 1
  chk "single 08 row" is "$(rows 8)" 1
  t stop
}

sc_stale_run() {
  fresh stale_run mock
  local old="$TC3_EVIDENCE_DIR/20250101-000000-mock"; mkdir -p "$old"
  printf 'step\tname\tresult\tnote\ttime\n04\tenv\tFAIL\told\t2025-01-01T00:00:00+0900\n' > "$old/status.tsv"
  echo "$old" > "$TC3_EVIDENCE_DIR/.current_run"
  t env
  chk "new run dir created (not 2025 one)" bash -c "[[ \$(cat '$TC3_EVIDENCE_DIR/.current_run') != '$old' ]]"
  chk "old run untouched" is "$(wc -l < "$old/status.tsv")" 2
}

sc_report_incomplete() {
  fresh report_incomplete mock
  t env; t report; local rc=$?
  chk "overall not PASS/SIMULATED when steps missing" has "$(run_dir)/summary.json" '"overall": "INCOMPLETE"'
  chk "report exit != 0 on INCOMPLETE" is "$((rc != 0))" 1
}

sc_proxy_env() {
  fresh proxy_env furiosa; furiosa_env
  # 죽은 프록시 + no_proxy 미설정: 로컬 API 호출이 프록시로 새면 전부 실패한다
  export http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 no_proxy= NO_PROXY=
  local rc=0
  for c in serve verify soak stop; do t "$c" || rc=1; done
  chk "serve/verify/soak/stop ok behind dead proxy" is "$rc" 0
  for s in 6 7 8 9 10 11; do chk "$s PASS" is "$(st $s)" PASS; done
}

sc_env_bom() {
  fresh env_bom mock
  unset TC3_BACKEND TC3_PORT TC3_API_URL
  { printf '\xef\xbb\xbfTC3_BACKEND=mock\n'; grep -vE '^(TC3_BACKEND|TC3_PORT|TC3_API_URL)=' "$KIT/tc3.env.example"; echo "TC3_PORT=$PORT"; } > "$SC_ENV"
  t env; chk "env ok with BOM-prefixed tc3.env" is $? 0
  chk "backend read as mock" is "$(st 4)" SIMULATED
}

sc_soak_live_output() {
  fresh soak_live_output furiosa; furiosa_env; export TC3_SOAK_N=6 STUB_CHAT_DELAY=1
  t serve
  "$TC3" soak --env "$SC_ENV" > "$SC_DIR/soak_live.txt" 2>&1 & local p=$!
  sleep 3.5
  local n; n="$(grep -cE '^\[ *[0-9]+/6\]' "$SC_DIR/soak_live.txt")"
  chk "soak progress appears live (>=2 lines after 3.5s, got $n)" lt 1 "$n"
  wait "$p"; t stop
}

sc_backend_switch() {
  fresh backend_switch mock
  t env; local r1; r1="$(run_dir)"
  furiosa_env; export TC3_BACKEND=furiosa
  t env
  chk "switching backend starts a new run" bash -c "[[ \$(cat '$TC3_EVIDENCE_DIR/.current_run') != '$r1' ]]"
}

sc_preflight_ok() {
  fresh preflight_ok furiosa; furiosa_env
  if [[ -f "$REAL_MODEL/config.json" ]]; then export TC3_MODEL_DIR="$REAL_MODEL" TC3_FIXTURE=0; else skip "실제 가중치 없음"; return; fi
  t preflight; chk "preflight exit 0 when ready" is $? 0
  chk "no evidence written by preflight" bash -c "[[ ! -d '$TC3_EVIDENCE_DIR' ]] || [[ -z \$(find '$TC3_EVIDENCE_DIR' -name status.tsv) ]]"
}

sc_preflight_bad() {
  fresh preflight_bad furiosa; furiosa_env
  export TC3_FIXTURE=0 TC3_MODEL_DIR=/nope TC3_ARTIFACT_DIR=/nope2 STUB_LSPCI=none
  (cd /tmp && exec python3 -m http.server "$PORT" >/dev/null 2>&1) & local fpid=$!
  sleep 1
  t preflight; chk "preflight exit != 0 when not ready" is "$(( $? != 0 ))" 1
  chk "flags missing NPU" has "$SC_LOG" "1ed2"
  chk "flags missing weights" has "$SC_LOG" "원본 가중치 문제"
  chk "flags busy port" has "$SC_LOG" "포트 $PORT"
  kill "$fpid" 2>/dev/null
}

sc_stop_stubborn() {
  fresh stop_stubborn furiosa; furiosa_env; export STUB_SERVE_MODE=stubborn TC3_KILL_GRACE=3
  t serve
  local t0=$SECONDS; t stop; local rc=$?
  chk "stop exit 0 when server ignores SIGTERM" is "$rc" 0
  chk "11 PASS" is "$(st 11)" PASS
  chk "port closed" closed "$PORT"
  chk "no leftover" noproc "[f]ake_openai.py --port $PORT"
  chk "within grace+margin (<20s)" lt $((SECONDS - t0)) 20
}

sc_old_sdk() {
  fresh old_sdk furiosa; furiosa_env; export TC3_FURIOSA_LLM_VERSION=2025.3.1
  t serve
  chk "no --served-model-name on SDK < 2026.2" hasnt "$(run_dir)/server.log" "--served-model-name"
  chk "warning shown" has "$SC_LOG" "2026.2.0"
  chk "serve warns about id mismatch" has "$SC_LOG" "≠ TC3_MODEL_NAME"
  t stop
  t preflight; chk "preflight FAILS on SDK < 2026.2 (guaranteed 07-10 failure)" is "$(( $? != 0 ))" 1
}

sc_leader_dies() {
  fresh leader_dies furiosa; furiosa_env; export STUB_SERVE_MODE=orphan STUB_DELAY=1
  t serve; chk "serve ok" is $? 0
  sleep 5   # 리더(스텁 bash)는 종료, 워커(가짜 서버)만 남음
  chk "worker still alive (setup)" bash -c "pgrep -f '[f]ake_openai.py --port $PORT' >/dev/null"
  t stop; chk "stop exit 0" is $? 0
  chk "11 PASS" is "$(st 11)" PASS
  chk "orphan worker group killed" noproc "[f]ake_openai.py --port $PORT"
  chk "port closed" closed "$PORT"
}

sc_ver_compare() {
  fresh ver_compare furiosa
  local out
  out="$( (TC3_HOME="$KIT"; source "$KIT/lib/common.sh"; source "$KIT/lib/backend_furiosa.sh"
      for c in "2026.2 2026.2.0 0" "2026.1.9 2026.2.0 1" "2026.10.0 2026.2.0 0" "2026.2.0rc1 2026.2.0 0" \
               "2025.3.1 2025.2.0 0" "2026.4.0.post1 2026.2.0 0" "6.6.87.2 6.3 0" "5.15.0 6.3 1" "2026.2.0 2026.2.0 0"; do
        set -- $c; _ver_ge "$1" "$2"; r=$?; [[ "$r" == "$3" ]] || echo "BAD: _ver_ge $1 $2 -> $r (want $3)"
      done) 2>&1)"
  echo "$out" >> "$SC_LOG"
  chk "_ver_ge edge cases (2026.2 vs 2026.2.0, 2026.10 vs 2026.2, rc/post suffix, kernel)" is "$out" ""
}

sc_report_stale_soak() {
  fresh report_stale_soak mock; export TC3_SOAK_N=3
  t serve; t soak
  chk "first soak PASS 3/3 (setup)" is "$(st 10)" PASS
  TC3_SOAK_N=0 t soak    # 두 번째 시도는 요약 전에 실패 (n<1)
  chk "10 FAIL after crashed retry" is "$(st 10)" FAIL
  t stop; t report
  chk "report shows no numbers from the earlier attempt" hasnt "$(run_dir)/report.md" "success 3/3"
  chk "D label not from the earlier attempt" hasnt "$(run_dir)/report.md" "연속 3회"
  chk "retry history listed" has "$(run_dir)/report.md" "재수행 이력"
}

sc_platform_os_fail() {
  fresh platform_os_fail mock
  mkdir -p "$SC_DIR/bin"; printf '#!/bin/sh\necho "Forbidden (HTTP 403)" >&2\nexit 1\n' > "$SC_DIR/bin/openstack"; chmod +x "$SC_DIR/bin/openstack"
  export PATH="$SC_DIR/bin:$PATH" OS_AUTH_URL=http://keystone.invalid:5000/v3
  t platform; chk "platform exit 0 when openstack query fails" is $? 0
  chk "01 MANUAL (Horizon fallback)" is "$(st 1)" MANUAL
  local rc=0; for c in env model-size serve verify soak stop; do t "$c" || rc=1; done
  t report; chk "report not FAIL because of optional platform step" is $? 0
  chk "overall SIMULATED" has "$(run_dir)/summary.json" '"overall": "SIMULATED"'
}

sc_port_mismatch() {
  fresh port_mismatch mock; export TC3_API_URL="http://127.0.0.1:$((PORT + 1))"
  t env
  chk "warns when API URL port != TC3_PORT" has "$SC_LOG" "TC3_PORT($PORT)"
}

sc_fetch_model_net() {
  fresh fetch_model_net furiosa; furiosa_env
  python3 -c 'import huggingface_hub' 2>/dev/null || python3 -m pip install -q huggingface_hub >/dev/null 2>&1 \
    || { skip "huggingface_hub 설치 불가 (네트워크)"; return; }
  export TC3_HF_REPO_MODEL=hf-internal-testing/tiny-random-LlamaForCausalLM TC3_MODEL_DIR="$SC_DIR/weights"
  export TC3_HF_REPO_ARTIFACT=trl-internal-testing/tiny-LlamaForCausalLM-3.2 TC3_ARTIFACT_DIR="$SC_DIR/art" TC3_HF_ARTIFACT_REVISION=main
  t fetch-model; chk "fetch-model exit 0" is $? 0
  chk "config.json downloaded (include-pattern bug guard)" test -f "$SC_DIR/weights/config.json"
  chk "safetensors downloaded" test -f "$SC_DIR/weights/model.safetensors"
  chk "onnx excluded by patterns" test ! -e "$SC_DIR/weights/onnx"
  chk "artifact full download incl. chat_template.jinja" test -f "$SC_DIR/art/chat_template.jinja"
  chk "artifact source recorded (outside artifact dir)" test -f "$SC_DIR/art.tc3_source"
  chk "artifact dir has no extra tc3 file" test ! -e "$SC_DIR/art/.tc3_source"
  export TC3_HF_ARTIFACT_REVISION=v-other
  t fetch-model; chk "refuses to mix a different revision into the same artifact dir" is "$(( $? != 0 ))" 1
  chk "explains the mismatch" has "$SC_LOG" "다른 내용이 있음"
  export TC3_HF_ARTIFACT_REVISION=main
  local tag1 tag2
  tag1="$( (TC3_HOME="$KIT"; source "$KIT/lib/common.sh"; hf_pick_tag furiosa-ai/Llama-3.1-8B-Instruct 2026.3.0) 2>>"$SC_LOG")"
  tag2="$( (TC3_HOME="$KIT"; source "$KIT/lib/common.sh"; hf_pick_tag furiosa-ai/Llama-3.1-8B-Instruct 2025.3.1) 2>>"$SC_LOG")"
  chk "SDK 2026.3.0 → artifact tag v2026.3" is "$tag1" v2026.3
  chk "SDK 2025.3.1 → artifact tag v2025.3.0" is "$tag2" v2025.3.0
}

sc_stop_nothing() {
  fresh stop_nothing furiosa; furiosa_env
  t stop; chk "stop exit 0 with nothing running" is $? 0
  chk "11 PASS" is "$(st 11)" PASS
}

sc_cli_misuse() {
  fresh cli_misuse mock
  "$TC3" --help > "$SC_DIR/help.txt" 2>&1; chk "--help exit 0" is $? 0
  chk "--help has no code lines" hasnt "$SC_DIR/help.txt" "pipefail"
  chk "--help lists preflight" has "$SC_DIR/help.txt" "preflight"
  "$TC3" env --backend >> "$SC_LOG" 2>&1; chk "missing option value exit != 0 (no crash)" is "$(( $? != 0 ))" 1
  t bogus; chk "unknown command exit != 0" is "$(( $? != 0 ))" 1
  t env --bogus; chk "unknown option exit != 0" is "$(( $? != 0 ))" 1
}

sc_platform_manual() {
  fresh platform_manual mock
  t platform; chk "platform exit 0" is $? 0
  chk "01 MANUAL" is "$(st 1)" MANUAL
}

sc_soak_100() {
  fresh soak_100 mock; export TC3_SOAK_N=100
  t serve; t soak; chk "soak 100 exit 0" is $? 0
  chk "100/100" has "$(run_dir)/step10_soak.log" "success       : 100/100"
  t stop
}

sc_lspci_novendor() {
  fresh lspci_novendor furiosa; furiosa_env; export STUB_LSPCI=novendor
  t env; chk "env PASS when pci.ids lacks vendor name" is "$(st 4)" PASS
}

sc_lspci_none() {
  fresh lspci_none furiosa; furiosa_env; export STUB_LSPCI=none
  t env; chk "env exit != 0 without NPU" is "$(( $? != 0 ))" 1
  chk "04 FAIL" is "$(st 4)" FAIL
}

sc_vllm_full() {
  fresh vllm_full vllm; export PATH="$STUBS/vllm:$STUBS/furiosa:$PATH" STUB_LSPCI=nvidia
  python3 "$KIT/scripts/make_fixture_model.py" "$SC_DIR/models/m" >/dev/null
  if [[ -f "$REAL_MODEL/config.json" ]]; then export TC3_MODEL_DIR="$REAL_MODEL" TC3_FIXTURE=0; else export TC3_MODEL_DIR="$SC_DIR/models/m" TC3_MIN_PARAMS=1 TC3_FIXTURE=0; fi
  local rc=0
  for c in env model-size serve verify soak stop report; do t "$c" || { rc=1; echo "    step $c rc!=0" >> "$SC_LOG"; }; done
  chk "every step exit 0" is "$rc" 0
  for s in 4 5 6 7 8 9 10 11; do chk "$s PASS" is "$(st $s)" PASS; done
}

sc_ctrl_c_serve() {
  fresh ctrl_c_serve furiosa; furiosa_env; export STUB_DELAY=6
  # 조작자가 serve 대기 중 터미널을 닫음(SIGHUP) → nohup 서버는 남는다. 다음 serve 가 이를 처리해야 함.
  "$TC3" serve --env "$SC_ENV" >> "$SC_LOG" 2>&1 & local p=$!
  sleep 2; kill -HUP "$p"; wait "$p" 2>/dev/null
  export STUB_DELAY=1
  t serve; chk "serve after interrupted serve" is $? 0
  chk "single server process" is "$(pgrep -fc "fake_openai.py --port $PORT")" 1
  t stop; chk "port closed" closed "$PORT"
}

sc_path_with_spaces() {
  fresh path_with_spaces furiosa; furiosa_env
  python3 "$KIT/scripts/make_fixture_model.py" "$SC_DIR/my models/Llama 8B" >/dev/null
  export TC3_FIXTURE=0 TC3_MODEL_DIR="$SC_DIR/my models/Llama 8B" TC3_MIN_PARAMS=1
  t model-size; chk "model-size with spaces in path" is "$(st 5)" PASS
}

sc_nonroot() {
  fresh nonroot mock
  id tc3user >/dev/null 2>&1 || useradd -m tc3user
  chmod -R a+rwX "$SC_DIR"
  su tc3user -c "TC3_EVIDENCE_DIR='$TC3_EVIDENCE_DIR' TC3_BACKEND=mock TC3_PORT=$PORT TC3_API_URL='$TC3_API_URL' TC3_SOAK_N=3 TC3_FIXTURE=1 TC3_MOCK_STARTUP_DELAY=1 '$TC3' all --env '$SC_ENV'" >> "$SC_LOG" 2>&1
  chk "tc3 all as non-root" is $? 0
}

sc_timezone() {
  fresh timezone mock
  chk "container TZ is KST (+0900)" is "$(date +%z)" "+0900"
}

ALL=(mock_all mock_steps furiosa_full serve_dies_fast serve_timeout serve_twice port_foreign wrong_model_name
     bad_json_chat empty_answer soak_flaky server_dies_midsoak weights_missing params_below_min env_crlf
     env_quotes_nonl symlink_and_cwd no_jq lang_c rerun_step stale_run report_incomplete stop_nothing cli_misuse platform_manual
     soak_100 lspci_novendor lspci_none vllm_full ctrl_c_serve path_with_spaces nonroot timezone
     proxy_env env_bom soak_live_output backend_switch preflight_ok preflight_bad stop_stubborn old_sdk
     port_mismatch leader_dies ver_compare report_stale_soak platform_os_fail fetch_model_net)

i=0
for name in "${ALL[@]}"; do
  i=$((i + 1))
  [[ -n "$FILTER" && ! "$name" =~ $FILTER ]] && continue
  cleanup_procs
  printf '[%02d] %-22s ' "$i" "$name"
  t0=$SECONDS
  ( SC_NUM=$i; "sc_$name"; exit $(( OK == 1 ? 0 : (OK == 2 ? 2 : 1) )) ) > "$OUT/.cur" 2>&1
  rc=$?
  case $rc in
    0) echo "PASS  ($((SECONDS - t0))s)"; NPASS=$((NPASS + 1)); RESULTS+=("PASS $name") ;;
    2) echo "SKIP"; NSKIP=$((NSKIP + 1)); RESULTS+=("SKIP $name") ;;
    *) echo "FAIL  ($((SECONDS - t0))s)  log: $OUT/$name/out.log"; cat "$OUT/.cur"; NFAIL=$((NFAIL + 1)); RESULTS+=("FAIL $name") ;;
  esac
done
cleanup_procs
echo
echo "== scenarios: $NPASS pass, $NFAIL fail, $NSKIP skip =="
(( NFAIL == 0 ))

#!/usr/bin/env bash
# 백엔드: 로컬 시뮬레이션 — 내장 mock OpenAI 서버 (다운로드·가속기 없음, 흐름/증빙 생성 검증용)
#   - furiosa 백엔드와 같은 방식(nohup 백그라운드 + pid 파일)으로 서버를 띄우고 내려서 프로세스 관리 경로까지 검증

be_describe()  { echo "LOCAL SIMULATION — built-in mock OpenAI server on port ${TC3_PORT}"; }
be_simulated() { echo 1; }

be_install() {
  py_deps_install
  log "mock 백엔드: 추가 설치 없음"
}

be_env_check() {
  local step="$1"
  capture "$step" env_sim "로컬 시뮬레이션 환경 (가속기 없음)" -- "uname -a; python3 --version; curl --version | head -1; echo 'SIMULATED: no accelerator in local environment'"
  return 0
}

be_fetch_model() { log "mock 백엔드: 모델 다운로드 없음 (TC3_FIXTURE=1 로 fixture 생성)"; }
be_model_extra() { return 0; }

be_serve_start() {
  local logf="$TC3_RUN_DIR/server.log"
  local cmd=(python3 "$TC3_HOME/scripts/mock_openai_server.py" --port "$TC3_PORT" --model "$TC3_MODEL_NAME" --startup-delay "${TC3_MOCK_STARTUP_DELAY:-4}")
  { echo "# ==== serve $(now_iso)"; echo "# cmd: ${cmd[*]}"; } >> "$logf"
  start_bg "$logf" "${cmd[@]}"
  log "mock 서버 시작 (pid $(server_pid), log: $logf)"
}

be_accel_status() {
  local step="$1"
  if [[ -f "$(pid_file)" ]]; then
    capture "$step" serve_status "서버 프로세스 상태" -- "ps -o pid,etime,cmd -p \$(cat '$(pid_file)')" || true
  else
    capture "$step" serve_status "서버 프로세스 상태" -- "pgrep -af mock_openai_server || echo 'mock server process not running'" || true
  fi
}

be_serve_stop() { kill_pid_file; }

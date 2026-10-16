#!/usr/bin/env bash
# 백엔드: 로컬 시뮬레이션 — llama.cpp server (별도 컨테이너/프로세스) 에 실제 추론
#   - 서버는 docker compose 의 llm 서비스(또는 수동 실행)가 띄우고, 이 백엔드는 "준비 대기 + 호출" 만 한다.
#   - 가속기 단계는 SIMULATED 로 기록된다.

be_describe()  { echo "LOCAL SIMULATION — llama.cpp server at ${TC3_API_URL} (CPU, GGUF Q4_K_M)"; }
be_simulated() { echo 1; }
be_external_server() { return 0; }   # 서버는 docker compose 의 llm 서비스가 관리 (tc3 가 띄우거나 내리지 않음)

be_install() {
  py_deps_install || return 1
  log "로컬 시뮬: 추론 서버는 docker compose 의 'llm' 서비스가 담당합니다 (docker/compose.local.yml)"
}

be_env_check() {
  local step="$1"
  capture "$step" env_sim "로컬 시뮬레이션 환경 (가속기 없음)" -- "uname -a; python3 --version; curl --version | head -1; echo 'SIMULATED: no accelerator in local environment'"
  return 0
}

be_fetch_model() {
  log "로컬 시뮬: 서버 모델은 llama.cpp 가 자체 다운로드(-hf). 파라미터 수 단계는 TC3_FIXTURE=1 로 합성 fixture 사용."
}

be_model_extra() { return 0; }

be_serve_start() {
  local logf="$TC3_RUN_DIR/server.log"
  echo "# external llama.cpp server expected at $TC3_API_URL (not started by tc3)" > "$logf"
  log "외부 llama.cpp 서버 대기: $TC3_API_URL"
}

be_accel_status() {
  local step="$1"
  capture "$step" serve_status "서버 상태 (/health)" -- "curl -sS -m 5 '$TC3_API_URL/health' || true; echo" || true
}

be_preflight() {
  if curl -fsS -m 5 "$TC3_API_URL/v1/models" >/dev/null 2>&1; then pf_ok "llama.cpp 서버 응답: $TC3_API_URL"
  else pf_warn "llama.cpp 서버 미응답: $TC3_API_URL (docker compose -f docker/compose.local.yml up -d llm)"; fi
}

be_serve_stop() {
  # 외부 llama.cpp 서버는 tc3 가 띄운 것이 아니므로 여기서 내리지 않는다 (docker compose stop llm 으로 정지)
  log "로컬 시뮬: 외부 서버는 'docker compose -f docker/compose.local.yml stop llm' 으로 정지"
}

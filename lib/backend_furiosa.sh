#!/usr/bin/env bash
# 백엔드: Furiosa RNGD + furiosa-llm (OpenStack VM, PCI passthrough) — 본선(2안)
# 인터페이스: be_describe be_simulated be_install be_env_check be_fetch_model be_model_extra
#            be_serve_start be_accel_status be_serve_stop

be_describe()  { echo "Furiosa RNGD + furiosa-llm serve (devices=${TC3_DEVICES:-npu:0:*})"; }
be_simulated() { echo 0; }

_furiosa_activate() {
  if [[ -n "${TC3_FURIOSA_VENV:-}" && -f "$TC3_FURIOSA_VENV/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$TC3_FURIOSA_VENV/bin/activate"
  fi
}

be_install() {
  # 이미지(ubuntu-jammy-...-rngd-2026.x)에 드라이버/SDK 가 들어 있으면 설치 단계는 확인만 하고 끝난다.
  log "Furiosa 스택 확인 (드라이버·furiosa-smi·furiosa-llm)"
  _furiosa_activate
  local need_apt=0 need_pip=0
  have furiosa-smi || need_apt=1
  lsmod 2>/dev/null | grep -q '^furiosa' || warn "furiosa 커널 모듈이 로드되어 있지 않음 (드라이버 미설치 또는 재부팅 필요)"
  have furiosa-llm || need_pip=1

  if (( need_apt )); then
    warn "furiosa-smi 가 없습니다 → APT 저장소에서 설치합니다. (저장소 URL/패키지명은 Furiosa 문서의 이미지 버전과 맞는지 확인: https://developer.furiosa.ai)"
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates apt-transport-https gnupg curl
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "${TC3_FURIOSA_APT_KEY:-https://archive.furiosa.ai/furiosa.gpg}" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/furiosa.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/furiosa.gpg] ${TC3_FURIOSA_APT_URL:-https://archive.furiosa.ai/ubuntu} jammy restricted" \
      | sudo tee /etc/apt/sources.list.d/furiosa.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y furiosa-driver-rngd furiosa-pert-rngd furiosa-smi
    warn "드라이버를 새로 설치했으면 재부팅 후 다시 실행하세요: sudo reboot"
  fi

  # 공통 파이썬 도구 (증빙 스크립트용)
  python3 -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
  python3 -m pip install --quiet requests safetensors numpy "huggingface_hub[cli]" || sudo apt-get install -y python3-pip

  if (( need_pip )); then
    warn "furiosa-llm 이 없습니다 → pip 로 설치합니다."
    if [[ -n "${TC3_FURIOSA_VENV:-}" ]]; then
      python3 -m venv "$TC3_FURIOSA_VENV" && _furiosa_activate
    fi
    python3 -m pip install --upgrade pip
    python3 -m pip install furiosa-llm
  fi
  _furiosa_activate
  log "furiosa-smi: $(furiosa-smi --version 2>/dev/null | head -1 || echo '-')  /  furiosa-llm: $(furiosa-llm --version 2>/dev/null | head -1 || echo '-')"
}

# 절차 4: VM 에 RNGD 가 할당되었는지 + 실행환경
be_env_check() {
  local step="$1" rc=0
  _furiosa_activate
  capture "$step" env_lspci   "가속기 PCI 확인"            -- "lspci -nn | grep -i furiosa" || rc=1
  capture "$step" env_smi     "furiosa-smi info"           -- "furiosa-smi info"             || rc=1
  capture "$step" env_status  "furiosa-smi status"         -- "furiosa-smi status"           || true
  capture "$step" env_ver     "furiosa-llm / python 버전"   -- "furiosa-llm --version; python3 --version; uname -r" || rc=1
  return $rc
}

be_fetch_model() {
  _furiosa_activate
  export HF_TOKEN="${HF_TOKEN:-}"
  log "원본 가중치(파라미터 수 산출용) → $TC3_MODEL_DIR"
  mkdir -p "$TC3_MODEL_DIR" "$TC3_ARTIFACT_DIR"
  huggingface-cli download "$TC3_HF_REPO_MODEL" --local-dir "$TC3_MODEL_DIR" \
      --include "config.json" "*.safetensors" "model.safetensors.index.json" "tokenizer*" "generation_config.json"
  log "RNGD artifact → $TC3_ARTIFACT_DIR"
  huggingface-cli download "$TC3_HF_REPO_ARTIFACT" --local-dir "$TC3_ARTIFACT_DIR"
}

# 절차 5 보조: artifact 메타데이터 (furiosa-llm 버전마다 파일 구성이 다름 → 있는 것만 보여줌)
be_model_extra() {
  local step="$1"
  capture "$step" artifact_ls "RNGD artifact 디렉터리" -- "ls -lh '$TC3_ARTIFACT_DIR'" || return 1
  if [[ -f "$TC3_ARTIFACT_DIR/artifact.json" ]]; then
    capture "$step" artifact_meta "artifact.json (앞부분)" -- "head -c 1200 '$TC3_ARTIFACT_DIR/artifact.json'; echo" || true
  fi
  return 0
}

# 절차 6: furiosa-llm serve (백그라운드, 로그 → server.log)
be_serve_start() {
  _furiosa_activate
  local logf="$TC3_RUN_DIR/server.log"
  local cmd=(furiosa-llm serve "$TC3_ARTIFACT_DIR"
             --served-model-name "$TC3_MODEL_NAME"
             --devices "${TC3_DEVICES:-npu:0:*}"
             --host 0.0.0.0 --port "$TC3_PORT")
  echo "# cmd: ${cmd[*]}" > "$logf"
  nohup "${cmd[@]}" >> "$logf" 2>&1 &
  save_pid $!
  log "furiosa-llm serve 시작 (pid $(cat "$(pid_file)"), log: $logf)"
}

be_accel_status() {
  local step="$1"
  _furiosa_activate
  capture "$step" serve_status "모델 적재 후 NPU 상태" -- "furiosa-smi status" || true
}

be_serve_stop() {
  kill_pid_file
  pkill -f "furiosa-llm serve" 2>/dev/null || true
}

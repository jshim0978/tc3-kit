#!/usr/bin/env bash
# 백엔드: NVIDIA L40S + vLLM (docker vllm/vllm-openai) — 예비(1안)

be_describe()  { echo "NVIDIA GPU + vLLM docker (${TC3_VLLM_IMAGE})"; }
be_simulated() { echo 0; }

be_install() {
  log "Docker / NVIDIA Container Toolkit / vLLM 이미지 확인"
  if ! have docker; then
    warn "docker 가 없습니다 → 설치"
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$(id -un)" || true
  fi
  if ! docker info 2>/dev/null | grep -i nvidia >/dev/null; then   # grep -q 는 pipefail 에서 SIGPIPE 로 오판할 수 있음
    warn "NVIDIA Container Toolkit 미설정으로 보임 → 설치 (드라이버는 별도: nvidia-smi 가 먼저 동작해야 함)"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update -y && sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
  fi
  local rc=0
  py_deps_install || rc=1
  log "vLLM 이미지 pull: $TC3_VLLM_IMAGE"
  docker pull "$TC3_VLLM_IMAGE" || rc=1
  return $rc
}

be_env_check() {
  local step="$1" rc=0
  capture "$step" env_lspci  "가속기 PCI 확인"       -- "lspci -nn | grep -i nvidia" || rc=1
  capture "$step" env_smi    "nvidia-smi"            -- "nvidia-smi"                  || rc=1
  # docker images 는 이미지가 없어도 exit 0 → image inspect 로 존재까지 확인
  capture "$step" env_docker "docker / vLLM 이미지"   -- "docker --version && docker image inspect '$TC3_VLLM_IMAGE' --format '{{index .RepoTags 0}} {{.Id}} {{.Size}}'" || rc=1
  return $rc
}

be_preflight() {
  if lspci -nn 2>/dev/null | grep -i nvidia >/dev/null; then pf_ok "NVIDIA PCI 장치"; else pf_bad "lspci 에 NVIDIA 장치 없음"; fi
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then pf_ok "nvidia-smi 정상"; else pf_bad "nvidia-smi 실패"; fi
  if have docker && docker info >/dev/null 2>&1; then pf_ok "docker 데몬 접근"; else pf_bad "docker 데몬 접근 불가 (권한: docker 그룹)"; fi
  if docker image inspect "$TC3_VLLM_IMAGE" >/dev/null 2>&1; then pf_ok "vLLM 이미지: $TC3_VLLM_IMAGE"; else pf_bad "vLLM 이미지 없음: $TC3_VLLM_IMAGE → bin/tc3 install"; fi
}

be_fetch_model() {
  export HF_TOKEN="${HF_TOKEN:-}"
  mkdir -p "$TC3_MODEL_DIR"
  hf_access "$TC3_HF_REPO_MODEL" || return 1
  hf_download "$TC3_HF_REPO_MODEL" "$TC3_MODEL_DIR" "" "*.json" "*.safetensors" "tokenizer*" || return 1
  check_weights "$TC3_MODEL_DIR" || { fail "가중치 다운로드 불완전 — fetch-model 재실행"; return 1; }
  ok "fetch-model 완료"
}

be_model_extra() { return 0; }

be_serve_start() {
  local logf="$TC3_RUN_DIR/server.log" name="tc3-vllm"
  docker rm -f "$name" >/dev/null 2>&1 || true
  local models_root; models_root="$(dirname "$TC3_MODEL_DIR")"
  local cmd=(docker run -d --name "$name" --gpus all --ipc=host -p "${TC3_PORT}:8000"
             -v "${models_root}:${models_root}" -e HF_HUB_OFFLINE=1
             "$TC3_VLLM_IMAGE"
             --model "$TC3_MODEL_DIR" --served-model-name "$TC3_MODEL_NAME"
             --dtype bfloat16 --max-model-len "${TC3_VLLM_MAX_MODEL_LEN:-8192}" --seed 0)
  { echo "# ==== serve $(now_iso)"; echo "# cmd: ${cmd[*]}"; } >> "$logf"
  "${cmd[@]}" >> "$logf" 2>&1 || warn "docker run 실패 — server.log 확인"
  # 컨테이너 로그를 server.log 로 계속 흘려보냄. 컨테이너가 죽으면 이 프로세스도 끝나므로 serve 가 즉시 실패를 감지한다
  start_bg "$logf" docker logs -f "$name"
  log "vLLM 컨테이너 시작 ($name, log: $logf)"
}

be_accel_status() {
  local step="$1"
  capture "$step" serve_status "모델 적재 후 GPU 메모리" -- "nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv" || true
}

be_serve_stop() {
  kill_pid_file
  docker stop tc3-vllm >/dev/null 2>&1 || true
  docker rm -f tc3-vllm >/dev/null 2>&1 || true
}

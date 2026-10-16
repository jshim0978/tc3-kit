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
  if ! docker info 2>/dev/null | grep -qi nvidia; then
    warn "NVIDIA Container Toolkit 미설정으로 보임 → 설치 (드라이버는 별도: nvidia-smi 가 먼저 동작해야 함)"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update -y && sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
  fi
  python3 -m pip install --quiet requests safetensors numpy "huggingface_hub[cli]" || sudo apt-get install -y python3-pip
  log "vLLM 이미지 pull: $TC3_VLLM_IMAGE"
  docker pull "$TC3_VLLM_IMAGE"
}

be_env_check() {
  local step="$1" rc=0
  capture "$step" env_lspci  "가속기 PCI 확인"       -- "lspci -nn | grep -i nvidia" || rc=1
  capture "$step" env_smi    "nvidia-smi"            -- "nvidia-smi"                  || rc=1
  capture "$step" env_docker "docker / vLLM 이미지"   -- "docker --version; docker images '$TC3_VLLM_IMAGE' --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}'" || rc=1
  return $rc
}

be_fetch_model() {
  export HF_TOKEN="${HF_TOKEN:-}"
  mkdir -p "$TC3_MODEL_DIR"
  huggingface-cli download "$TC3_HF_REPO_MODEL" --local-dir "$TC3_MODEL_DIR" \
      --include "config.json" "*.safetensors" "model.safetensors.index.json" "tokenizer*" "generation_config.json"
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
  echo "# cmd: ${cmd[*]}" > "$logf"
  "${cmd[@]}" >> "$logf" 2>&1
  # 컨테이너 로그를 server.log 로 계속 흘려보냄
  nohup docker logs -f "$name" >> "$logf" 2>&1 &
  save_pid $!
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

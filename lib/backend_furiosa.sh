#!/usr/bin/env bash
# 백엔드: Furiosa RNGD + furiosa-llm (OpenStack VM, PCI passthrough) — 본선(2안)
# 인터페이스: be_describe be_simulated be_activate be_install be_env_check be_fetch_model be_model_extra
#            be_serve_start be_accel_status be_serve_stop be_preflight
#
# SDK 버전별 차이 (developer.furiosa.ai 문서 기준, 2026-10 확인):
#   --served-model-name     : furiosa-llm 2026.2.0 이상만 지원 (이전 버전은 인자 오류)
#   --devices               : "npu:0" (2025.1~2026.4 문서화). "npu:0:*" 는 2025.1 이하 표기
#   artifact                : furiosa-ai/<model> 의 SDK 릴리스 태그(vYYYY.N)와 SDK 가 일치해야 함. 2026.4 는 FXB(.fxb) 필요
#   furiosa-pert-rngd (apt) : 2025.x 까지만 (2026.1 부터 런타임이 로드)

be_describe()  { echo "Furiosa RNGD + furiosa-llm serve (devices=${TC3_DEVICES:-npu:0})"; }
be_simulated() { echo 0; }

be_activate() {
  if [[ -n "${TC3_FURIOSA_VENV:-}" ]]; then
    if [[ -f "$TC3_FURIOSA_VENV/bin/activate" ]]; then
      # shellcheck disable=SC1091
      source "$TC3_FURIOSA_VENV/bin/activate"
    else
      warn "TC3_FURIOSA_VENV=$TC3_FURIOSA_VENV 에 venv 가 없습니다"
    fi
  fi
}

# furiosa-llm 실행파일과 같은 파이썬(셔뱅)으로 설치 버전을 읽는다 — venv/pipx 설치여도 정확
_furiosa_py() {
  local exe sb; exe="$(command -v furiosa-llm 2>/dev/null)" || { echo python3; return; }
  sb="$(head -1 "$exe" 2>/dev/null)"
  if [[ "$sb" == '#!'*python* ]]; then echo "${sb#\#!}"; else echo python3; fi
}
_furiosa_ver() {
  [[ -n "${TC3_FURIOSA_LLM_VERSION:-}" ]] && { echo "$TC3_FURIOSA_LLM_VERSION"; return; }
  local py; read -ra py <<< "$(_furiosa_py)"
  "${py[@]}" -c "from importlib.metadata import version; print(version('furiosa-llm'))" 2>/dev/null
}
# _ver_ge A B : A >= B (점 구분 숫자 비교, 2026.2.0rc1 같은 접미사는 무시)
_ver_ge() { [[ "$(printf '%s\n%s\n' "${2%%[a-z]*}" "${1%%[a-z]*}" | sort -V | head -1)" == "${2%%[a-z]*}" ]]; }

be_install() {
  # 이미지(ubuntu-jammy-...-rngd-2026.x)에 드라이버/SDK 가 들어 있으면 설치 단계는 확인만 하고 끝난다.
  log "Furiosa 스택 확인 (드라이버·furiosa-smi·furiosa-llm)"
  local need_apt=0 need_pip=0 kmods
  have furiosa-smi || need_apt=1
  kmods="$(lsmod 2>/dev/null)"
  grep -q '^furiosa' <<< "$kmods" || warn "furiosa 커널 모듈이 로드되어 있지 않음 (드라이버 미설치 또는 재부팅 필요)"
  have furiosa-llm || need_pip=1
  local kv; kv="$(uname -r)"
  _ver_ge "${kv%%-*}" 6.3 || warn "커널 $kv — RNGD 드라이버는 6.3 이상 필요 (jammy: sudo apt install linux-generic-hwe-22.04 후 재부팅)"

  if (( need_apt )); then
    warn "furiosa-smi 가 없습니다 → Furiosa APT 저장소(pkg.dev)에서 드라이버·furiosa-smi 설치"
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/cloud.google.gpg
    echo "deb [arch=$(dpkg --print-architecture)] http://asia-northeast3-apt.pkg.dev/projects/furiosa-ai $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
      | sudo tee /etc/apt/sources.list.d/furiosa.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y build-essential "linux-modules-extra-$kv" "linux-headers-$kv"
    sudo apt-get install -y furiosa-driver-rngd furiosa-smi
    warn "드라이버를 새로 설치했으면 재부팅 후 다시 실행하세요: sudo reboot"
  fi

  if [[ -n "${TC3_FURIOSA_VENV:-}" && ! -f "$TC3_FURIOSA_VENV/bin/activate" ]]; then
    python3 -m venv "$TC3_FURIOSA_VENV" && be_activate
  fi
  # 증빙 스크립트용 파이썬 패키지 — venv 를 쓰면 venv 에, 아니면 시스템 python3 에
  py_deps_install
  if (( need_pip )); then
    warn "furiosa-llm 이 없습니다 → pip 로 설치 (드라이버 릴리스와 같은 버전이어야 함: TC3_FURIOSA_LLM_PIN)"
    python3 -m pip install --upgrade pip
    python3 -m pip install "furiosa-llm${TC3_FURIOSA_LLM_PIN:+==$TC3_FURIOSA_LLM_PIN}"
  fi
  log "furiosa-llm: $(_furiosa_ver || echo '-')  /  $(furiosa-smi info 2>/dev/null | grep -m1 -i rngd | tr -s ' ' || echo 'furiosa-smi: -')"
}

# 절차 4: VM 에 RNGD 가 할당되었는지 + 실행환경
be_env_check() {
  local step="$1" rc=0 py
  py="$(_furiosa_py)"
  # 벤더명(pci.ids)이 없는 이미지에서도 잡히도록 FuriosaAI PCI 벤더 ID 1ed2 로도 매칭 (RNGD 0001 / RNGD-S 2222 / RNGD-Plus 0002)
  capture "$step" env_lspci   "가속기 PCI 확인"            -- "lspci -nn | grep -iE 'furiosa|\\[1ed2:'" || rc=1
  capture "$step" env_smi     "furiosa-smi info"           -- "furiosa-smi info"             || rc=1
  capture "$step" env_status  "furiosa-smi status"         -- "furiosa-smi status"           || true
  capture "$step" env_ver     "furiosa-llm / python / 커널 버전" -- "command -v furiosa-llm && $py -c \"from importlib.metadata import version as v; print('furiosa-llm', v('furiosa-llm'))\" && python3 --version && uname -r" || rc=1
  return $rc
}

be_fetch_model() {
  export HF_TOKEN="${HF_TOKEN:-}"
  log "원본 가중치(파라미터 수 산출용): $TC3_HF_REPO_MODEL → $TC3_MODEL_DIR"
  mkdir -p "$TC3_MODEL_DIR" "$TC3_ARTIFACT_DIR"
  hf_download "$TC3_HF_REPO_MODEL" "$TC3_MODEL_DIR" "" "*.json" "*.safetensors" "tokenizer*" || return 1
  check_weights "$TC3_MODEL_DIR" || { fail "가중치 다운로드 불완전 — fetch-model 재실행"; return 1; }
  # artifact 는 설치된 SDK 와 같은 릴리스 태그로 (TC3_HF_ARTIFACT_REVISION 으로 지정 가능)
  local rev="${TC3_HF_ARTIFACT_REVISION:-}" ver; ver="$(_furiosa_ver)"
  if [[ -z "$rev" ]]; then
    rev="$(hf_pick_tag "$TC3_HF_REPO_ARTIFACT" "$ver")" || rev=""
    [[ -n "$rev" ]] && log "SDK $ver 에 맞는 artifact 태그: $rev" || warn "SDK '${ver:-?}' 에 맞는 태그를 찾지 못해 main 을 받습니다 — TC3_HF_ARTIFACT_REVISION 으로 지정 권장"
  fi
  log "RNGD artifact: $TC3_HF_REPO_ARTIFACT${rev:+@$rev} → $TC3_ARTIFACT_DIR (전체 — chat_template·binary_bundle 포함)"
  hf_download "$TC3_HF_REPO_ARTIFACT" "$TC3_ARTIFACT_DIR" "$rev" || return 1
  [[ -n "$(ls -A "$TC3_ARTIFACT_DIR" 2>/dev/null)" ]] || { fail "artifact 디렉터리가 비어 있음: $TC3_ARTIFACT_DIR"; return 1; }
  echo "${TC3_HF_REPO_ARTIFACT}@${rev:-main} (furiosa-llm ${ver:-?}) $(now_iso)" > "$TC3_ARTIFACT_DIR/.tc3_source"
  ok "fetch-model 완료"
}

# 절차 5 보조: artifact 메타데이터 (furiosa-llm 버전마다 파일 구성이 다름 → 있는 것만 보여줌)
be_model_extra() {
  local step="$1"
  capture "$step" artifact_ls "RNGD artifact 디렉터리" -- "ls -lh '$TC3_ARTIFACT_DIR'" || return 1
  if [[ -f "$TC3_ARTIFACT_DIR/.tc3_source" ]]; then
    capture "$step" artifact_src "artifact 출처(HF 태그)" -- "cat '$TC3_ARTIFACT_DIR/.tc3_source'" || true
  fi
  return 0
}

# 절차 6: furiosa-llm serve (별도 프로세스 그룹, 로그 → server.log)
be_serve_start() {
  local logf="$TC3_RUN_DIR/server.log" ver; ver="$(_furiosa_ver)"
  local cmd=(furiosa-llm serve "$TC3_ARTIFACT_DIR" --devices "${TC3_DEVICES:-npu:0}" --host 0.0.0.0 --port "$TC3_PORT")
  if [[ -z "$ver" ]] || _ver_ge "$ver" 2026.2.0; then
    cmd+=(--served-model-name "$TC3_MODEL_NAME")
    [[ -z "$ver" ]] && warn "furiosa-llm 버전을 읽지 못함 — --served-model-name 을 지정해 기동"
  else
    warn "furiosa-llm $ver (< 2026.2.0) 은 --served-model-name 미지원 → /v1/models id 가 '$TC3_MODEL_NAME' 과 다를 수 있음"
  fi
  if [[ -n "${TC3_FURIOSA_SERVE_ARGS:-}" ]]; then local extra; read -ra extra <<< "$TC3_FURIOSA_SERVE_ARGS"; cmd+=("${extra[@]}"); fi
  [[ -d "$TC3_ARTIFACT_DIR" ]] || warn "artifact 디렉터리 없음: $TC3_ARTIFACT_DIR (fetch-model 확인)"
  { echo "# ==== serve $(now_iso) furiosa-llm ${ver:-?}"; echo "# cmd: ${cmd[*]}"; } >> "$logf"
  start_bg "$logf" "${cmd[@]}"
  log "furiosa-llm serve 시작 (pid $(server_pid), log: $logf)"
}

be_accel_status() {
  local step="$1"
  # status: 코어 사용·메모리 / ps: NPU 를 점유한 프로세스 (serve 후엔 furiosa-llm, stop 후엔 없음)
  capture "$step" npu_status "NPU 상태 (furiosa-smi status / ps)" -- "furiosa-smi status; echo; furiosa-smi ps" || true
}

be_serve_stop() {
  kill_pid_file                                   # 프로세스 그룹(워커 포함) 종료
  pkill -f "furiosa-llm serve" 2>/dev/null || true # pid 파일 없이 남은 서버까지 정리
}

be_preflight() {
  local ln; ln="$(lspci -nn 2>/dev/null | grep -iE 'furiosa|\[1ed2:' | head -1)"
  if [[ -n "$ln" ]]; then pf_ok "RNGD PCI: ${ln:0:100}"; else pf_bad "lspci 에 FuriosaAI(1ed2) 장치 없음 — VM 에 NPU 패스스루 확인"; fi
  if have furiosa-smi && furiosa-smi info >/dev/null 2>&1; then pf_ok "furiosa-smi info 정상"; else pf_bad "furiosa-smi info 실패 (드라이버/권한)"; fi
  local ver; ver="$(_furiosa_ver)"
  if ! have furiosa-llm; then pf_bad "furiosa-llm 없음 (TC3_FURIOSA_VENV=${TC3_FURIOSA_VENV:-미설정})"
  elif [[ -z "$ver" ]]; then pf_warn "furiosa-llm 있음, 버전 확인 불가"
  elif _ver_ge "$ver" 2026.2.0; then pf_ok "furiosa-llm $ver (--served-model-name 지원)"
  else pf_warn "furiosa-llm $ver < 2026.2.0 — --served-model-name 미지원, /v1/models id 확인 필요"; fi
  [[ "${TC3_DEVICES:-}" == *":*" ]] && [[ -n "$ver" ]] && _ver_ge "$ver" 2025.2.0 && pf_warn "TC3_DEVICES=$TC3_DEVICES — 2025.2 이후 문서 표기는 npu:0"
  local kv; kv="$(uname -r)"; if _ver_ge "${kv%%-*}" 6.3; then pf_ok "커널 $kv (≥ 6.3)"; else pf_warn "커널 $kv — RNGD 드라이버 요구 6.3 이상"; fi
  if [[ -z "$(ls -A "$TC3_ARTIFACT_DIR" 2>/dev/null)" ]]; then pf_bad "artifact 없음/비어 있음: $TC3_ARTIFACT_DIR → bin/tc3 fetch-model"
  else
    local fxb; fxb="$(find "$TC3_ARTIFACT_DIR" -maxdepth 2 -name '*.fxb' 2>/dev/null | head -1)"
    if [[ -n "$ver" ]] && _ver_ge "$ver" 2026.4.0 && [[ -z "$fxb" ]]; then pf_bad "SDK $ver 는 FXB 필요 — $TC3_ARTIFACT_DIR 에 .fxb 없음"
    else pf_ok "artifact: $TC3_ARTIFACT_DIR $( [[ -f "$TC3_ARTIFACT_DIR/.tc3_source" ]] && cut -d' ' -f1 "$TC3_ARTIFACT_DIR/.tc3_source")"; fi
  fi
  local busy; busy="$(furiosa-smi ps 2>/dev/null | grep -E '[0-9]+' | grep -viE 'pid|^[+| -]*$' || true)"
  # furiosa-smi ps 출력 형식은 문서에 고정돼 있지 않아 경고로만 표시
  if [[ -n "$busy" ]] && ! server_alive; then pf_warn "NPU 를 점유한 프로세스가 있을 수 있음 → furiosa-smi ps 확인"; else pf_ok "NPU 점유 프로세스 없음 (furiosa-smi ps)"; fi
}

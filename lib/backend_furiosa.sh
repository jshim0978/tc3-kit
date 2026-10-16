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

# furiosa-llm 은 전용 venv 에 설치한다 (공식: uv pip install --torch-backend=auto). 기본 ~/furiosa-venv, "none" 이면 PATH 사용.
# venv 를 쓰는 이유: pip --user 설치는 ~/.local/bin 이 같은 세션 PATH 에 없어 바로 실행되지 않고, 시스템 패키지와 충돌할 수 있음
: "${TC3_FURIOSA_VENV:=$HOME/furiosa-venv}"
be_activate() {
  [[ "$TC3_FURIOSA_VENV" == "none" ]] && return 0
  if [[ -f "$TC3_FURIOSA_VENV/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$TC3_FURIOSA_VENV/bin/activate"
  elif ! have furiosa-llm && [[ "${CMD:-}" != "install" ]]; then
    warn "furiosa-llm 이 설치되어 있지 않습니다 (venv 없음: $TC3_FURIOSA_VENV) → bin/tc3 install"
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
# _ver_norm V : 숫자 3자리로 정규화 (2026.2 → 2026.2.0, 2026.2.0rc1 → 2026.2.0)
_ver_norm() { local v="${1%%[!0-9.]*}" p; IFS=. read -ra p <<< "$v"; printf '%d.%d.%d' "${p[0]:-0}" "${p[1]:-0}" "${p[2]:-0}"; }
# _ver_ge A B : A >= B
_ver_ge() { local a b; a="$(_ver_norm "$1")"; b="$(_ver_norm "$2")"; [[ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -1)" == "$b" ]]; }
# artifact 출처 기록 파일 — artifact 디렉터리 밖(형제 파일)에 둔다 (SDK 가 디렉터리 안 파일을 해석할 수 있으므로)
_art_src() { echo "${TC3_ARTIFACT_DIR%/}.tc3_source"; }

# 깨끗한 VM 에서 시험 당일 수행하는 설치 — 이미 있는 것은 확인만 한다 (몇 번을 실행해도 같은 결과)
#   [1] 커널 ≥ 6.3  [2] 기본 패키지  [3] Furiosa APT 저장소 + 헤더 + 드라이버·furiosa-smi  [4] NPU 동작 확인
#   [5] venv + furiosa-llm (공식 방법: uv pip install --torch-backend=auto)  [6] 키트 파이썬 도구
# 종료코드: 0 완료 / 1 실패 / 3 재부팅 필요 (sudo reboot → 재접속 → bin/tc3 install 다시 실행)
be_install() {
  local rc=0 reboot=0 kv; kv="$(uname -r)"
  log "[1/6] 커널: $kv"
  if _ver_ge "${kv%%-*}" 6.3; then ok "커널 $kv (≥ 6.3)"
  else
    warn "커널 $kv < 6.3 — RNGD 드라이버 요구사항 → HWE 커널 설치 (설치 후 재부팅 필요)"
    apt_get update && apt_get install linux-generic-hwe-22.04 || rc=1
    reboot=1
  fi

  log "[2/6] 기본 패키지"
  local miss; mapfile -t miss < <(apt_missing ca-certificates curl gnupg pciutils python3-venv python3-pip)
  if (( ${#miss[@]} )); then apt_get update && apt_get install "${miss[@]}" || rc=1
  else ok "기본 패키지 설치됨"; fi

  log "[3/6] Furiosa 드라이버 · furiosa-smi"
  if [[ ! -f /etc/apt/sources.list.d/furiosa.list ]]; then
    log "Furiosa APT 저장소 등록 (asia-northeast3-apt.pkg.dev/projects/furiosa-ai)"
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | $SUDO gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/cloud.google.gpg || rc=1
    echo "deb [arch=$(dpkg --print-architecture)] http://asia-northeast3-apt.pkg.dev/projects/furiosa-ai $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
      | $SUDO tee /etc/apt/sources.list.d/furiosa.list >/dev/null || rc=1
    apt_get update || rc=1
  fi
  local drv=("furiosa-driver-rngd${TC3_FURIOSA_DRIVER_PIN:+=$TC3_FURIOSA_DRIVER_PIN}" "furiosa-smi${TC3_FURIOSA_SMI_PIN:+=$TC3_FURIOSA_SMI_PIN}")
  if (( ! reboot )); then
    # 드라이버(DKMS)는 현재 커널의 헤더가 있어야 빌드된다 → 헤더 먼저
    mapfile -t miss < <(apt_missing build-essential "linux-modules-extra-$kv" "linux-headers-$kv")
    (( ${#miss[@]} )) && { apt_get install "${miss[@]}" || rc=1; }
  fi
  mapfile -t miss < <(apt_missing furiosa-driver-rngd furiosa-smi)
  # 고정 버전(PIN)과 설치된 버전이 다르면 고정 버전으로 맞춘다 (리허설에서 검증한 조합만 사용)
  local dv sv; dv="$(dpkg-query -W -f='${Version}' furiosa-driver-rngd 2>/dev/null)"; sv="$(dpkg-query -W -f='${Version}' furiosa-smi 2>/dev/null)"
  [[ -n "${TC3_FURIOSA_DRIVER_PIN:-}" && -n "$dv" && "$dv" != "$TC3_FURIOSA_DRIVER_PIN" ]] && miss+=(furiosa-driver-rngd)
  [[ -n "${TC3_FURIOSA_SMI_PIN:-}" && -n "$sv" && "$sv" != "$TC3_FURIOSA_SMI_PIN" ]] && miss+=(furiosa-smi)
  if (( ${#miss[@]} )); then apt_get install --allow-downgrades "${drv[@]}" || rc=1
  else ok "furiosa-driver-rngd $dv · furiosa-smi $sv 설치됨"; fi

  log "[4/6] NPU 동작 확인"
  if furiosa-smi info 2>/dev/null; then ok "furiosa-smi info 정상"
  elif ! lspci -nn 2>/dev/null | grep -iE 'furiosa|\[1ed2:' >/dev/null; then
    fail "PCI 에 FuriosaAI(1ed2) 장치가 없음 — VM 의 NPU 패스스루(flavor/호스트) 확인 필요 (재부팅으로 해결되지 않음)"; rc=1
  else
    warn "장치는 보이지만 furiosa-smi info 실패 — 드라이버 모듈 적재를 위해 재부팅 필요"; reboot=1
  fi

  log "[5/6] furiosa-llm (venv: $TC3_FURIOSA_VENV)"
  if [[ "$TC3_FURIOSA_VENV" != "none" && ! -f "$TC3_FURIOSA_VENV/bin/activate" ]]; then
    python3 -m venv "$TC3_FURIOSA_VENV" || rc=1
  fi
  be_activate
  local cur; cur="$(_furiosa_ver)"
  if [[ -z "$cur" ]] || { [[ -n "${TC3_FURIOSA_LLM_PIN:-}" ]] && [[ "$cur" != "$TC3_FURIOSA_LLM_PIN" ]]; }; then
    local spec="${TC3_FURIOSA_PIP_SPEC:-furiosa-llm${TC3_FURIOSA_LLM_PIN:+==$TC3_FURIOSA_LLM_PIN}}"
    log "설치: $spec (uv, torch-backend=auto — GPU 없는 VM 이면 CPU torch 로 받아 CUDA 패키지를 내려받지 않음)"
    python3 -m pip install --quiet --upgrade pip setuptools wheel uv || rc=1
    uv pip install --upgrade --torch-backend=auto "$spec" || rc=1
    hash -r
  else ok "furiosa-llm $cur 설치됨"; fi

  log "[6/6] 키트 파이썬 도구 (없는 것만 설치 — furiosa-llm 의존성은 건드리지 않음)"
  py_deps_install || rc=1

  local smiv; smiv="$(dpkg-query -W -f='${Version}' furiosa-smi 2>/dev/null)"
  log "요약: 커널 $kv / furiosa-driver-rngd $(dpkg-query -W -f='${Version}' furiosa-driver-rngd 2>/dev/null || echo -) / furiosa-smi ${smiv:--} / furiosa-llm $(_furiosa_ver || echo -) / venv $TC3_FURIOSA_VENV"
  if (( rc != 0 )); then fail "install 실패 — 위 오류를 확인하세요"; return 1; fi
  if (( reboot )); then warn "재부팅이 필요합니다: sudo reboot → 재접속 후 bin/tc3 install 을 다시 실행 (설치된 항목은 확인만 하고 끝남)"; return 3; fi
  ok "install 완료"
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
  ensure_dir "$TC3_MODEL_DIR" && ensure_dir "$TC3_ARTIFACT_DIR" || { fail "모델 디렉터리를 만들 수 없음: $TC3_MODEL_DIR / $TC3_ARTIFACT_DIR"; return 1; }
  local need="${TC3_FETCH_MIN_FREE_GB:-40}" free
  free="$(df -Pk "$TC3_MODEL_DIR" | awk 'NR == 2 { print int($4 / 1048576) }')"
  if (( free < need )); then fail "디스크 여유 ${free} GB < ${need} GB ($TC3_MODEL_DIR) — 가중치(~16 GB)+artifact 저장 공간 부족"; return 1; fi
  ok "디스크 여유 ${free} GB (필요 ≥ ${need} GB)"
  hf_access "$TC3_HF_REPO_MODEL" || { fail "→ bin/tc3 hf-login 으로 로그인한 뒤 다시 실행"; return 1; }
  log "원본 가중치(파라미터 수 산출용): $TC3_HF_REPO_MODEL → $TC3_MODEL_DIR"
  hf_download "$TC3_HF_REPO_MODEL" "$TC3_MODEL_DIR" "" "*.json" "*.safetensors" "tokenizer*" || return 1
  check_weights "$TC3_MODEL_DIR" || { fail "가중치 다운로드 불완전 — fetch-model 재실행"; return 1; }
  # artifact 는 설치된 SDK 와 같은 릴리스 태그로 (TC3_HF_ARTIFACT_REVISION 으로 지정 가능)
  local rev="${TC3_HF_ARTIFACT_REVISION:-}" ver; ver="$(_furiosa_ver)"
  if [[ -z "$rev" ]]; then
    rev="$(hf_pick_tag "$TC3_HF_REPO_ARTIFACT" "$ver")" || rev=""
    [[ -n "$rev" ]] && log "SDK $ver 에 맞는 artifact 태그: $rev" || warn "SDK '${ver:-?}' 에 맞는 태그를 찾지 못해 main 을 받습니다 — TC3_HF_ARTIFACT_REVISION 으로 지정 권장"
  fi
  local want="${TC3_HF_REPO_ARTIFACT}@${rev:-main}" src; src="$(_art_src)"
  # 다른 리비전이 이미 받아져 있으면 섞이지 않도록 중단 (이전 리비전의 .fxb 등이 남을 수 있음)
  if [[ -n "$(ls -A "$TC3_ARTIFACT_DIR" 2>/dev/null)" ]] && { [[ ! -f "$src" ]] || [[ "$(cut -d' ' -f1 "$src")" != "$want" ]]; }; then
    fail "artifact 디렉터리에 다른 내용이 있음: $TC3_ARTIFACT_DIR (기존: $(cut -d' ' -f1 "$src" 2>/dev/null || echo '출처 불명'), 요청: $want)"
    fail "  → 디렉터리를 비우거나 TC3_ARTIFACT_DIR 을 새 경로로 지정한 뒤 다시 실행"
    return 1
  fi
  log "RNGD artifact: $want → $TC3_ARTIFACT_DIR (전체 — chat_template·binary_bundle 포함)"
  hf_download "$TC3_HF_REPO_ARTIFACT" "$TC3_ARTIFACT_DIR" "$rev" || return 1
  [[ -n "$(ls -A "$TC3_ARTIFACT_DIR" 2>/dev/null)" ]] || { fail "artifact 디렉터리가 비어 있음: $TC3_ARTIFACT_DIR"; return 1; }
  echo "$want (furiosa-llm ${ver:-?}) $(now_iso)" > "$src"
  ok "fetch-model 완료"
}

# 절차 5 보조: artifact 메타데이터 (furiosa-llm 버전마다 파일 구성이 다름 → 있는 것만 보여줌)
be_model_extra() {
  local step="$1"
  capture "$step" artifact_ls "RNGD artifact 디렉터리" -- "ls -lh '$TC3_ARTIFACT_DIR'" || return 1
  if [[ -f "$(_art_src)" ]]; then
    capture "$step" artifact_src "artifact 출처(HF 태그)" -- "cat '$(_art_src)'" || true
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
  # 2026.1~2026.3 은 Ray 를 쓴다 — Ray 데몬은 별도 세션으로 떠 그룹 종료에 안 잡힐 수 있어 우리 사용자 것만 정리
  if have ray && pgrep -u "$(id -u)" -f 'raylet|gcs_server' >/dev/null 2>&1; then ray stop --force >/dev/null 2>&1 || true; fi
}

be_preflight() {
  local ln; ln="$(lspci -nn 2>/dev/null | grep -iE 'furiosa|\[1ed2:' | head -1)"
  if [[ -n "$ln" ]]; then pf_ok "RNGD PCI: ${ln:0:100}"; else pf_bad "lspci 에 FuriosaAI(1ed2) 장치 없음 — VM 에 NPU 패스스루 확인"; fi
  if have furiosa-smi && furiosa-smi info >/dev/null 2>&1; then pf_ok "furiosa-smi info 정상"; else pf_bad "furiosa-smi info 실패 (드라이버/권한)"; fi
  local ver py; ver="$(_furiosa_ver)"; read -ra py <<< "$(_furiosa_py)"
  if ! have furiosa-llm; then pf_bad "furiosa-llm 없음 (TC3_FURIOSA_VENV=${TC3_FURIOSA_VENV:-미설정})"
  elif [[ -z "$ver" ]]; then pf_warn "furiosa-llm 있음, 버전 확인 불가"
  elif _ver_ge "$ver" 2026.2.0; then pf_ok "furiosa-llm $ver (--served-model-name 지원)"
  else pf_bad "furiosa-llm $ver < 2026.2.0 — --served-model-name 미지원: /v1/models id 가 '$TC3_MODEL_NAME' 이 아니라 절차 7~10 실패 (SDK 업그레이드 필요)"; fi
  # 고정 버전(PIN)과 실제 설치 버전 일치 — 리허설에서 검증한 조합인지
  if [[ -n "${TC3_FURIOSA_LLM_PIN:-}" && -n "$ver" ]]; then
    if [[ "$ver" == "$TC3_FURIOSA_LLM_PIN" ]]; then pf_ok "furiosa-llm = 고정 버전 $TC3_FURIOSA_LLM_PIN"
    else pf_bad "furiosa-llm $ver ≠ 고정 버전 $TC3_FURIOSA_LLM_PIN → bin/tc3 install"; fi
  fi
  local pair p var pin iv
  for pair in furiosa-driver-rngd:TC3_FURIOSA_DRIVER_PIN furiosa-smi:TC3_FURIOSA_SMI_PIN; do
    p="${pair%%:*}"; var="${pair#*:}"; pin="${!var:-}"
    iv="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
    [[ -z "$pin" ]] && continue
    if [[ -z "$iv" ]]; then pf_warn "$p 패키지 정보 없음 (dpkg) — 고정 버전 $pin 확인 불가"
    elif [[ "$iv" == "$pin" ]]; then pf_ok "$p = 고정 버전 $pin"
    else pf_bad "$p $iv ≠ 고정 버전 $pin → bin/tc3 install"; fi
  done
  # SDK 가 실제로 import 되는지 (의존 패키지 충돌로 serve 가 즉시 죽는 경우를 사전에 잡음)
  if have furiosa-llm; then
    local ie; if ie="$("${py[@]}" -c 'import furiosa_llm' 2>&1)"; then pf_ok "furiosa_llm import 정상 (${py[*]})"; else pf_bad "furiosa_llm import 실패: ${ie##*$'\n'}"; fi
  fi
  [[ "${TC3_DEVICES:-}" == *":*" ]] && [[ -n "$ver" ]] && _ver_ge "$ver" 2025.2.0 && pf_warn "TC3_DEVICES=$TC3_DEVICES — 2025.2 이후 문서 표기는 npu:0"
  local kv; kv="$(uname -r)"; if _ver_ge "${kv%%-*}" 6.3; then pf_ok "커널 $kv (≥ 6.3)"; else pf_warn "커널 $kv — RNGD 드라이버 요구 6.3 이상"; fi
  if [[ -z "$(ls -A "$TC3_ARTIFACT_DIR" 2>/dev/null)" ]]; then pf_bad "artifact 없음/비어 있음: $TC3_ARTIFACT_DIR → bin/tc3 fetch-model"
  else
    local fxb; fxb="$(find "$TC3_ARTIFACT_DIR" -maxdepth 2 -name '*.fxb' 2>/dev/null | head -1)"
    if [[ -n "$ver" ]] && _ver_ge "$ver" 2026.4.0 && [[ -z "$fxb" ]]; then pf_bad "SDK $ver 는 FXB 필요 — $TC3_ARTIFACT_DIR 에 .fxb 없음"
    else pf_ok "artifact: $TC3_ARTIFACT_DIR $( [[ -f "$(_art_src)" ]] && cut -d' ' -f1 "$(_art_src)")"; fi
  fi
  local busy; busy="$(furiosa-smi ps 2>/dev/null | grep -E '[0-9]+' | grep -viE 'pid|^[+| -]*$' || true)"
  # furiosa-smi ps 출력 형식은 문서에 고정돼 있지 않아 경고로만 표시
  if [[ -n "$busy" ]] && ! server_alive; then pf_warn "NPU 를 점유한 프로세스가 있을 수 있음 → furiosa-smi ps 확인"; else pf_ok "NPU 점유 프로세스 없음 (furiosa-smi ps)"; fi
}

#!/usr/bin/env bash
# tc3 VM 상태 스냅샷 · 비교 · 원복 — 리허설 전 "처음 받은 상태"로 VM 을 되돌린다 (시험 당일 install 부터 시작하도록)
#
#   vm-state.sh snapshot <file>                 현재 상태 기록 (VM 을 받은 직후 1회: /var/tmp/tc3-baseline.txt 권장)
#   vm-state.sh diff <baseline> [current]       기준 대비 차이 (current 생략 시 지금 상태)
#   vm-state.sh wipe <baseline> [--yes] [--history]
#       기준 이후 생긴 것만 제거: 서버 프로세스 → 추가된 apt 패키지(purge) → 추가된 apt 저장소·키 → 추가된 pip(--user)
#       → 키트·venv·캐시·모델 등 새로 생긴 경로 → 홈의 새 항목(.ssh 제외). 기본은 계획만 출력(dry-run), --yes 로 실행.
#       --history: ~/.bash_history 도 삭제. 끝나면 기준과 다시 비교해 남은 차이를 보여준다.
# 주의: 키트 디렉터리 밖(예: /var/tmp)에 복사해서 실행 (wipe 가 ~/tc3-kit 을 지움)
set -uo pipefail

KIT="${TC3_KIT_DIR:-$HOME/tc3-kit}"
VENV="${TC3_FURIOSA_VENV:-$HOME/furiosa-venv}"
MODELS="${TC3_MODELS_ROOT:-/models}"
SUDO=""; (( EUID != 0 )) && SUDO="sudo"
PATHS=("$KIT" "$VENV" "$MODELS" "$HOME/.cache/huggingface" "$HOME/.cache/pip" "$HOME/.cache/uv" "$HOME/.local")

snapshot() {
  echo "## kernel"; uname -r
  echo "## packages"; dpkg-query -W -f='${db:Status-Abbrev} ${Package}=${Version}\n' 2>/dev/null | awk '$1 == "ii" { print $2 }' | sort
  echo "## apt-sources"; ls -1 /etc/apt/sources.list.d/ 2>/dev/null | sort; sha256sum /etc/apt/sources.list 2>/dev/null | cut -c1-16
  echo "## apt-keys"; ls -1 /etc/apt/trusted.gpg.d/ /etc/apt/keyrings/ 2>/dev/null | grep -v ':$' | grep -v '^$' | sort
  echo "## kernel-modules"; lsmod 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -iE 'furiosa|rngd' | sort
  echo "## dkms"; (dkms status 2>/dev/null || true) | sort
  echo "## pip-user"; python3 -m pip list --user --format=freeze 2>/dev/null | sort
  echo "## paths"; local p; for p in "${PATHS[@]}"; do if [[ -e "$p" ]]; then echo "$p"; fi; done
  echo "## models"; ls -1A "$MODELS" 2>/dev/null | sort
  echo "## home"; ls -1A "$HOME" 2>/dev/null | sort
  echo "## listen"; (ss -Hltn 2>/dev/null || true) | awk '{ print $4 }' | sort -u
  echo "## procs"; pgrep -af 'furiosa-llm|raylet|gcs_server|fake_openai' 2>/dev/null | grep -v -e pgrep -e vm-state | awk '{ $1 = ""; print substr($0, 2) }' | sort
}

section() { awk -v s="## $2" '$0 == s { on = 1; next } /^## / { on = 0 } on && NF' "$1"; }
added()   { comm -13 <(section "$1" "$3" | sort -u) <(section "$2" "$3" | sort -u); }   # base 에 없고 now 에 있는 줄
removed() { comm -23 <(section "$1" "$3" | sort -u) <(section "$2" "$3" | sort -u); }

YES=0; HIST=0
run() { if (( YES )); then echo "+ $*"; "$@"; else echo "(dry-run) $*"; fi; }

wipe() {
  local base="$1" now; now="$(mktemp)"; snapshot > "$now"
  echo "== 기준: $base  (kit=$KIT venv=$VENV models=$MODELS)"
  (( YES )) || echo "== DRY-RUN: 실제로 지우려면 --yes"

  echo "-- 1) 서버 프로세스 정리"
  run pkill -f 'furiosa-llm serve' ; run pkill -f fake_openai.py
  if command -v ray >/dev/null 2>&1 || [[ -x "$VENV/bin/ray" ]]; then run "${VENV}/bin/ray" stop --force; fi

  echo "-- 2) 추가된 apt 패키지 purge"
  local run_kernel; run_kernel="$(uname -r)"
  local -a pk=(); local l n
  while read -r l; do
    n="${l%%=*}"
    if [[ "$n" == *"$run_kernel"* ]]; then echo "   유지(실행 중 커널): $n — 기준 커널로 되돌리려면 재부팅 후 다시 wipe"; continue; fi
    section "$base" packages | awk -F= -v n="$n" '$1 == n { f = 1 } END { exit !f }' && { echo "   버전만 바뀜(되돌리지 않음): $l"; continue; }
    pk+=("$n")
  done < <(added "$base" "$now" packages)
  if (( ${#pk[@]} )); then run $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=600 -y purge "${pk[@]}"
  else echo "   없음"; fi
  removed "$base" "$now" packages | sed 's/^/   기준에 있었으나 지금 없음(확인 필요): /'

  echo "-- 3) 추가된 apt 저장소·키"
  local f changed=0
  while read -r f; do [[ -n "$f" ]] && { run $SUDO rm -f "/etc/apt/sources.list.d/$f"; changed=1; }; done < <(added "$base" "$now" apt-sources | grep -v '^[0-9a-f]\{16\}$')
  while read -r f; do [[ -n "$f" ]] && { run $SUDO rm -f "/etc/apt/trusted.gpg.d/$f" "/etc/apt/keyrings/$f"; changed=1; }; done < <(added "$base" "$now" apt-keys)
  (( changed )) && run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y update -qq

  echo "-- 4) 추가된 pip --user 패키지"
  mapfile -t pk < <(added "$base" "$now" pip-user | cut -d= -f1)
  if (( ${#pk[@]} )); then run python3 -m pip uninstall -y "${pk[@]}"; else echo "   없음"; fi

  echo "-- 5) 새로 생긴 경로 · 모델"
  while read -r f; do [[ -n "$f" ]] && run $SUDO rm -rf -- "$f"; done < <(added "$base" "$now" paths)
  if section "$base" paths | grep -qx "$MODELS"; then
    while read -r f; do [[ -n "$f" ]] && run $SUDO rm -rf -- "$MODELS/$f"; done < <(added "$base" "$now" models)
  fi

  echo "-- 6) 홈의 새 항목 (.ssh 제외)"
  while read -r f; do
    [[ -z "$f" || "$f" == ".ssh" ]] && continue
    [[ "$f" == ".bash_history" ]] && (( ! HIST )) && { echo "   유지: .bash_history (--history 로 삭제)"; continue; }
    run rm -rf -- "$HOME/$f"
  done < <(added "$base" "$now" home)
  if (( HIST )) && [[ -f "$HOME/.bash_history" ]]; then run rm -f -- "$HOME/.bash_history"; fi

  echo "-- 7) 남은 차이 (기준 대비)"
  snapshot > "$now"
  if diff_out="$(diff <(cat "$base") "$now")"; then echo "   없음 — 기준 상태와 동일"
  else echo "$diff_out" | sed 's/^/   /'
       section "$now" kernel-modules | grep -q . && echo "   ※ 커널 모듈이 아직 적재됨 → sudo reboot 후 다시 diff"
  fi
  rm -f "$now"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  snapshot) [[ -n "${1:-}" ]] || { echo "usage: $0 snapshot <file>" >&2; exit 2; }; snapshot > "$1"; echo "snapshot → $1 ($(grep -c . "$1") lines)" ;;
  diff)     [[ -f "${1:-}" ]] || { echo "usage: $0 diff <baseline> [current]" >&2; exit 2; }
            if [[ -n "${2:-}" ]]; then diff "$1" "$2"; else diff "$1" <(snapshot); fi && echo "차이 없음" ;;
  wipe)     base="${1:-}"; shift || true; [[ -f "$base" ]] || { echo "usage: $0 wipe <baseline> [--yes] [--history]" >&2; exit 2; }
            for o in "$@"; do case "$o" in --yes) YES=1 ;; --history) HIST=1 ;; *) echo "unknown option $o" >&2; exit 2 ;; esac; done
            wipe "$base" ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

#!/usr/bin/env bash
# TC3 시험 실행기 — 옵션 없이 쓰는 단일 진입점. 로직은 모두 bin/tc3 에 있고, 여기는 메뉴·안내만 한다.
#   ./start.sh              메뉴
#   ./start.sh 1|2|3|all    바로 실행 (1 사전준비 확인 · 2 시험 스크립트 재생 · 3 결과 보기 · all 1→2→3)
cd "$(dirname "$(readlink -f "$0")")" || exit 1
if [[ ! -f tc3.env ]]; then cp tc3.env.example tc3.env && echo "[start] tc3.env 가 없어 tc3.env.example 을 복사했습니다 (값 확인: vi tc3.env)"; fi
conf() { local v; v="$(grep -E "^$1=" tc3.env | tail -1 | cut -d= -f2- | tr -d '\r')"; echo "${!1:-${v:-$2}}"; }
BACKEND="$(conf TC3_BACKEND furiosa)"; EV="$(conf TC3_EVIDENCE_DIR evidence)"
REV="$(git rev-parse --short HEAD 2>/dev/null || echo -)"

item() { # item <번호> <설명> <명령 문자열> — 실행할 명령을 먼저 보여주고 실행, 끝나면 한 줄 요약
  local n="$1" what="$2" cmd="$3" t0=$SECONDS rc run
  echo; echo "▶ $n) $what"; echo "  \$ $cmd"; echo
  bash -c "$cmd"; rc=$?
  run="$(cat "$EV/.current_run" 2>/dev/null)"; run="${run#"$PWD"/}"
  echo
  if (( rc == 0 )); then echo "✔ $n) $what — 완료 ($((SECONDS - t0)) s) · 결과 ${run:-$EV}/"
  else echo "✘ $n) $what — 실패 (종료코드 $rc, $((SECONDS - t0)) s) · 로그 ${run:-$EV}/ — 원인 확인 후 다시 실행 (자동 재시도 없음)"; fi
  return $rc
}
do1() { item 1 "사전준비 확인" "bin/tc3 preflight" && echo "  다음: 2) 시험 스크립트 재생"; }
do2() { item 2 "시험 스크립트 재생" "bin/tc3 live" && echo "  다음: 3) 결과 보기"; }
do3() { item 3 "결과 보기" "bin/tc3 result && bin/tc3 result --files"; }
doall() { do1 && do2 && do3; }

case "${1:-}" in
  1) do1; exit ;; 2) do2; exit ;; 3) do3; exit ;; all|a) doall; exit ;;
  "") ;;
  *) echo "사용법: ./start.sh [1|2|3|all]"; exit 2 ;;
esac
while :; do
  cat <<EOF

TC3 시험 실행기 — 백엔드: $BACKEND (tc3.env)   키트: $REV
 1) 사전준비 확인      bin/tc3 preflight
 2) 시험 스크립트 재생  bin/tc3 live   (tmux 없으면 run --inline-monitor)
 3) 결과 보기          bin/tc3 result && bin/tc3 result --files
 a) 1 → 2 → 3 순서대로 전부
 q) 종료
EOF
  read -rp "선택: " c || exit 0
  case "$c" in
    1) do1 ;; 2) do2 ;; 3) do3 ;; a|A) doall ;; q|Q) exit 0 ;;
    *) echo "1, 2, 3, a, q 중에서 고르세요" ;;
  esac
done

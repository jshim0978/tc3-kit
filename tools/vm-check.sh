#!/usr/bin/env bash
# 새 VM 첫 접속 점검 (읽기 전용 — 아무것도 설치·변경하지 않음). 리허설 시작 전, vm-state.sh snapshot 과 함께.
#   scp tools/vm-check.sh llmvm:/var/tmp/ && ssh llmvm 'bash /var/tmp/vm-check.sh [프록시 주소]'
#   예: bash /var/tmp/vm-check.sh http://192.168.90.153:3128
PROXY="${1:-}"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; BAD=$((BAD + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
BAD=0

echo "== VM"
echo "  $(hostname)  $(. /etc/os-release; echo "$PRETTY_NAME")  kernel $(uname -r)  user $(id -un)"
kv="$(uname -r | cut -d- -f1)"
if printf '%s\n6.3\n' "$kv" | sort -V -C 2>/dev/null; then warn "커널 $kv < 6.3 → install 이 HWE 커널 설치 후 재부팅을 요구함 (정상 흐름, 원복 시 커널 주의)"
else ok "커널 $kv (≥ 6.3)"; fi
echo "  CPU $(nproc)  RAM $(free -g | awk '/^Mem:/ {print $2}') GB  시각대 $(date '+%Z %z')  NTP $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')"
df -h / /models 2>/dev/null | awk 'NR == 1 || !seen[$0]++' | sed 's/^/  /'
avail="$(df -Pk "$( [ -d /models ] && echo /models || echo / )" | awk 'NR == 2 { print int($4 / 1048576) }')"
if (( avail >= 40 )); then ok "디스크 여유 ${avail} GB (fetch-model ≥ 40 GB)"; else bad "디스크 여유 ${avail} GB < 40 GB (원본 16 GB + artifact 16.5 GB)"; fi

echo "== NPU"
if command -v lspci >/dev/null; then
  l="$(lspci -nn 2>/dev/null | grep -iE 'furiosa|\[1ed2:')"
  if [[ -n "$l" ]]; then ok "RNGD: $l"; else bad "PCI 에 FuriosaAI(1ed2) 장치 없음 — flavor 의 pci alias 확인"; fi
else
  warn "lspci 없음 (pciutils 는 install 이 설치) — /sys 로 확인"
  s="$(grep -l 0x1ed2 /sys/bus/pci/devices/*/vendor 2>/dev/null)"
  if [[ -n "$s" ]]; then ok "RNGD: ${s//$'\n'/ }"; else bad "PCI 에 FuriosaAI(1ed2) 장치 없음 — flavor 의 pci alias 확인"; fi
fi

echo "== 권한"
if sudo -n true 2>/dev/null; then ok "sudo 암호 없이 가능 (install 자동 실행 가능)"; else warn "sudo 가 암호를 요구 — install 은 사람이 그 창에서 암호 입력 필요"; fi
command -v python3 >/dev/null && ok "python3 $(python3 -c 'import platform; print(platform.python_version())')" || bad "python3 없음"
command -v git >/dev/null && ok "git $(git --version | awk '{print $3}')" || bad "git 없음 (clone 불가 → sudo apt-get install -y git 필요)"
command -v curl >/dev/null && ok "curl" || bad "curl 없음"

echo "== 네트워크 (직접)"
echo "  route: $(ip -4 route show default 2>/dev/null | head -1)   dns: $(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf)"
direct=0
# install·fetch-model 이 실제로 접속하는 곳 (PyTorch 휠은 download-r2.pytorch.org, HF 파일은 cdn 호스트에서 내려옴)
# HEAD 요청만 (큰 파일도 내려받지 않음)
URLS=(https://github.com https://huggingface.co https://pypi.org https://files.pythonhosted.org/packages/py2.py3/s/six/six-1.16.0-py2.py3-none-any.whl
      https://download.pytorch.org/whl/cpu/ 'https://download-r2.pytorch.org/whl/cpu/torch-2.5.1%2Bcpu-cp310-cp310-linux_x86_64.whl'
      http://archive.ubuntu.com/ubuntu/ http://asia-northeast3-apt.pkg.dev/projects/furiosa-ai/dists/jammy/Release https://packages.cloud.google.com/apt/doc/apt-key.gpg)
for u in "${URLS[@]}"; do
  c="$(curl -sI -o /dev/null -m 10 -w '%{http_code}' --noproxy '*' "$u" 2>/dev/null)"
  if [[ "$c" =~ ^[23] ]]; then ok "$u → $c"; direct=$((direct + 1)); else warn "$u → ${c:-000} (직접 접속 안 됨)"; fi
done
echo "  apt 미러: $( { grep -hE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list; grep -hE '^URIs:' /etc/apt/sources.list.d/*.sources; } 2>/dev/null \
  | grep -oE '(https?|ftp)://[^ ]+|file:[^ ]+' | sed -E 's#^(https?|ftp)://([^/]+).*#\2#' | sort -u | tr '\n' ' ')"
[[ -n "${http_proxy:-}${https_proxy:-}" ]] && warn "환경에 프록시 설정됨: ${http_proxy:-} ${https_proxy:-}"

if [[ -n "$PROXY" ]]; then
  echo "== 네트워크 (프록시 $PROXY)"
  for u in "${URLS[@]}"; do
    c="$(curl -sI -o /dev/null -m 15 -w '%{http_code}' -x "$PROXY" "$u" 2>/dev/null)"
    if [[ "$c" =~ ^[23] ]]; then ok "$u → $c"; else bad "$u → ${c:-000} (프록시 경유 실패)"; fi
  done
fi

echo
if (( direct == ${#URLS[@]} )); then ok "인터넷 직접 접속 가능 — 프록시 불필요"
elif [[ -z "$PROXY" ]]; then warn "인터넷 직접 접속이 일부/전부 안 됨 (${direct}/${#URLS[@]}) — master3 프록시로 재점검: bash $0 http://192.168.90.153:3128 (런북 3-1)"; fi
(( BAD == 0 )) && echo "vm-check: 문제 없음" || { echo "vm-check: 문제 ${BAD}건"; exit 1; }

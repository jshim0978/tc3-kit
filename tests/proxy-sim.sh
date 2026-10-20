#!/usr/bin/env bash
# 인터넷이 없는 시험 VM 흉내 — docker --internal 망의 vm-sim 컨테이너가 프록시 컨테이너(tools/tc3-proxy.py)만 거쳐서
# git clone / bin/tc3 preflight / install / fetch-model 을 끝낼 수 있는지, serve 이후 단계에는 프록시가 섞이지 않는지 검증한다.
#   docker build -t tc3-vm-sim -f tests/vm-sim/Dockerfile .   (한 번)
#   bash tests/proxy-sim.sh            # 작업 트리(커밋 안 된 수정 포함)를 VM 컨테이너에 복사해 실행
#   KEEP=1 bash tests/proxy-sim.sh     # 끝나도 컨테이너를 남김 (조사용)
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
KIT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${IMG:-tc3-vm-sim}"
NET=tc3-psim-nonet OUTNET=tc3-psim-out VM=tc3-psim-vm PX=tc3-psim-proxy UP=tc3-psim-up OTHER=tc3-psim-other
PXURL="http://$PX:3128"
OUT="${OUT:-$KIT/tests/.proxy-sim}"; mkdir -p "$OUT"; LOG="$OUT/run.log"; : > "$LOG"
NPASS=0; NFAIL=0

cleanup() { docker rm -f $VM $PX $UP $OTHER >/dev/null 2>&1; docker network rm $NET $OUTNET >/dev/null 2>&1; }
[[ "${KEEP:-0}" == 1 ]] || trap cleanup EXIT
chk() { # chk <설명> <명령...>
  local d="$1"; shift
  if "$@" >> "$LOG" 2>&1; then echo "  ok   $d"; NPASS=$((NPASS + 1)); else echo "  FAIL $d   (log: $LOG)"; NFAIL=$((NFAIL + 1)); fi
}
vm()    { docker exec -u etri -w /home/etri/tc3-kit $VM bash -c "set -a; . /etc/environment; set +a; $1"; }   # ssh 로그인과 같은 환경
vmlog() { echo "### vm: $1" >> "$LOG"; vm "$1" >> "$LOG" 2>&1; }

cleanup
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "이미지 $IMG 없음 — docker build -t tc3-vm-sim -f tests/vm-sim/Dockerfile ."; exit 2; }
echo "== 준비: 내부 전용 망 + VM + 프록시 + 가짜 업스트림"
docker network create --internal $NET >/dev/null
docker network create $OUTNET >/dev/null   # 프록시의 바깥쪽 (인터넷 가능, 사용자 정의 망이라 컨테이너 이름 DNS 가 됨)
docker run -d --name $VM --hostname etri-llm-test --network $NET "$IMG" sleep infinity >/dev/null
VMIP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" $VM)"
# 저장소에 들어갈 파일만 (추적 + 새 파일, 무시 대상 제외 → models/·evidence/·tc3.env 는 안 감) + .git (preflight 의 커밋 확인용)
( cd "$KIT" && { git ls-files -co --exclude-standard; find .git -type f; } | tar -cf - -T - ) \
  | docker exec -i $VM bash -c 'mkdir -p /home/etri/tc3-kit && tar -C /home/etri/tc3-kit -xf - && chown -R etri:etri /home/etri/tc3-kit'
docker run -d --name $PX --network $OUTNET "$IMG" sleep infinity >/dev/null
docker network connect $NET $PX
docker exec -i $PX bash -c 'cat > /tc3-proxy.py' < "$KIT/tools/tc3-proxy.py"
docker exec -d $PX bash -c "python3 /tc3-proxy.py --listen 0.0.0.0:3128 --client $VMIP --allow-extra upstream.test --log /tmp/px.log > /tmp/px.out 2>&1"
docker run -d --name $UP --network $NET --network-alias upstream.test "$IMG" \
  bash -c 'mkdir -p /srv && truncate -s 1G /srv/big.bin && cd /srv && exec python3 -m http.server 80' >/dev/null
docker run -d --name $OTHER --network $NET "$IMG" sleep infinity >/dev/null
sleep 3
echo "   VM $VMIP (내부 망만), 프록시 $PXURL (--client $VMIP)"

echo "== 1. 격리 확인"
chk "VM 은 인터넷에 직접 못 나감" vm '! curl -s -m 8 -o /dev/null https://huggingface.co'
chk "다른 컨테이너는 프록시 사용 거부 (403)" bash -c "[ \"\$(docker exec $OTHER curl -s -o /dev/null -m 10 -w '%{http_code}' -x $PXURL http://archive.ubuntu.com/)\" = 403 ]"
chk "허용 목록 밖 목적지 거부 (프록시가 403)" bash -c "[ \"\$(docker exec $VM curl -s -m 10 -o /dev/null -w '%{http_connect}' -x $PXURL https://example.com)\" = 403 ]"
chk "CONNECT 는 443 만 (프록시가 403)" bash -c "[ \"\$(docker exec $VM curl -s -m 10 -o /dev/null -w '%{http_connect}' -p -x $PXURL https://github.com:22)\" = 403 ]"

echo "== 2. git clone (키트 받기 전 단계: git -c http.proxy)"
chk "git clone https://github.com/... via proxy" vm "git -c http.proxy=$PXURL clone -q --depth 1 https://github.com/octocat/Hello-World.git /tmp/hw && test -f /tmp/hw/README"

echo "== 3. 키트: TC3_PROXY 설정 후 preflight / install / fetch-model"
vm "cp tc3.env.example tc3.env && sed -i 's|^TC3_PROXY=.*|TC3_PROXY=$PXURL|' tc3.env && grep '^TC3_PROXY=' tc3.env" >> "$LOG" 2>&1
vmlog 'bin/tc3 preflight'
chk "preflight: 프록시 경유 외부 접속 정상" grep -q '경유 외부 접속 정상' "$LOG"
t0=$SECONDS
chk "install (apt·Furiosa 저장소·pip/uv 전부 프록시 경유) exit 0" vm 'bin/tc3 install'
echo "     install $((SECONDS - t0))s"
chk "apt 가 프록시 설정을 받음 (sudo 너머)" bash -c "docker exec $PX grep -q 'GET http://.*ubuntu.com/' /tmp/px.log"
chk "Furiosa APT 저장소(pkg.dev) 프록시 경유" bash -c "docker exec $PX grep -q 'pkg.dev' /tmp/px.log"
chk "Google 서명 키 프록시 경유" bash -c "docker exec $PX grep -q 'packages.cloud.google.com:443 OK' /tmp/px.log"
chk "PyPI 프록시 경유" bash -c "docker exec $PX grep -qE '(pypi.org|files.pythonhosted.org):443 OK' /tmp/px.log"
FETCH_ENV='TC3_HF_REPO_MODEL=hf-internal-testing/tiny-random-LlamaForCausalLM TC3_MODEL_DIR=/home/etri/w TC3_HF_REPO_ARTIFACT=trl-internal-testing/tiny-LlamaForCausalLM-3.2 TC3_ARTIFACT_DIR=/home/etri/art TC3_HF_ARTIFACT_REVISION=main TC3_FETCH_MIN_FREE_GB=1'
chk "fetch-model (HF) exit 0" vm "$FETCH_ENV bin/tc3 fetch-model"
chk "가중치 받음 (config.json, model.safetensors)" vm 'test -f /home/etri/w/config.json && test -f /home/etri/w/model.safetensors'
chk "artifact 받음" vm 'test -f /home/etri/art/config.json'
chk "HF 프록시 경유" bash -c "docker exec $PX grep -q 'huggingface.co:443 OK' /tmp/px.log"

echo "== 3b. 실제 furiosa-llm 의존성 해석 (uv --dry-run --torch-backend=auto, 프록시 경유 — 허용 목록 누락 검출)"
d0="$(docker exec $PX bash -c 'wc -l < /tmp/px.log')"
chk "uv 가 furiosa-llm==${REAL_LLM:-2026.3.0} 전체 의존성 해석 (exit 0)" vm "HTTPS_PROXY=$PXURL HTTP_PROXY=$PXURL ~/furiosa-venv/bin/uv pip install --dry-run --python ~/furiosa-venv/bin/python --torch-backend=auto furiosa-llm==${REAL_LLM:-2026.3.0}"
chk "해석 중 거부된 목적지 없음" bash -c "! docker exec $PX tail -n +$((d0 + 1)) /tmp/px.log | grep DENY"
chk "PyTorch CPU 인덱스 경유" bash -c "docker exec $PX tail -n +$((d0 + 1)) /tmp/px.log | grep -q 'pytorch.org:443 OK'"

echo "== 4. 시험 단계 (serve 이후): 프록시가 섞이지 않음"
n0="$(docker exec $PX bash -c 'wc -l < /tmp/px.log')"
chk "serve exit 0" vm 'TC3_FIXTURE=1 bin/tc3 serve'
chk "서버 프로세스 환경에 http(s)_proxy 없음" vm 'pid=$(pgrep -f "furiosa-llm serve" | head -1); [ -n "$pid" ] && ! tr "\0" "\n" < /proc/$pid/environ | grep -qiE "^https?_proxy="'
chk "verify exit 0" vm 'bin/tc3 verify'
chk "soak exit 0" vm 'TC3_SOAK_N=5 bin/tc3 soak'
chk "stop exit 0" vm 'bin/tc3 stop'
chk "serve~stop 동안 프록시로 나간 요청 0건" bash -c "[ \"\$(docker exec $PX bash -c 'wc -l < /tmp/px.log')\" = $n0 ]"

echo "== 5. 처리량 (프록시 중계 자체: 업스트림 1 GiB, 같은 호스트)"
sp="$(vm "curl -s -o /dev/null -m 120 -x $PXURL -w '%{speed_download}' http://upstream.test/big.bin")"
echo "     $(awk -v s="${sp:-0}" 'BEGIN { printf "%.0f MB/s", s / 1e6 }')"
chk "1 GiB 를 120초 안에 중계" awk -v s="${sp:-0}" 'BEGIN { exit !(s * 120 >= 1073741824) }'

echo "== 프록시 로그: 접속한 목적지"
docker exec $PX bash -c "awk '{print \$4, \$5}' /tmp/px.log | sed -E 's#(https?://[^/]+)/.*#\1#' | sort | uniq -c | sort -rn" | tee "$OUT/destinations.txt"
docker exec $PX cat /tmp/px.log > "$OUT/proxy.log"
echo
echo "== proxy-sim: $NPASS ok, $NFAIL fail  (로그 $LOG)"
(( NFAIL == 0 ))

# TEST ONLY — "깨끗한 시험용 VM" 흉내: SSH 접속 가능한 최소 Ubuntu 22.04 (pip·venv·furiosa 스택 없음)
#   bin/tc3 install 이 실제로 하는 일(기본 패키지 apt, Furiosa APT 저장소 등록, 드라이버/smi 설치, venv + uv 로 furiosa-llm 설치)을
#   컨테이너에서 끝까지 검증하기 위함. 컨테이너에서 설치할 수 없는 것(드라이버 DKMS, WSL 커널 헤더)은 로컬 더미 deb 로 대체하고,
#   NPU 동작은 furiosa-smi/lspci 스텁이, furiosa-llm 은 가짜 pip 패키지(tests/stubs/fake-furiosa-llm)가 흉내낸다.
#   docker build -t tc3-vm-sim -f tests/vm-sim/Dockerfile .
#   docker run -d --name tc3-vm-sim --hostname etri-llm-test -p 127.0.0.1:2222:22 -v <pubkey>:/tmp/authorized_keys:ro \
#     -v <kit repo>:/srv/tc3-kit.git:ro -v <models>/Llama-3.1-8B-Instruct:/models/Llama-3.1-8B-Instruct:ro tc3-vm-sim

# --- 더미 deb (설치 불가 항목 대체) ---
FROM ubuntu:22.04 AS fakedebs
RUN apt-get update && apt-get install -y --no-install-recommends dpkg-dev && rm -rf /var/lib/apt/lists/*
RUN set -e; KV="$(uname -r)"; mkdir -p /opt/fakerepo; \
    for p in furiosa-driver-rngd furiosa-smi build-essential "linux-headers-$KV" "linux-modules-extra-$KV"; do \
      d="/tmp/$p"; mkdir -p "$d/DEBIAN"; \
      printf 'Package: %s\nVersion: 9999.0-sim\nArchitecture: all\nMaintainer: tc3 test\nDescription: tc3 vm-sim dummy for %s\n' "$p" "$p" > "$d/DEBIAN/control"; \
      dpkg-deb --build "$d" "/opt/fakerepo/${p}_9999.0-sim_all.deb" >/dev/null; \
    done; \
    cd /opt/fakerepo && dpkg-scanpackages . /dev/null > Packages 2>/dev/null

# --- 깨끗한 VM ---
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive TZ=Asia/Seoul
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server sudo python3 curl ca-certificates git tzdata procps util-linux iproute2 pciutils gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime && echo Asia/Seoul > /etc/timezone
COPY --from=fakedebs /opt/fakerepo /opt/fakerepo
RUN echo 'deb [trusted=yes] file:/opt/fakerepo ./' > /etc/apt/sources.list.d/tc3-vm-sim-fake.list
# 시험 VM 사용자와 같은 형태의 일반 사용자 (sudo 암호 없음 — 리허설 자동화용)
RUN useradd -m -s /bin/bash etri && echo 'etri ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/etri \
    && mkdir -p /run/sshd /home/etri/.ssh && chmod 700 /home/etri/.ssh && chown etri:etri /home/etri/.ssh \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && printf '[safe]\n\tdirectory = *\n' > /home/etri/.gitconfig && chown etri:etri /home/etri/.gitconfig
# NPU 스텁 (하드웨어 흉내) + install 이 설치할 가짜 furiosa-llm 패키지 위치 (clone 된 키트 안)
COPY tests/stubs/furiosa/furiosa-smi tests/stubs/furiosa/lspci /usr/local/bin/
RUN chmod +x /usr/local/bin/furiosa-smi /usr/local/bin/lspci \
    && printf '%s\n' 'TC3_FURIOSA_PIP_SPEC=/home/etri/tc3-kit/tests/stubs/fake-furiosa-llm' \
         'TC3_FURIOSA_DRIVER_PIN=9999.0-sim' 'TC3_FURIOSA_SMI_PIN=9999.0-sim' 'TC3_FURIOSA_LLM_PIN=2026.4.0' >> /etc/environment \
    && mkdir -p /models/furiosa-ai/Llama-3.1-8B-Instruct \
    && echo '{"model":"Llama-3.1-8B-Instruct","note":"vm-sim stub artifact"}' > /models/furiosa-ai/Llama-3.1-8B-Instruct/artifact.json \
    && echo stub > /models/furiosa-ai/Llama-3.1-8B-Instruct/model.fxb \
    && echo "furiosa-ai/Llama-3.1-8B-Instruct@v2026.4 (vm-sim stub)" > /models/furiosa-ai/Llama-3.1-8B-Instruct.tc3_source
EXPOSE 22
CMD ["bash", "-c", "install -o etri -g etri -m 600 /tmp/authorized_keys /home/etri/.ssh/authorized_keys && exec /usr/sbin/sshd -D -e"]

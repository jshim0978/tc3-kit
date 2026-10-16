# TEST ONLY — 시험용 VM 흉내 (SSH 접속 가능한 Ubuntu 22.04 + furiosa 스텁). tc3-capture-vm.ps1 리허설용.
#   docker build -t tc3-vm-sim -f tests/vm-sim/Dockerfile .
#   docker run -d --name tc3-vm-sim -p 2222:22 -v <pubkey>:/tmp/authorized_keys:ro \
#     -v <kit repo>:/srv/tc3-kit.git:ro -v <models>/Llama-3.1-8B-Instruct:/models/Llama-3.1-8B-Instruct:ro tc3-vm-sim
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive TZ=Asia/Seoul
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server sudo python3 python3-pip curl jq pciutils ca-certificates git tzdata procps util-linux iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install --no-cache-dir requests safetensors numpy \
    && ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime && echo Asia/Seoul > /etc/timezone
# 시험 VM 사용자와 같은 형태의 일반 사용자 (sudo 가능)
RUN useradd -m -s /bin/bash etri && echo 'etri ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/etri \
    && mkdir -p /run/sshd /home/etri/.ssh && chmod 700 /home/etri/.ssh && chown etri:etri /home/etri/.ssh \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && printf '[safe]\n\tdirectory = *\n' > /home/etri/.gitconfig && chown etri:etri /home/etri/.gitconfig
# furiosa 스텁 (furiosa-llm/furiosa-smi/lspci) + 가짜 서버 + furiosa-llm 버전 메타데이터
COPY tests/stubs/fake_openai.py /usr/local/fake_openai.py
COPY tests/stubs/furiosa/furiosa-llm tests/stubs/furiosa/furiosa-smi tests/stubs/furiosa/lspci /usr/local/bin/
RUN chmod +x /usr/local/bin/furiosa-llm /usr/local/bin/furiosa-smi /usr/local/bin/lspci \
    && SP="$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" \
    && mkdir -p "$SP/furiosa_llm-2026.4.0.dist-info" \
    && printf 'Metadata-Version: 2.1\nName: furiosa-llm\nVersion: 2026.4.0\n' > "$SP/furiosa_llm-2026.4.0.dist-info/METADATA" \
    && mkdir -p /models/furiosa-ai/Llama-3.1-8B-Instruct \
    && echo '{"model":"Llama-3.1-8B-Instruct","note":"vm-sim stub artifact"}' > /models/furiosa-ai/Llama-3.1-8B-Instruct/artifact.json \
    && echo stub > /models/furiosa-ai/Llama-3.1-8B-Instruct/model.fxb \
    && echo "furiosa-ai/Llama-3.1-8B-Instruct@v2026.4 (vm-sim stub)" > /models/furiosa-ai/Llama-3.1-8B-Instruct/.tc3_source \
    && hostname > /dev/null
EXPOSE 22
CMD ["bash", "-c", "install -o etri -g etri -m 600 /tmp/authorized_keys /home/etri/.ssh/authorized_keys && exec /usr/sbin/sshd -D -e"]

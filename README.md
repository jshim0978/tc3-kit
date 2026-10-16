# tc3-kit — TC3 「초거대AI 모델 검증 수」 공인인증시험 수행 키트

AI반도체 클라우드 플랫폼(openKcloud, DUT1)의 OpenStack VM 위에서 **Llama-3.1-8B-Instruct** 가 실행·운영됨을
시험원 앞에서 재현하고, 단계별 CLI 출력을 증빙 파일로 남기는 도구입니다.
절차서의 단계 번호(1~11)와 명령이 1:1로 대응하며, 로컬(Mac Docker)과 시험용 VM(RNGD/L40S)에서 **같은 명령**으로 돌아갑니다.

```
bin/tc3 <command> [--backend furiosa|vllm|llamacpp|mock]

  install       패키지/드라이버/이미지 설치·확인 (idempotent)
  fetch-model   모델 가중치·artifact 다운로드
  preflight     시험 전 점검 (가속기·furiosa-llm·가중치·포트·파이썬 패키지) — 증빙에 기록 안 함
  platform      [1~3] 플랫폼 증빙 (openstack CLI 있으면 자동, 없으면 Horizon 캡처 안내)
  env           [4]   가속기 PCI/드라이버/실행환경 확인
  model-size    [5]   모델 파라미터 수 산출 (safetensors 텐서 합산 = 8,030,261,248)
  serve         [6]   추론 서버 기동 → 준비 대기 → 적재 후 가속기 상태
  verify        [7~9] /v1/models, 한국어·영어 고정 프롬프트 추론
  soak          [10]  연속 N회 요청 (성공률·p50/p95)
  stop          [11]  서버 정지·원복
  report        evidence → report.md / summary.json (판정 증빙 4종)
  all           env → model-size → serve → verify → soak → stop → report
  status        현재 run 의 단계별 결과
```

## 구성

```
tc3-kit/
├── bin/tc3                  진입점 (bash)
├── lib/common.sh            로그·증빙 캡처(capture)·상태 기록(record)
├── lib/backend_furiosa.sh   RNGD + furiosa-llm        ← 시험 본선 (DUT1 VM etri-llm-test, m1.large.rngd)
├── lib/backend_vllm.sh      L40S + vLLM docker        ← 예비
├── lib/backend_llamacpp.sh  로컬: llama.cpp + Llama-3.1-8B-Instruct GGUF (CPU 실추론)
├── lib/backend_mock.sh      로컬: 내장 mock 서버 (다운로드 없음, 흐름 검증)
├── scripts/tc3_soak.py            연속 요청 시험
├── scripts/tc3_count_params.py    파라미터 수 산출
├── scripts/tc3_report.py          report.md 생성
├── scripts/mock_openai_server.py  mock 서버
├── scripts/make_fixture_model.py  로컬용 합성 safetensors
├── docker/Dockerfile.tester       로컬 "VM 역할" 컨테이너 (Ubuntu 22.04)
├── docker/compose.local.yml       로컬 구성 (llama.cpp 서버 + tester)
├── tc3.env.example                설정 템플릿 → tc3.env
└── evidence/<YYYYMMDD-HHMMSS>-<backend>/   stepNN_*.log, server.log, soak_result.csv, report.md, summary.json
```

백엔드별로 다른 것은 **4(가속기 확인)·5의 artifact 보조·6(서버 기동)·11(정지)** 뿐이고, 클라이언트 절차(7~10)는 공통입니다.
로컬 백엔드(`llamacpp`, `mock`)는 가속기 관련 단계를 `SIMULATED` 로 기록하며, report 에 "공인시험 증빙으로 사용 불가"가 명시됩니다.

## 빠른 시작

### A. 로컬 — 흐름만 (1분, 다운로드 없음)
```bash
cp tc3.env.example tc3.env
TC3_BACKEND=mock TC3_FIXTURE=1 TC3_SOAK_N=20 bin/tc3 all
```
Docker 로 돌리려면:
```bash
docker compose -f docker/compose.local.yml run --rm --no-deps tester all --backend mock
```

### B. 로컬 — 실제 Llama-3.1-8B-Instruct 로 (Mac, Docker)
`docker/compose.local.yml` 이 llama.cpp 서버(GGUF Q4_K_M ≈ 4.9 GB 자동 다운로드)와 tester 를 띄웁니다.
Docker Desktop 메모리 ≥ 10 GB 권장. CPU 추론이라 느리므로 소크는 10회로.
```bash
TC3_SOAK_N=10 docker compose -f docker/compose.local.yml up --abort-on-container-exit --exit-code-from tester
```
파라미터 수 단계까지 **실측**하려면 원본 safetensors(16 GB, HF gated)를 `models/` 에 받고 `TC3_FIXTURE=0`:
```bash
pip install -U "huggingface_hub[cli]"
# hf >= 1.0: --include 는 패턴마다 반복 (한 번에 여러 개 쓰면 첫 패턴 외에는 무시됨). unsloth = meta-llama 와 같은 가중치의 비-gated 미러
hf download unsloth/Meta-Llama-3.1-8B-Instruct --local-dir models/Llama-3.1-8B-Instruct \
    --include "*.json" --include "*.safetensors"
TC3_FIXTURE=0 TC3_SOAK_N=10 docker compose -f docker/compose.local.yml up --abort-on-container-exit --exit-code-from tester
```
(Mac 에서 더 빠르게: `brew install llama.cpp` 후 `llama-server -hf bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M --alias Llama-3.1-8B-Instruct --port 8000`
으로 Metal 가속 서버를 띄우고, `TC3_BACKEND=llamacpp TC3_API_URL=http://127.0.0.1:8000 bin/tc3 all` 을 Mac 에서 직접 실행.)


### B-2. Windows PC 에서 실제 터미널 캡처까지 자동 (tc3-capture.ps1)
Docker Desktop 이 떠 있는 Windows 에서 아래 한 줄이면 서버 기동 → 절차 4~12 실행 → **단계마다 터미널 창을 실제 화면 캡처**(PNG) 합니다.
```powershell
cd $HOME\repos\tc3-kit
Set-ExecutionPolicy -Scope Process Bypass -Force; .\tc3-capture.ps1          # 소크 10회, fixture
.\tc3-capture.ps1 -RealWeights   # models\Llama-3.1-8B-Instruct 에 원본 safetensors 가 있으면 파라미터 수 실측
```
결과: `captures\<timestamp>\TC3_stepNN_*.png` (창 캡처) + `.txt`(전체 출력) + `evidence\<run>\`(키트 증빙). 창을 넓게(가로 140열 이상) 띄우고 실행 중 다른 창을 앞으로 가져오지 마세요 — 전면 창을 찍습니다.

### C. 시험용 VM (RNGD, 본선) — 공인시험 당일 흐름
```bash
# 0) VM 접속 (코엑스IDC → master3 → VM)  ※ ~/.ssh/config 에 llmvm 정의
ssh llmvm

# 1) 키트 받기
git clone https://github.com/<ORG>/tc3-kit.git && cd tc3-kit
cp tc3.env.example tc3.env            # TC3_BACKEND=furiosa (기본값)

# 2) 사전 준비 (리허설 때 1회; 당일은 확인만)
bin/tc3 install                       # 드라이버·furiosa-smi·furiosa-llm 확인(없으면 설치)
HF_TOKEN=hf_xxx bin/tc3 fetch-model   # 원본 가중치 + RNGD artifact → /models

# 3) 시험 (단계별로 화면 캡처)
bin/tc3 preflight    # 사전 점검 (✗ 가 있으면 해결 후 진행)
bin/tc3 env          # [4]
bin/tc3 model-size   # [5]
bin/tc3 serve        # [6]
bin/tc3 verify       # [7~9]
bin/tc3 soak         # [10]
bin/tc3 stop         # [11]
bin/tc3 report       # report.md
# 또는 한 번에: bin/tc3 all
```
플랫폼 증빙 [1~3] 은 Horizon(또는 master3 의 openstack CLI)에서 캡처합니다: Hypervisors / Flavor `m1.large.rngd` 의 `pci_passthrough:alias` / Instance `etri-llm-test` 의 Status·Host·IP.

## 검증 · 런북
- `tests/run_scenarios.sh` — Ubuntu 22.04 컨테이너에서 47개 시나리오(정상·고장 주입·운영 실수) 자동 검증:
  `docker compose -f docker/compose.local.yml run --rm --no-deps -T --entrypoint bash tester /kit/tests/run_scenarios.sh`
- `docs/VM_RUNBOOK.md` — 리허설 체크리스트, SDK 버전별 결정표, 원복(wipe), 당일 장애 대응
- `tc3-capture-vm.ps1` — VM 에서 SSH 로 절차를 실행하며 단계별 터미널 화면 캡처 (`tests/vm-sim` 으로 리허설 가능)

## 증빙(evidence) 규칙
- 모든 단계는 `capture` 로 실행되어 **화면에 `$ 명령` → 출력** 순으로 보이고, 같은 내용이 `stepNN_<slug>.log` 에
  헤더(시각·호스트·사용자·백엔드·명령·종료코드)와 함께 저장됩니다. 시험원 화면 캡처와 로그 파일이 1:1 로 대응합니다.
- `status.tsv` 에 단계별 PASS/FAIL/SIMULATED/MANUAL 이 기록되고, `report.md` 가 판정 증빙 4종(A 플랫폼 / B 모델 크기 / C 실행 / D 운영)으로 집계합니다.
- 판정 기준: A = VM ACTIVE + 가속기 인식, B = 파라미터 수 ≥ `TC3_MIN_PARAMS`(8e9), C = /v1/models id 일치 + 한/영 응답 비어있지 않음, D = 소크 성공률 100 %.

## 설정 (`tc3.env`)
`tc3.env.example` 참고. 환경변수가 파일보다 우선합니다 (`TC3_BACKEND=mock bin/tc3 all`).
주요 항목: `TC3_BACKEND`, `TC3_API_URL`/`TC3_PORT`, `TC3_MODEL_NAME`, `TC3_MODEL_DIR`(safetensors), `TC3_ARTIFACT_DIR`(RNGD),
`TC3_DEVICES`(`npu:0:*`), `TC3_SOAK_N`(100), `TC3_READY_TIMEOUT`(900 s), `HF_TOKEN`, `TC3_FIXTURE`.

## 문제 해결
- `serve` 준비 시간 초과 → `evidence/<run>/server.log` 확인. furiosa 는 첫 기동 시 artifact 로딩에 수 분 걸릴 수 있음 (`TC3_READY_TIMEOUT` 상향).
- `env` 에서 `lspci | grep -i furiosa` 가 비면 VM 에 NPU 가 패스스루되지 않은 것 → flavor/호스트 확인.
- `model-size` 가중치 없음 → `fetch-model` (gated 모델은 HF 라이선스 동의 + `HF_TOKEN`).
- `soak` 일부 실패 → `soak_result.csv` 의 error 열 확인 (타임아웃이면 `TC3_SOAK_TIMEOUT` 상향).

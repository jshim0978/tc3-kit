# HANDOFF — TC3 로컬 시뮬레이션: 이 PC에서 Docker 로 실행하고 실제 터미널 창을 캡처하기

> 받는 쪽: 이 PC(Windows, 사용자 `etri-jws`)에서 도는 Claude Code 세션. 이 문서만 보고 끝까지 수행할 수 있어야 한다.
> 작성: 2026-10-16, 이전 세션(클라우드)에서 준비한 상태를 그대로 넘김.

## 0. 한 줄 목표
`C:\Users\etri-jws\repos\tc3-kit` 의 시험 키트를 **Docker(VM 대용) 위의 실제 Llama-3.1-8B-Instruct** 로 절차 4~12 까지 돌리고, **단계마다 실제 터미널 창을 PNG 로 캡처**해서 `captures\<timestamp>\` 에 남긴다. 캡처와 `evidence\<run>\` 를 zip 으로 묶어 사용자에게 돌려준다. (문서 삽입은 이전 세션이 맡는다 — 하지 않아도 됨.)

## 1. 배경 (왜 하는가)
- 과제 "AI반도체 클라우드 플랫폼 구축 및 최적화 기술 개발" 2차년도 공인인증시험(시험기관 GERI, 11/2~6) 중 **TC3 「초거대AI 모델 검증 수」**: DUT1(openKcloud) OpenStack VM 위에서 오픈소스 초거대 모델 1종(Llama-3.1-8B-Instruct)이 실행·운영됨을 CLI 화면 캡처로 입증한다.
- 당일 VM(RNGD NPU, `etri-llm-test`, 192.168.90.239)에서는 `git clone tc3-kit → bin/tc3 env/model-size/serve/verify/soak/stop/report` 순으로 수행한다. **지금 할 일은 그 절차를 이 PC 의 Docker 에서 미리 똑같이 돌려 실제 캡처를 확보하는 것** (절차서 초안에 넣을 "로컬 시뮬레이션" 캡처).
- 키트는 백엔드 플러그인 구조: `furiosa`(VM 본선) / `vllm`(예비) / `llamacpp`(이 PC 로컬: llama.cpp 서버에 실제 8B GGUF) / `mock`. 클라이언트 절차(7~10)는 공통. 로컬에서는 가속기 단계(4·6·11)가 `SIMULATED` 로 기록되고 report 에 "공인시험 증빙 아님"이 찍힌다 — 정상.

## 2. 현재 상태 (이미 되어 있는 것)
- 키트 파일: `C:\Users\etri-jws\repos\tc3-kit` (git 저장소 아님 — 파일만 복사됨). 구성: `bin/tc3`(bash CLI), `lib/backend_*.sh`, `scripts/*.py`, `docker/Dockerfile.tester`, `docker/compose.local.yml`, `tc3.env`(furiosa 기본값이지만 compose 가 환경변수로 llamacpp 를 주입), `tc3-capture.ps1`(캡처 도구), `README.md`.
- 모든 텍스트 파일은 **LF** 줄바꿈. 컨테이너(Linux)가 `bin/tc3` 를 실행하므로 CRLF 로 바뀌면 깨진다. git 을 쓰면 `git config core.autocrlf false` 먼저.
- Docker Desktop 설치돼 있음(실행 중인지 확인 필요). 이 PC 의 리눅스 샌드박스에서 mock 백엔드로 전 단계 통과를 확인했고, 클라우드에서는 llamacpp 백엔드로 실제 8B 로 전 단계 통과를 확인했다(파라미터 8,030,261,248, 한/영 추론 PASS, 소크 10/10). 즉 키트 자체는 검증됨.
- `docker/compose.local.yml`: `llm` 서비스 = `ghcr.io/ggml-org/llama.cpp:server` 가 `bartowski/Meta-Llama-3.1-8B-Instruct-GGUF` 의 `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf`(≈4.9 GB)를 HF 에서 받아 `--alias Llama-3.1-8B-Instruct --port 8000` 로 서빙(healthcheck 최대 15분). `tester` 서비스 = Ubuntu 22.04 + python(requests/safetensors/numpy), `..` 를 `/kit` 으로 마운트, entrypoint `/kit/bin/tc3`. 환경: `TC3_BACKEND=llamacpp`, `TC3_API_URL=http://llm:8000`, `TC3_FIXTURE=${TC3_FIXTURE:-1}`, `TC3_SOAK_N=${TC3_SOAK_N:-10}`.

## 3. 해야 할 일 (순서대로)

### 3-1. 사전 점검
```powershell
cd C:\Users\etri-jws\repos\tc3-kit
docker version                      # Server 섹션이 나와야 함 (안 나오면 Docker Desktop 실행 후 재시도)
docker info --format '{{.MemTotal}}' # 10 GB(10737418240) 이상 권장 — 부족하면 Docker Desktop > Settings > Resources 에서 올림
Get-Content -Raw bin/tc3 | % { if ($_ -match "`r`n") { "CRLF!" } else { "LF ok" } }
```
git 저장소로 만들어 절차 0(커밋 해시 확인)이 캡처에 찍히게 한다:
```powershell
git config --global core.autocrlf false   # 또는 --local (init 후)
git init; git add -A; git commit -m "tc3-kit local snapshot for capture run"
```

### 3-2. 실행 + 캡처 (핵심)
`tc3-capture.ps1` 이 전부 한다: tester 빌드 → `llm` 기동·healthy 대기 → 절차 4~12 를 `docker compose run --rm tester <step>` 로 한 단계씩 실행 → **단계마다 `Clear-Host` 후 명령줄 표시 → 실행 → 전면 창을 GDI 로 캡처**(`captures\<timestamp>\TC3_stepNN_*.png`) → `report.md`·evidence 디렉터리 캡처 → `llm` 정지.

**중요: 전면(foreground) 창을 찍는 도구이므로, Claude Code 의 내부 셸에서 실행하지 말고 "보이는 새 터미널 창"에서 실행해야 한다.** 예:
```powershell
# 새 Windows Terminal 창을 띄워 그 안에서 스크립트 실행 (창은 넓게: 140열×50행 이상 권장)
Start-Process wt.exe -ArgumentList "-d C:\Users\etri-jws\repos\tc3-kit powershell -NoExit -ExecutionPolicy Bypass -File .\tc3-capture.ps1"
# wt 가 없으면
Start-Process powershell -ArgumentList "-NoExit -ExecutionPolicy Bypass -File C:\Users\etri-jws\repos\tc3-kit\tc3-capture.ps1" -WorkingDirectory C:\Users\etri-jws\repos\tc3-kit
```
실행 중(15~25분, 첫 실행은 GGUF 다운로드 포함)에는 그 창이 가려지지 않게 둔다. 진행은 `captures\<timestamp>\` 에 PNG 가 늘어나는 것으로 확인하면 된다. 종료 시 창에 "완료 — 캡처: ..." 와 PNG 목록이 찍힌다.

옵션:
- 파라미터 수를 fixture(합성) 대신 **실측 8,030,261,248** 로 찍고 싶으면 원본 safetensors(16 GB)를 먼저 받고 `-RealWeights`:
  ```powershell
  pip install -U "huggingface_hub[cli]"
  huggingface-cli download unsloth/Meta-Llama-3.1-8B-Instruct --local-dir models\Llama-3.1-8B-Instruct --include config.json "*.safetensors" model.safetensors.index.json "tokenizer*"
  # 그 다음 tc3-capture.ps1 -RealWeights   (unsloth 는 meta-llama 와 동일 가중치의 비-gated 미러)
  ```
- 소크 횟수: `-SoakN 20` (CPU 추론이라 요청당 10~30 s).

### 3-3. 결과 확인 (합격 기준)
`captures\<timestamp>\` 에 아래 PNG 가 있어야 한다. 각각 열어 보고(이미지 확인), 아래 내용이 보이면 OK.

| 파일 | 보여야 하는 것 |
|---|---|
| `TC3_step00_docker_and_kit.png` | `docker version` Server 정보, `git log -1 --oneline` 커밋 해시 |
| `TC3_step06a_llm_server_ready.png` | `docker compose ps` 에 llm healthy, 로그 tail, `/v1/models` JSON 에 `"id": "Llama-3.1-8B-Instruct"`, `meta.n_params: 8030261312` |
| `TC3_step04_env.png` | `[tc3] WARN [step 04] env: SIMULATED — 로컬 환경 — 가속기 없음` |
| `TC3_step05_model_size.png` | fixture 면 `SIMULATED ... 196618 params`; RealWeights 면 `total parameters = 8,030,261,248 (8.03 B)` + `PASS` |
| `TC3_step06_serve.png` | `/health {"status":"ok"}`, `[step 06] serve: SIMULATED — 로컬 서버 준비됨` |
| `TC3_step07-09_verify.png` | `[step 07] models PASS id=Llama-3.1-8B-Instruct`, `[step 08] chat_ko PASS ... finish_reason=stop`, `[step 09] chat_en PASS` (창에는 마지막 부분만 보여도 됨 — 전체는 evidence 로그) |
| `TC3_step10_soak.png` | `success : 10/10 (100.0%)`, `latency p50/p95`, `[step 10] soak PASS` |
| `TC3_step11_stop.png` | `[step 11] stop: SIMULATED — 외부 로컬 서버는 tc3 가 정지하지 않음` |
| `TC3_step12_report.png`, `TC3_step12_report_md.png` | report.md: 종합 **SIMULATED**, B(모델 크기) PASS(RealWeights 시), C 의 07~09 PASS, D(운영) PASS |
| `TC3_step12b_evidence.png` | `evidence\<run>\` 파일 목록 + `tc3 status` 표 |
| `TC3_step13_cleanup.png` | `docker compose stop llm` |

추가 확인:
```powershell
Get-Content evidence\<run>\status.tsv        # 04/06/11 SIMULATED, 07~10 PASS (05 는 fixture=SIMULATED / real=PASS)
Get-Content evidence\<run>\report.md
```
실패(FAIL)가 있으면 해당 `evidence\<run>\stepNN_*.log` 와 `server.log` 를 보고 원인을 고친 뒤 **그 단계만** 다시 캡처해도 된다:
```powershell
# 예: verify 만 다시 (새 터미널 창에서)
docker compose -f docker/compose.local.yml up -d llm
docker compose -f docker/compose.local.yml run --rm tester verify
```
(단계별 재실행 시 캡처는 Win+PrtScn 또는 `tc3-capture.ps1` 의 Snap 함수를 참고해 직접 찍는다.)

### 3-4. 돌려줄 것
```powershell
Compress-Archive -Path captures\<timestamp>, evidence\<run> -DestinationPath TC3_PC캡처_<timestamp>.zip -Force
```
- `TC3_PC캡처_<timestamp>.zip` 과 함께 결과 요약(각 단계 PASS/SIMULATED, 파라미터 수, 소크 성공률·p50·p95, 문제 있었던 점)을 사용자에게 전달.
- 가능하면 `git add captures evidence -f` 는 하지 말 것(.gitignore 대상) — zip 으로만 전달.

## 4. 자주 걸리는 문제
- `the input device is not a TTY` → `docker compose run` 을 파이프/비대화형 셸에서 돌린 것. 보이는 터미널 창에서 직접 실행.
- `llm` 이 healthy 가 안 됨 → `docker compose -f docker/compose.local.yml logs llm`: HF 다운로드 실패(네트워크/프록시)면 재시도; 메모리 부족(OOM, exit 137)이면 Docker Desktop 메모리 ↑.
- `bin/tc3: cannot execute` / `$'\r': command not found` → CRLF 변환됨. `git config core.autocrlf false` 후 파일 다시 받거나 `(Get-Content bin/tc3 -Raw) -replace "`r`n","`n" | Set-Content -NoNewline bin/tc3` (lib/*.sh, scripts/*.py 도 동일).
- 캡처가 엉뚱한 창 → 스크립트 실행 중 다른 창이 전면에 있었음. 해당 단계만 다시 찍기.
- 캡처가 흐릿/잘림 → 터미널 창을 더 크게(최대화) 하고 재실행. DPI 는 스크립트가 `SetProcessDPIAware` 로 보정함.
- `huggingface-cli` 없음 → `pip install -U "huggingface_hub[cli]"`; 다운로드가 막히면 fixture 로 진행(절차 5 만 SIMULATED).

## 5. 하지 말 것
- `bin/tc3`, `lib/`, `scripts/`, `docker/` 의 내용을 바꾸지 말 것(시험 절차서와 1:1 대응). 버그로 보이면 고치되 무엇을 왜 바꿨는지 요약에 적을 것.
- 공유 서버/VM(192.168.90.x, 210.114.95.x, 101.79.0.102)에는 접속하지 말 것 — 이 작업은 **이 PC 로컬에서만** 한다.
- 캡처에 자격 증명·토큰이 보이지 않게 할 것(HF_TOKEN 등은 환경변수로만).

## 6. 참고: 키트 명령 요약
```
bin/tc3 env | model-size | serve | verify | soak | stop | report | status | all
docker compose -f docker/compose.local.yml {build tester | up -d llm | run --rm tester <cmd> | stop llm | logs llm}
```
README.md 의 B / B-2 절에 같은 내용이 있다.

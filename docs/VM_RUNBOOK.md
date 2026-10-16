# TC3 VM 런북 — 리허설 · 원복 · 시험 당일(11/3)

대상: DUT1(openKcloud) VM `etri-llm-test` (RNGD NPU, Ubuntu 22.04), 백엔드 `furiosa`.
원칙: **당일에는 확인과 실행만 한다.** 설치·다운로드·버전 결정은 리허설에서 끝내고 결과를 `tc3.env.example` 기본값에 커밋한다.

---

## 1. 시험 당일 절차 (캡처 순서)

| # | 명령 | 캡처 | 정상 결과 | 예상 소요 |
|---|---|---|---|---|
| 0 | `git clone <REPO> && cd tc3-kit && cp tc3.env.example tc3.env` | (선택) | clone 완료 | 10 s |
| 0b | `bin/tc3 preflight` | (선택, 내부 점검) | `preflight: 문제 없음` | 5 s |
| 4 | `bin/tc3 env` | ✔ | `PASS [step 04] env` — lspci `1ed2`, furiosa-smi info/status, furiosa-llm 버전 | 5 s |
| 5 | `bin/tc3 model-size` | ✔ | `total parameters = 8,030,261,248 (8.03 B)` + `PASS` | 10 s |
| 6 | `bin/tc3 serve` | ✔ | `PASS [step 06] serve` + `furiosa-smi status / ps` 에 furiosa-llm | 1–5 min |
| 7–9 | `bin/tc3 verify` | ✔ | 07 `id=Llama-3.1-8B-Instruct`, 08/09 `finish_reason=stop` PASS | 30 s |
| 10 | `bin/tc3 soak` | ✔ | `success : 100/100 (100.0%)`, p50/p95, PASS (진행이 줄 단위로 실시간 표시) | 2–5 min |
| 11 | `bin/tc3 stop` | ✔ | `server stopped (connection refused)` + `furiosa-smi ps` 비어 있음, PASS | 5–30 s |
| 12 | `bin/tc3 report` / `cat evidence/<run>/report.md` | ✔ | 종합 **PASS**, A~D | 2 s |

- 각 단계 첫 줄 `[tc3] run: evidence/<YYYYMMDD-HHMMSS>-furiosa backend: furiosa kit: <commit>` 으로 캡처와 증빙 로그가 1:1 로 연결된다.
- 모든 단계는 실패 시 종료코드 ≠ 0 과 `[tc3] FAIL ...` 한 줄 원인을 남긴다. 같은 단계를 다시 실행하면 같은 run 에 기록되고 `attempts.tsv`·report 의 "재수행 이력"에 남는다.
- 절차 1~3(플랫폼)은 Horizon 캡처 (Hypervisors / flavor `m1.large.rngd` 의 `pci_passthrough:alias` / 인스턴스 Status·Host·IP).

## 2. 리허설 체크리스트 (VM 제공 후)

1. **접속**: 이 PC → (점프 호스트) → VM. `~/.ssh/config` 에 `Host llmvm` 정의, 키 인증. `ssh llmvm hostname` 확인.
2. **기본 정보 기록**: `grep PRETTY /etc/os-release; uname -r; nproc; free -g; df -h / /models; date; timedatectl`.
3. **NPU / SDK 버전** — 아래 결정표의 입력:
   ```
   lspci -nn | grep -iE 'furiosa|1ed2'
   furiosa-smi info; furiosa-smi status; furiosa-smi ps
   command -v furiosa-llm; python3 -c "from importlib.metadata import version; print(version('furiosa-llm'))"
   apt list --installed 2>/dev/null | grep -i furiosa
   ```
4. **네트워크**: `curl -sI https://github.com https://huggingface.co https://pypi.org | grep HTTP` — 막혀 있으면 오프라인 반입(scp)으로 전환.
5. **키트**: `git clone` → `cp tc3.env.example tc3.env` → `bin/tc3 install` → `bin/tc3 fetch-model` → `bin/tc3 preflight`.
6. **전체 리허설 + 캡처**: 이 PC 에서
   `Start-Process wt.exe -ArgumentList '-w new --size 160,60 -d C:\Users\etri-jws\repos\tc3-kit powershell -NoExit -ExecutionPolicy Bypass -File .\tc3-capture-vm.ps1 -Target llmvm'`
   → `captures\<ts>-vm\` 에 단계별 PNG + VM 증빙(scp).
7. **문제 시나리오 점검** (실기기에서만 확인 가능한 것): serve 두 번 실행, serve 중 stop, stop 후 `furiosa-smi ps` 비었는지, soak 100회 소요시간, 서버 기동 시간(→ `TC3_READY_TIMEOUT` 여유 확인).
8. **결정 사항을 `tc3.env.example` 에 커밋** (venv 경로, artifact 경로/태그, devices) → 당일 `cp` 만으로 동일 설정.

### SDK 버전별 결정표 (developer.furiosa.ai, 2026-10 기준)

| 항목 | 2025.2–2025.3 | 2026.1 | 2026.2–2026.3 | 2026.4 |
|---|---|---|---|---|
| `--served-model-name` | 미지원 ⚠ | 미지원 ⚠ | 지원 | 지원 |
| `--devices` | `npu:0` | `npu:0` | `npu:0` | `npu:0` |
| artifact | `furiosa-ai/Llama-3.1-8B-Instruct@v2025.x` | `@v2026.1` | `@v2026.2` / `@v2026.3` | FXB 필요 → `furiosa-ai/Meta-Llama-3.1-8B-Instruct-FP8-dynamic@v2026.4` |
| `huggingface-cli` | 동작 | 동작 | 없음(`hf`) | 없음(`hf`) |

⚠ `--served-model-name` 미지원 버전이면 `/v1/models` id 가 `Llama-3.1-8B-Instruct` 와 달라 절차 7~10 이 FAIL 한다 → `preflight` 가 ✗ 로 막는다. 리허설에서 SDK 업그레이드(드라이버·smi·furiosa-llm 같은 릴리스로) 여부를 결정.
키트는 설치된 버전을 읽어 플래그를 자동 선택하고(`fetch-model` 은 맞는 태그를 자동 선택, 출처는 `<artifact 경로>.tc3_source` 에 기록), `preflight` 가 SDK import·버전·FXB 를 점검한다.
`bin/tc3 install` 은 SDK 가 쓰는 파이썬의 기존 패키지를 **업그레이드하지 않고** 없는 것만 설치한다 (furiosa-llm 의존성 보호).

## 3. 원복(wipe) — 리허설 후, 당일 전

**지운다 (시험 흔적)**
```
bin/tc3 stop                                  # 서버 정리 (이미 내려가 있으면 그대로 PASS)
cd ~ && rm -rf ~/tc3-kit                      # 키트·evidence·.server.pid 전부 (당일 git clone 으로 새로 받음)
rm -f /tmp/.tc3_capture_step.sh
history -c && rm -f ~/.bash_history           # (선택) 명령 이력
furiosa-smi ps                                # NPU 점유 프로세스 없음 확인
```
**남긴다 (사전 준비물 — README 계획: "리허설 때 1회, 당일은 확인만")**: 드라이버·furiosa-smi·furiosa-llm(venv), `/models/Llama-3.1-8B-Instruct`(원본 가중치), `/models/furiosa-ai/...`(artifact), 파이썬 패키지.
→ 완전 초기화(드라이버·모델까지 삭제)를 원하면 당일 `install`·`fetch-model`(수십 GB 다운로드)이 필요해 위험이 커진다 — **결정 필요**.

원복 확인: `ls ~/tc3-kit` 없음, `ls /models` 유지, `furiosa-smi ps` 비어 있음, `ss -ltn 'sport = :8000'` 비어 있음.

## 4. 당일 장애 대응

| 증상 | 원인 | 조치 |
|---|---|---|
| `bash: bin/tc3: Permission denied` | 실행 권한 | `bash bin/tc3 <cmd>` 로 실행 (키트는 100755 로 커밋됨) |
| preflight `✗ 포트 8000 사용 중` | 이전 서버/다른 프로세스 | `bin/tc3 stop` → 그래도면 `ss -ltnp 'sport = :8000'` 로 PID 확인 후 정리 |
| serve 가 즉시 FAIL "준비 전에 종료됨" | furiosa-llm 기동 오류 | 화면의 server.log 꼬리 확인 (장치 점유·artifact 버전 불일치·인자 오류) |
| serve "준비 시간 초과" | 적재 지연 | `bin/tc3 stop` 후 `TC3_READY_TIMEOUT=1800 bin/tc3 serve` |
| 07 FAIL `id='...'` | served-model-name 미적용 | SDK 버전 확인 (결정표) |
| soak 일부 ERR | 타임아웃/서버 이상 | `soak_result.csv` error 열, `TC3_SOAK_TIMEOUT` 상향 후 재실행 |
| stop FAIL "내려가지 않음" | 프로세스 잔존 | `furiosa-smi ps`, `pkill -f 'furiosa-llm serve'` 후 `bin/tc3 stop` 재실행 |
| 증빙이 이전 run 에 섞임 | — | 날짜·백엔드가 다르면 자동으로 새 run. 같은 날 새로 시작하려면 `rm evidence/.current_run` |

## 5. 검증 근거

- `tests/run_scenarios.sh`: Ubuntu 22.04 컨테이너에서 47개 시나리오 (정상 흐름, furiosa/vllm 스텁 경로 + 실제 가중치, 서버 즉시 사망·시간 초과·이중 기동·포트 점유·SIGTERM 무시, 잘못된 모델 id·비JSON·빈 응답·간헐 실패·도중 사망, CRLF/BOM/따옴표 tc3.env, 프록시, 비루트, LANG=C, 심볼릭 링크, 백엔드 전환, 날짜 넘김, 실제 HF 다운로드).
- 실행: `docker compose -f docker/compose.local.yml run --rm --no-deps -T --entrypoint bash tester /kit/tests/run_scenarios.sh`

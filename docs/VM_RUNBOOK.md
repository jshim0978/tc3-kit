# TC3 VM 런북 — 리허설 · 완전 원복 · 시험 당일(11/3)

대상: DUT1(openKcloud) VM `etri-llm-test` (RNGD NPU, Ubuntu 22.04), 백엔드 `furiosa`.
원칙 (2026-10-16 결정): **리허설 후 VM 을 처음 받은 상태로 완전 원복**(드라이버·SDK·모델 포함) → 시험 당일은 깨끗한 VM 에서
`install` · `fetch-model` 부터 수행한다. 그래서 **버전은 반드시 고정**하고(아래 2절), 당일 소요 시간·네트워크를 리허설에서 실측한다.

---

## 1. 시험 당일 절차 (캡처 순서)

| # | 명령 | 정상 결과 | 예상 소요 (리허설에서 실측해 채움) |
|---|---|---|---|
| 0 | `git clone <REPO> && cd tc3-kit && cp tc3.env.example tc3.env` | clone 완료, `git log -1` 커밋 | 10 s |
| 0c | `bin/tc3 install` | `[1/6]~[6/6]` 후 `PASS install 완료` (종료코드 0) — **종료코드 3 이면 재부팅 필요** | 5–15 min (apt + pip ≈ 수 GB) |
| 0c' | (3 이면) `sudo reboot` → 재접속 → `bin/tc3 install` | 설치된 항목은 확인만, `PASS install 완료` | 2–5 min |
| 0e | `bin/tc3 hf-login` | **시험원이 HF 토큰 붙여넣기**(화면에 안 보임) → `PASS HF 접근 확인: <계정> → meta-llama/Llama-3.1-8B-Instruct` | 30 s |
| 0d | `bin/tc3 fetch-model` | 디스크 여유 확인 → 원본 가중치 16 GB + artifact → `PASS fetch-model 완료` | 5–40 min (회선 속도) |
| 0b | `bin/tc3 preflight` | `preflight: 문제 없음` (고정 버전 일치·SDK import·FXB·포트) | 5 s |
| 4 | `bin/tc3 env` | `PASS [step 04] env` — lspci `1ed2`, furiosa-smi info/status, furiosa-llm 버전 | 5 s |
| 5 | `bin/tc3 model-size` | `total parameters = 8,030,261,248 (8.03 B)` + `PASS` | 10 s |
| 6 | `bin/tc3 serve` | `PASS [step 06] serve` + `furiosa-smi status / ps` 에 furiosa-llm | 1–5 min |
| 7–9 | `bin/tc3 verify` | 07 `id=Llama-3.1-8B-Instruct`, 08/09 `finish_reason=stop` PASS | 30 s |
| 10 | `bin/tc3 soak` | `success : 100/100 (100.0%)`, p50/p95, PASS (줄 단위 실시간 표시) | 2–5 min |
| 11 | `bin/tc3 stop` | `server stopped (connection refused)` + `furiosa-smi ps` 비어 있음, PASS | 5–30 s |
| 12 | `bin/tc3 report` / `cat evidence/<run>/report.md` | 종합 **PASS**, A~D | 2 s |
| 끝 | `bin/tc3 hf-logout` (캡처 불필요) | 저장된 토큰 삭제 — 공용 VM 에 토큰을 남기지 않음 | 2 s |

- install·fetch-model 의 전체 출력은 증빙 `evidence/<run>/prep_install.log`, `prep_fetch_model.log` 에도 남는다.
- 각 단계 첫 줄 `[tc3] run: evidence/<YYYYMMDD-HHMMSS>-furiosa backend: furiosa kit: <commit>` 으로 캡처와 증빙이 1:1 연결.
- 실패 시 종료코드 ≠ 0 과 `[tc3] FAIL ...` 한 줄 원인. 같은 단계를 다시 하면 같은 run 에 기록되고 report "재수행 이력"에 남는다.
- 절차 1~3(플랫폼)은 Horizon 캡처.
- 이 PC 에서 같은 순서로 실행·캡처: `tc3-capture-vm.ps1 -Target llmvm -Clone -RepoUrl <REPO> -Install -HfLogin -Fetch -AllowReboot`
  (hf-login 단계에서 알림음 → 사람이 그 창에 토큰을 붙여넣고 Enter. 자동화는 토큰을 입력하지 않는다)
- 원본 가중치는 공식 `meta-llama/Llama-3.1-8B-Instruct` (gated) — 라이선스 동의한 HF 계정 토큰으로 `bin/tc3 hf-login` (2026-10-16 결정).
  `hf auth login` 대신 쓰는 이유: hub 1.x 의 `hf auth login` 은 브라우저 로그인 메뉴(화살표 선택)가 먼저 떠 원격 터미널에서 실수 여지가 있음.
  `hf-login` 은 숨김 입력으로 받은 토큰을 `huggingface_hub.login()` 에 stdin 으로 넘겨 같은 위치(`~/.cache/huggingface/token`)에 저장한다.

## 2. 버전 고정 (당일 install 이 설치하는 조합 — `tc3.env.example`)

깨끗한 VM 에 당일 설치하므로 **리허설에서 검증한 조합만** 설치되도록 고정한다. Furiosa 는 2026.5 베타를 이미 공개했다 —
고정하지 않으면 11/3 에 검증되지 않은 새 릴리스가 설치될 수 있다. `preflight` 가 설치 버전 = 고정 버전인지 확인한다.

| 조합 | 드라이버 (apt) | furiosa-smi (apt) | furiosa-llm (pip) | artifact (HF) | 비고 |
|---|---|---|---|---|---|
| **A [기본]** | 2026.3.1 | 2026.1.1-3 | 2026.3.0 | `furiosa-ai/Llama-3.1-8B-Instruct` @ `v2026.3` | BF16 원본 정밀도 |
| B | 2026.4.0 | 2026.4.0-3 | 2026.4.0 | `furiosa-ai/Meta-Llama-3.1-8B-Instruct-FP8-dynamic` @ `v2026.4` | FP8 양자화, 2026.4 는 FXB 필요 |

- 두 조합 모두 실제 pkg.dev 저장소에서 의존성 해석 확인(apt simulate), PyPI 에서 Python 3.10 해석 확인(uv dry-run, CUDA 패키지 0개).
- 실기기에서만 확인 가능: 카드 펌웨어와 드라이버 호환, 실제 기동·추론. **리허설 결과로 A/B 확정 후 커밋.**
- `--served-model-name` 은 2026.2.0 이상만 지원 → 2025.x/2026.1 은 절차 7~10 이 FAIL 하므로 선택지에서 제외 (preflight 가 ✗).

## 3. 리허설 체크리스트 (VM 제공 후)

1. **접속**: 이 PC → (점프 호스트) → VM. `~/.ssh/config` 에 `Host llmvm`, 키 인증. `ssh llmvm hostname`.
   리허설 자동화를 위해 sudo 가 암호를 묻지 않아야 한다(또는 sudo 가 필요한 install 은 사용자가 직접 실행) — 자동화가 암호를 입력하지 않는다.
2. **기준 스냅샷 (가장 먼저, 아무것도 설치하기 전)**:
   `scp tools/vm-state.sh llmvm:/var/tmp/ && ssh llmvm '/var/tmp/vm-state.sh snapshot /var/tmp/tc3-baseline.txt'`
3. **기본 정보**: `grep PRETTY /etc/os-release; uname -r; nproc; free -g; df -h / ; timedatectl; lspci -nn | grep -iE 'furiosa|1ed2'`
   (커널 < 6.3 이면 install 이 HWE 커널 설치 후 재부팅을 요구 — 원복 시 커널 처리 주의, 4절)
4. **네트워크**: `curl -sI https://github.com https://huggingface.co https://pypi.org http://asia-northeast3-apt.pkg.dev | grep HTTP`
   + 프록시 여부. 막혀 있으면 오프라인 반입 계획으로 전환.
5. **HF 원본 가중치 접근** (결정: 공식 meta-llama): 사용자가 Llama 3.1 라이선스 동의한 HF 계정을 제공 → install 후 `bin/tc3 hf-login` 에서 사용자가 토큰 입력.
   원복 때 `~/.cache/huggingface`(토큰 포함)가 지워지므로 시험 당일 다시 `hf-login` 한다.
6. **당일과 같은 전체 흐름 + 캡처** (이 PC, 보이는 창 — hf-login 단계에서 사용자가 토큰 입력):
   `Start-Process wt.exe -ArgumentList '-w new --size 160,60 -d C:\Users\etri-jws\repos\tc3-kit powershell -NoExit -ExecutionPolicy Bypass -File .\tc3-capture-vm.ps1 -Target llmvm -Clone -RepoUrl <REPO> -Install -HfLogin -Fetch -AllowReboot'`
   → install/fetch-model **소요 시간 실측**해서 1절 표에 기록.
7. **실기기 확인 항목**: serve 두 번, serve 중 stop, stop 후 `furiosa-smi ps` 빈 것, soak 100회 시간, 서버 기동 시간(`TC3_READY_TIMEOUT` 여유),
   `furiosa-smi ps` 출력 형식, Ray 데몬 잔존 여부(조합 A).
8. **결정 사항 커밋** (조합 A/B, HF 저장소, 소요 시간) → 저장소 push → 4절 원복 → 원복 후 같은 흐름을 한 번 더 돌려 "깨끗한 상태에서 재현" 확인 → 다시 원복.

## 4. 완전 원복 (리허설 후 · 당일 전) — `tools/vm-state.sh`

기준 스냅샷과 비교해 **리허설 중 생긴 것만** 지운다: 서버 프로세스 → 추가된 apt 패키지(드라이버·smi·헤더·python3-venv 등) purge →
추가된 apt 저장소·키 → pip --user → 키트·venv·캐시(HF/pip/uv)·`/models` 의 새 항목 → 홈의 새 항목(.ssh 제외) → 남은 차이 표시.

```
ssh llmvm 'cp ~/tc3-kit/tools/vm-state.sh /var/tmp/ 2>/dev/null; /var/tmp/vm-state.sh wipe /var/tmp/tc3-baseline.txt'            # 계획만 (dry-run)
ssh llmvm '/var/tmp/vm-state.sh wipe /var/tmp/tc3-baseline.txt --yes --history'                                                  # 실행
ssh llmvm 'sudo reboot'   # 드라이버 모듈이 메모리에 남아 있으면 (wipe 가 알려줌)
ssh llmvm '/var/tmp/vm-state.sh diff /var/tmp/tc3-baseline.txt'                                                                  # "차이 없음" 확인
```
- 실행 중인 커널 패키지는 지우지 않는다(리허설에서 HWE 커널이 설치됐다면 기준 커널로 되돌리는 것은 별도 결정 — 원격 VM 부팅 위험).
- 버전만 바뀐 기존 패키지는 되돌리지 않고 보고만 한다.
- 원복 확인 후 `/var/tmp/tc3-baseline.txt`·`vm-state.sh` 도 지우면 완전히 흔적 없음.

## 5. 당일 장애 대응

| 증상 | 원인 | 조치 |
|---|---|---|
| `bash: bin/tc3: Permission denied` | 실행 권한 | `bash bin/tc3 <cmd>` (키트는 100755 로 커밋됨) |
| install `Could not get lock` | 부팅 직후 자동 업데이트 | install 이 최대 10분 대기 — 그대로 둔다 |
| install 종료코드 3 | 커널/드라이버 적재 | `sudo reboot` → 재접속 → `bin/tc3 install` |
| install "PCI 에 FuriosaAI 장치 없음" | NPU 패스스루 문제 | 재부팅으로 해결 안 됨 — 인프라(flavor/호스트) 확인 |
| fetch-model "HF 접근 불가(gated)" | 로그인 안 함/라이선스 미동의 | `bin/tc3 hf-login` 후 재실행 |
| hf-login "로그인 실패" | 토큰 오타·만료·권한 | huggingface.co/settings/tokens 에서 read 토큰 확인 후 재입력 |
| fetch-model "디스크 여유 부족" | /models 공간 | 볼륨 확인 (필요 ≥ 40 GB) |
| preflight `✗ ... ≠ 고정 버전` | 다른 버전 설치됨 | `bin/tc3 install` (고정 버전으로 맞춤) |
| preflight `✗ 포트 8000 사용 중` | 이전 서버/다른 프로세스 | `bin/tc3 stop` → `ss -ltnp 'sport = :8000'` |
| serve 즉시 FAIL "준비 전에 종료됨" | furiosa-llm 기동 오류 | 화면의 server.log 꼬리 (장치 점유·artifact 불일치·인자) |
| serve "준비 시간 초과" | 적재 지연 | `bin/tc3 stop` 후 `TC3_READY_TIMEOUT=1800 bin/tc3 serve` |
| 07 FAIL `id='...'` | served-model-name 미적용 | SDK 버전 확인 (2절) |
| soak 일부 ERR | 타임아웃/서버 이상 | `soak_result.csv` error 열, `TC3_SOAK_TIMEOUT` 상향 후 재실행 |
| stop FAIL "내려가지 않음" | 프로세스 잔존 | `furiosa-smi ps`, `pkill -f 'furiosa-llm serve'` 후 `bin/tc3 stop` |

## 6. 검증 근거

- `tests/run_scenarios.sh`: Ubuntu 22.04 컨테이너에서 48개 시나리오 (정상 흐름, furiosa/vllm 스텁 경로 + 실제 가중치, 서버 즉시 사망·시간 초과·이중 기동·포트 점유·SIGTERM 무시·리더만 사망, 잘못된 모델 id·비JSON·빈 응답·간헐 실패·도중 사망, CRLF/BOM/따옴표 tc3.env, 프록시, 비루트, LANG=C, 심볼릭 링크, 백엔드 전환, 날짜 넘김, 실제 HF 다운로드).
- `tests/vm-sim`: 깨끗한 Ubuntu 22.04(SSH) 에서 clone → install(실제 pkg.dev 저장소 등록, venv + uv) → 전 단계 → 캡처 → `vm-state.sh` 원복 → 재현.
- 실행: `docker compose -f docker/compose.local.yml run --rm --no-deps -T --entrypoint bash tester /kit/tests/run_scenarios.sh`

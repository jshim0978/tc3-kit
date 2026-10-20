# tc3-kit — TC3 「초거대AI 모델 검증 수」 시험 키트

시험용 VM(RNGD NPU)에서 **Llama-3.1-8B-Instruct** 를 추론 서버로 띄우고, 실행·운영 과정을 화면과 증빙 파일로 남깁니다.
아래 명령은 모두 **VM 에서** 실행합니다 (이 PC → `ssh llmvm`).

## 시험 당일 — 3단계

```bash
cd ~/tc3-kit
./start.sh            # 메뉴 1 → 2 → 3 (아래 표의 명령과 같음). 한 번에: ./start.sh all
```

| 단계 | 직접 입력 시 | 하는 일 |
|---|---|---|
| ① 사전준비 확인 | `bin/tc3 preflight` | 설치 버전·모델 파일·포트·디스크·시계 점검 — ✗ 가 없으면 통과 (! 는 주의) |
| ② 시험 스크립트 재생 | `bin/tc3 live` | 절차 4~12 를 한 번에 실행 — 왼쪽은 실시간 출력, 오른쪽은 NPU 상태(1초마다) |
| ③ 결과 저장·확인 | `bin/tc3 result` | `RESULT.md` 를 만들고 출력 (판정 A~D + NPU 점유) |

- 절차 1~3(플랫폼)은 명령이 없습니다 — Horizon 화면 3장: Hypervisors · Flavor 의 `pci_passthrough:alias` · Instance `etri-llm-test` 의 Status·Host·IP.
- 증빙 폴더: `evidence/<날짜-시각>-furiosa/` · 제출용 압축: `bin/tc3 result --zip`
- 실패하면 원인을 고친 뒤 실패한 단계부터: `bin/tc3 live --from <단계>` (단계 이름은 화면의 `━━` 줄에 표시, 예: `serve`)
- 재생 중 SSH 가 끊겨도 재생은 VM 에서 계속됩니다 → 다시 접속해 `bin/tc3 live` (새로 돌리지 않고 화면에 다시 붙음)

## 사전준비 — 시험 전에 한 번

```bash
git clone https://github.com/jshim0978/tc3-kit.git ~/tc3-kit && cd ~/tc3-kit   # 비밀번호 자리에 읽기 전용 토큰
cp tc3.env.example tc3.env
bin/tc3 install       # 드라이버·SDK·tmux (검증한 고정 버전). "재부팅 필요" → sudo reboot 후 다시
bin/tc3 hf-login      # "HF 토큰 입력" 이 뜬 뒤 붙여넣기 (화면에 안 보임)
bin/tc3 fetch-model   # 모델 파일 약 33 GB → /models
bin/tc3 hf-logout     # 받았으면 바로 — 공용 VM 에 토큰을 남기지 않음
bin/tc3 preflight     # ✗ 가 없으면 준비 끝 (! 도 읽어 볼 것)
```

키트가 바뀌면 `git pull` (같은 토큰).

## 판정 기준

| 증빙 | 기준 |
|---|---|
| A 플랫폼 | VM ACTIVE + NPU 인식 |
| B 모델 크기 | 파라미터 수 ≥ 8B (Llama-3.1-8B: 8,030,261,248) |
| C 실행 | 서버가 알려준 모델 이름 일치 + 한국어·영어 응답 |
| D 운영 | 연속 100회 요청 성공률 100% |

E(NPU 점유 그래프·요약)는 참고 자료이며 판정에는 쓰지 않습니다.

## NPU 없이 미리 해보기 (PC·Docker)

```bash
TC3_BACKEND=mock TC3_FIXTURE=1 TC3_SOAK_N=5 bin/tc3 run && TC3_BACKEND=mock bin/tc3 result
```

결과는 `SIMULATED` 로 표시됩니다 (공인시험 증빙 아님).

## 더 보기

| 필요할 때 | 위치 |
|---|---|
| 버전 고정·장애 대응표·리허설 | [docs/VM_RUNBOOK.md](docs/VM_RUNBOOK.md) |
| 절차서에 옮길 본문 | [docs/PROCEDURE_v2.md](docs/PROCEDURE_v2.md) |
| 모든 명령과 옵션 | `bin/tc3 --help` |
| 설정값 (백엔드·포트·연속 요청 횟수) | [tc3.env.example](tc3.env.example) |
| Windows PC 에서 VM 화면 캡처 | `.\tc3-capture-vm.ps1 -Target llmvm -Mode prep,run,result` |
| VM 점검·프록시·Horizon 접속 | `tools/` (런북 3절) |
| 자동 시험 | `tests/run_scenarios.sh` (런북 6절) |

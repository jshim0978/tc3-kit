# TC3 시험 절차 본문 v2 — 3단계 구조 (절차서 6.3 TC3 표 옮김용)

> 2026-10-20 결정: VM 에 OS·드라이버/SDK·모델·키트를 **미리 준비**하고, 시험 당일에는
> ① 사전준비 확인 → ② 시험 스크립트 재생 → ③ 결과 저장·확인 순서로 진행한다.
> `< >` 안은 시험 전에 확정해 채운다 (flavor, 키트 커밋, 결과 수치 등).

## 시험항목

초거대AI 모델 검증 수 — AI반도체 클라우드 플랫폼 시제품(DUT1) 위에서 실행·운영 가능한 오픈소스 초거대 모델 수

## 시험목표

DUT1 의 VM 에서 오픈소스 초거대 모델 1종 이상(Llama-3.1-8B-Instruct, 8.03B)을 NPU(FuriosaAI RNGD) 위의 추론 서비스로 실행하고,
연속 요청까지 운영됨을 확인한다.

## 시험환경

| 항목 | 내용 |
|---|---|
| 플랫폼 | openKcloud DUT1 (OpenStack), 가속기 FuriosaAI RNGD |
| VM | `etri-llm-test` (compute1) · IP `192.168.90.219` · flavor `<확정 flavor — 현재 m1.large.rngd: 4 vCPU / 8 GB / 80 GB, 계획 m1.xlarge.rngd: 16 vCPU / 64 GB / 200 GB>` (RNGD 1장 패스스루) |
| OS | Ubuntu 22.04 LTS, 커널 ≥ 6.3 |
| 모델 | `meta-llama/Llama-3.1-8B-Instruct` (원본 safetensors) + `furiosa-ai/Llama-3.1-8B-Instruct` @ `v2026.3` (RNGD artifact) |
| 시험 키트 | `tc3-kit` 커밋 `<키트 커밋>` |
| 구성도 | [그림 3] |

## 시험절차

### ① 사전준비 — 시험 전 완료, 시험 당일은 확인만

시험 전에 아래 항목을 VM 에 준비해 둔다 (명령: `bin/tc3 install`, `bin/tc3 hf-login`, `bin/tc3 fetch-model`).

| 준비 항목 | 내용 |
|---|---|
| OS·커널 | Ubuntu 22.04 LTS, 커널 6.3 이상 |
| NPU 드라이버·도구 | `furiosa-driver-rngd 2026.3.1`, `furiosa-smi 2026.1.1-3` |
| 추론 SDK | `furiosa-llm 2026.3.0` (Python venv) |
| 원본 가중치 | `meta-llama/Llama-3.1-8B-Instruct` — safetensors 4개, 16.06 GB, `/models/Llama-3.1-8B-Instruct` |
| NPU artifact | `furiosa-ai/Llama-3.1-8B-Instruct` @ `v2026.3` — 16.52 GB, `/models/furiosa-ai/Llama-3.1-8B-Instruct` |
| 시험 키트 | `tc3-kit` (커밋 `<키트 커밋>`), 설정 `tc3.env` (백엔드 furiosa, 포트 8000, 연속 요청 100회) |
| 네트워크 | 시험 단계는 외부 인터넷이 필요 없음 (모든 파일이 VM 에 있음) |

**당일 확인**

| 명령 | 화면 | 기대 결과 | 캡처 |
|---|---|---|---|
| `bin/tc3 preflight` (= `./start.sh 1`) | 위 항목의 기대값과 실제값을 표 한 장으로 표시 | 모든 항목 ✓ (또는 ! 주의), 마지막 줄 `preflight: 문제 없음` | `TC3_prep_preflight.png` |

증빙: `evidence/<run>/prep_check.log`, `prep_check.json`

### ② 시험 스크립트 재생

| 명령 | 화면 |
|---|---|
| `bin/tc3 live` (= `./start.sh 2`) | 왼쪽: 절차 4~12 실시간 진행 (단계 머리줄 `━━ [n/7] 절차 N · 단계 — 시작 시각 ━━`, 끝줄 `→ PASS (소요 s)`) · 오른쪽: NPU 상태 (`furiosa-smi status` / `ps`, 1초마다 갱신) |

| 절차 | 단계 | 수행 내용 | 기대 결과 | 캡처 |
|---|---|---|---|---|
| — | 사전준비 확인 | 재생 시작 전 자동 점검 (실패 시 시험을 시작하지 않음) | `preflight: 문제 없음` | `TC3_run_00_preflight.png` |
| 4 | env | `lspci` 로 RNGD(1ed2) 확인, `furiosa-smi info/status`, SDK·커널 버전 | RNGD 1장 인식, PASS | `TC3_run_04_env.png` |
| 5 | model-size | 원본 safetensors 의 텐서 합산 | `total parameters = 8,030,261,248 (8.03 B)`, PASS | `TC3_run_05_model-size.png` |
| 6 | serve | `furiosa-llm serve` 기동, 준비 대기 | 서버 준비 완료, NPU 메모리 적재, `furiosa-smi ps` 에 furiosa-llm, PASS | `TC3_run_06_serve.png` |
| 7~9 | verify | `/v1/models`, 한국어·영어 고정 프롬프트 추론 | `id=Llama-3.1-8B-Instruct`, 두 응답 `finish_reason=stop`, PASS | `TC3_run_07-09_verify.png` |
| 10 | soak | 연속 100회 요청 | `success : 100/100 (100.0%)`, p50·p95 응답시간, PASS | `TC3_run_10_soak.png` |
| 11 | stop | 서버 정지·원복 | `server stopped`, `furiosa-smi ps` 비어 있음, PASS | `TC3_run_11_stop.png` |
| 12 | report | 판정 보고서 생성 | 종합 PASS (판정 증빙 A~D) | `TC3_run_12_report.png` |
| — | 재생 종료 | NPU 점유 요약·단계별 경과·총 소요 | `재생 완료` | `TC3_run_done.png` |

재생 중 NPU 사용률·메모리를 1초 간격으로 기록해 그래프를 남긴다: `npu_samples.csv`, `npu_summary.txt`, `npu_utilization.png`.

### ③ 결과 저장 및 확인

| 명령 | 화면 | 기대 결과 | 캡처 |
|---|---|---|---|
| `bin/tc3 result` (= `./start.sh 3`) | `RESULT.md` 출력 (시험환경·판정 A~D·NPU 점유·소크 통계·단계별 결과·증빙 파일 목록), 끝에 요약 | `종합 판정: PASS` | `TC3_result.png` |
| `bin/tc3 result --files` | 주요 로그를 정해진 순서로 출력 (사전준비 → 절차 4 → … → 11 → NPU 요약) | 각 로그 확인 | `TC3_result_files.png` |
| `bin/tc3 result --zip` | 제출용 압축 생성 | `evidence/<run>.zip` | `TC3_result_zip.png` |

증빙 파일 무결성: `evidence/<run>/SHA256SUMS` (모든 파일의 sha256).

## 시험결과

| 판정 증빙 | 기준 | 결과 |
|---|---|---|
| A. 플랫폼 | VM ACTIVE + NPU 인식 (절차 1~4, 1~3 은 Horizon 캡처) | `<PASS>` |
| B. 모델 크기 | 파라미터 수 ≥ 8B | `<PASS — 8,030,261,248>` |
| C. 실행 | `/v1/models` 모델 ID 일치 + 한국어·영어 응답 | `<PASS>` |
| D. 운영 | 연속 100회 요청 성공률 100 % | `<PASS — 100/100>` |
| (참고) E. NPU 점유 | 재생 구간별 NPU 평균·최대 사용률, 메모리 최대 | `<npu_summary.txt 수치>` |

결론: AI반도체 클라우드 플랫폼 시제품(DUT1)의 VM 에서 오픈소스 초거대 모델 Llama-3.1-8B-Instruct(8.03B)를 NPU 추론 서비스로 실행하고
연속 요청까지 운영됨을 확인함 — 판정 증빙 A~D 충족, 종합 PASS. (2차년도 목표: 1종 이상)

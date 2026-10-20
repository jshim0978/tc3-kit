<#
.SYNOPSIS
  TC3 — 시험용 VM 에서 키트 절차를 SSH 로 실행하고, 단계마다 이 PC 의 터미널 창을 PNG 로 캡처한다.
  시험 당일과 같은 화면: VM 의 bash 프롬프트(user@host:~/tc3-kit$) + 명령 + 실제 출력(색 포함, ssh pty).

.USAGE  (보이는 새 Windows Terminal 창에서 실행 — 캡처 대상은 이 스크립트를 띄운 터미널 창)
  Start-Process wt.exe -ArgumentList '-w new --size 160,60 -d C:\Users\etri-jws\repos\tc3-kit powershell -NoExit -ExecutionPolicy Bypass -File .\tc3-capture-vm.ps1 -Target llmvm'
  깨끗한 VM 기준 당일 순서: -Clone -RepoUrl <url> -Install -HfLogin -Fetch -AllowReboot
    (clone → install [재부팅 필요 시 sudo reboot → 재접속 → install 재확인] → hf-login → fetch-model → preflight → 절차 4~12)
    -HfLogin: 이 창에 "HF 토큰 입력" 이 뜨면 사람이 직접 토큰을 붙여넣고 Enter (화면에 표시되지 않음, 자동 입력하지 않음)
  옵션: -KitDir ~/tc3-kit  -Steps env,model-size,...  -RepoUrl <url> (-Clone 과 함께: 새로 clone 하는 장면부터 캡처)
        -SshConfig <ssh config 파일> (점프 호스트/포트/키)  -SshArgs '-p','2222'  -NoPreflight  -NoFetch

.OUTPUT
  captures\<YYYYMMDD-HHMMSS>-vm\TC3_stepNN_*.png  + evidence\<run>\ (VM 에서 scp 로 가져온 증빙)
#>
param(
  [Parameter(Mandatory = $true)] [string]$Target,
  [string]$KitDir = "~/tc3-kit",
  [string[]]$Steps = @("env", "model-size", "serve", "verify", "soak", "stop", "report"),
  [string[]]$SshArgs = @(),
  [string]$SshConfig = "",
  [string]$RepoUrl = "",
  [switch]$Clone,
  [switch]$Install,
  [switch]$HfLogin,
  [switch]$Fetch,
  [switch]$AllowReboot,
  [switch]$NoPreflight,
  [switch]$NoFetch,
  # VM 에 인터넷이 없을 때: master3 의 tools/tc3-proxy.py 주소 (예: http://192.168.90.153:3128) — clone 과 tc3.env 의 TC3_PROXY 에 사용
  [string]$Proxy = "",
  # 시험 당일 3단계 캡처: prep (사전준비 확인) · run (시험 스크립트 재생, 단계 경계마다 자동 캡처) · result (결과 저장·확인)
  #   예: -Mode prep,run,result   (지정하면 절차 4~12 개별 단계 캡처 대신 이 흐름을 캡처)
  [string[]]$Mode = @(),
  # -Mode run: 단계가 끝난 화면을 유지할 시간(초) — 그 사이에 단계별 캡처 (화면에는 표시되지 않음)
  [double]$PhaseHold = 2.5,
  # -Mode run: soak 진행 중 캡처 간격(초)
  [int]$SoakEvery = 15
)
$ErrorActionPreference = "Continue"
# powershell -File 로 실행하면 배열 인자가 "a,b" 한 문자열로 들어오므로 쉼표로 나눈다
$Steps   = @($Steps   | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$SshArgs = @($SshArgs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Mode    = @($Mode    | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($m in $Mode) { if ($m -notin @("prep", "run", "result")) { Write-Error "-Mode 값은 prep, run, result (받은 값: $m)"; exit 1 } }
# 별도 ssh 설정 파일 (점프 호스트·포트·키를 담은 config) — powershell -File 로도 넘길 수 있는 단일 문자열 인자
if ($SshConfig) { $SshArgs = @("-F", $SshConfig) + $SshArgs }
if ($Proxy -and $Proxy -notmatch '^http://[A-Za-z0-9.-]+:[0-9]+$') { Write-Error "-Proxy 형식: http://<주소>:<포트> (예: http://192.168.90.153:3128) — 받은 값: $Proxy"; exit 1 }
if ($Proxy -and $Clone -and $RepoUrl -notmatch '^https://') { Write-Error "-Proxy 와 함께 쓰는 -RepoUrl 은 https:// 이어야 함 (프록시는 SSH clone 을 중계하지 않음)"; exit 1 }
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$CapDir = Join-Path $Here "captures\$Stamp-vm"
New-Item -ItemType Directory -Force -Path $CapDir | Out-Null

# ---------- 창 캡처 (tc3-capture.ps1 과 동일: 시작 시점 터미널 창 핸들 고정 + PrintWindow) ----------
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class TC3VmWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[TC3VmWin]::SetProcessDPIAware() | Out-Null
# 캡처할 창 = 이 스크립트가 도는 터미널 창. 전면 창으로 고르면 사용자가 그 순간 다른 창(브라우저 등)을 쓰고 있을 때
# 그 창이 찍힌다 (10/16 PowerPoint, 10/20 Chrome 오캡처). → 고유한 제목을 붙이고 그 제목의 창을 찾는다.
function Get-WinClass([IntPtr]$h) { $sb = New-Object System.Text.StringBuilder 256; [TC3VmWin]::GetClassName($h, $sb, 256) | Out-Null; $sb.ToString() }
$TermClasses = @("CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass")
$WinTitle = "TC3 capture $Stamp"
try { $Host.UI.RawUI.WindowTitle = $WinTitle } catch { }
$script:TermHwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 40 -and $script:TermHwnd -eq [IntPtr]::Zero; $i++) {
  $h = [TC3VmWin]::FindWindow($null, $WinTitle)
  if ($h -ne [IntPtr]::Zero -and (Get-WinClass $h) -in $TermClasses) { $script:TermHwnd = $h } else { Start-Sleep -Milliseconds 250 }
}
if ($script:TermHwnd -eq [IntPtr]::Zero) {
  $h = [TC3VmWin]::GetForegroundWindow()
  if ((Get-WinClass $h) -in $TermClasses) { $script:TermHwnd = $h; Write-Warning "제목으로 창을 찾지 못해 전면 터미널 창을 캡처 대상으로 씁니다" }
  else { Write-Error "캡처할 터미널 창을 찾지 못함 (제목 '$WinTitle') — Windows Terminal 의 '제목 표시줄에 터미널 제목 표시' 설정 확인"; exit 1 }
}
Write-Host ("캡처 대상 창: 0x{0:X} ({1})" -f $script:TermHwnd.ToInt64(), (Get-WinClass $script:TermHwnd)) -ForegroundColor DarkGray

# 캡처 검사: 크기가 너무 작거나 화면이 밝으면(터미널이 아닌 창이 찍힌 경우 — 10/16 PowerPoint 오캡처) 경고 후 1회 다시 찍는다
function Test-Snap([string]$path) {
  $b = New-Object System.Drawing.Bitmap $path
  try {
    if ($b.Width -lt 300 -or $b.Height -lt 200) { return "크기 $($b.Width)x$($b.Height) 가 너무 작음" }
    $sum = 0.0; $n = 0
    for ($x = 5; $x -lt $b.Width; $x += [Math]::Max(1, [int]($b.Width / 40))) {
      for ($y = 5; $y -lt $b.Height; $y += [Math]::Max(1, [int]($b.Height / 40))) { $c = $b.GetPixel($x, $y); $sum += (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) / 255; $n++ }
    }
    if ($n -gt 0 -and ($sum / $n) -gt 0.55) { return ("밝기 {0:N2} — 어두운 터미널 화면이 아님" -f ($sum / $n)) }
    return ""
  } finally { $b.Dispose() }
}
function Snap([string]$name) {
  Save-Snap $name
  $p = Join-Path $CapDir "$name.png"
  $why = Test-Snap $p
  if ($why) {
    if (-not $script:SnapQuiet) { Write-Warning "캡처 확인 필요 ($name): $why → 1초 후 다시 캡처" }
    Start-Sleep -Seconds 1; Save-Snap $name; $why = Test-Snap $p
    if ($why) {
      if (-not $script:SnapQuiet) { Write-Warning "다시 찍어도 확인 필요 ($name): $why" }
      "{0}`tCHECK`t{1}" -f $name, $why | Out-File -Append -Encoding utf8 (Join-Path $CapDir "steps.tsv")
    }
  }
}
function Save-Snap([string]$name) {
  Start-Sleep -Milliseconds $(if ($script:SnapQuiet) { 200 } else { 700 })
  $h = $(if ($script:TermHwnd -ne [IntPtr]::Zero) { $script:TermHwnd } else { [TC3VmWin]::GetForegroundWindow() })
  if ([TC3VmWin]::IsIconic($h)) { Write-Warning "터미널 창이 최소화되어 있어 캡처가 비어 보일 수 있습니다" }
  $wr = New-Object TC3VmWin+RECT; [TC3VmWin]::GetWindowRect($h, [ref]$wr) | Out-Null
  $r = New-Object TC3VmWin+RECT
  if ([TC3VmWin]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { $r = $wr }
  $w = $r.R - $r.L; $hh = $r.B - $r.T
  $p = Join-Path $CapDir "$name.png"
  $full = New-Object System.Drawing.Bitmap ($wr.R - $wr.L), ($wr.B - $wr.T)
  $g = [System.Drawing.Graphics]::FromImage($full); $hdc = $g.GetHdc()
  $ok = [TC3VmWin]::PrintWindow($h, $hdc, 2)
  $g.ReleaseHdc($hdc); $g.Dispose()
  if ($ok) { $bmp = $full.Clone((New-Object System.Drawing.Rectangle ($r.L - $wr.L), ($r.T - $wr.T), $w, $hh), $full.PixelFormat) }
  else { $bmp = New-Object System.Drawing.Bitmap $w, $hh; $g2 = [System.Drawing.Graphics]::FromImage($bmp); $g2.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size); $g2.Dispose() }
  $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $full.Dispose()
  # 재생(tmux) 화면 위에 글자를 찍으면 다음 캡처에 섞이므로, 재생 중에는 화면에 쓰지 않는다
  if (-not $script:SnapQuiet) { Write-Host "  [capture] $p" -ForegroundColor DarkGray }
}

# ---------- VM 실행 ----------
# 명령을 VM 의 bash 스크립트로 만들어 base64 로 보낸다 (PowerShell 5.1 의 인자 따옴표 문제 회피).
# 스크립트는 VM 의 실제 프롬프트 형식(Ubuntu 기본 PS1 색)으로 "user@host:~/dir$ 명령" 을 찍고 명령을 실행한다.
function Invoke-Vm([string[]]$commands, [string]$cwd = $KitDir, [switch]$Quiet, [switch]$NoWait, [string[]]$Exports = @()) {
  # 주의: PowerShell 에서 , 가 + 보다 먼저 결합 → 첫 원소는 괄호로 감싸야 함
  $lines = @(('cd ' + $cwd + ' 2>/dev/null || cd ~'),
             'P="$(printf ''\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m$ '' "$(id -un)" "$(hostname -s)" "$(dirs +0)")"',
             'rc=0')
  # 화면에 찍지 않는 환경변수 (예: 캡처용 TC3_PHASE_HOLD) — 화면의 명령은 당일과 같게 둔다
  foreach ($e in $Exports) { $lines += "export $e" }
  foreach ($c in $commands) {
    $q = $c.Replace("'", "'\''")
    if (-not $Quiet) { $lines += "printf '%s%s\n' `"`$P`" '$q'" }
    # 한 단계 안에서 앞 명령이 실패하면 거기서 멈춘다 (실패를 뒤 명령의 성공이 덮지 않도록)
    $lines += "$c; rc=`$?; if [ `$rc -ne 0 ]; then printf '%s\n' `"`$P`"; exit `$rc; fi"
  }
  if (-not $Quiet) { $lines += 'printf ''%s\n'' "$P"' }
  $lines += 'exit $rc'
  $script = ($lines -join "`n") + "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
  $remote = "f=`$(mktemp /tmp/tc3_capture.XXXXXX) && echo $b64 | base64 -d > `$f && bash `$f; r=`$?; rm -f `$f; exit `$r"
  # ssh 를 콘솔에 직접 연결해 실행 (출력을 변수로 받으면 화면에 아무것도 안 남음 → 캡처가 빈 창이 됨)
  # -q: 끝날 때 "Connection to ... closed." 같은 ssh 자체 메시지가 캡처에 찍히지 않게 (원격 명령의 출력·종료코드는 그대로)
  $argv = @("-t", "-q") + $SshArgs + @($Target, $remote) | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
  $p = Start-Process -FilePath "ssh" -ArgumentList ($argv -join ' ') -NoNewWindow -PassThru
  $null = $p.Handle   # PS 5.1: 핸들을 잡아 두지 않으면 ExitCode 가 비는 문제
  if ($NoWait) { return $p }
  $p.WaitForExit()
  return $p.ExitCode
}
# 비대화형 조회: -n (stdin 을 읽지 않음 — Windows ssh 가 콘솔 stdin 을 붙잡고 끝나지 않는 문제 방지), BatchMode (암호·확인 프롬프트로 멈추지 않음)
$NonInteractive = @("-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15")
function Get-Vm([string]$cmd) { (& ssh @NonInteractive @SshArgs $Target $cmd 2>$null | Out-String).Trim() }

function Step([string]$name, [string[]]$commands, [string]$cwd = $KitDir) {
  Clear-Host
  $rc = Invoke-Vm $commands $cwd
  Snap $name
  "{0}`t{1}`t{2}" -f $name, $rc, ($commands -join " ; ") | Out-File -Append -Encoding utf8 (Join-Path $CapDir "steps.tsv")
  return $rc
}

# 시험 스크립트 재생 캡처: 재생을 띄워 둔 채, VM 의 <현재 run>/phase 변화를 SSH 한 연결로 지켜보다가
# 단계가 바뀔 때마다(=앞 단계 출력이 끝난 화면) TC3_run_NN_<단계>.png, 끝나면 TC3_run_done.png 를 찍는다.
# ---------- 캡처 목록 (INDEX.md): 순번 · 파일 · 단계 · 화면의 명령 · 설명 — 시험절차서 작성용 ----------
$script:Seq = 0
$script:Index = New-Object System.Collections.Generic.List[object]
$D = @{
  "env_vm"            = "시험 환경 — 호스트 이름, OS(Ubuntu 22.04), 커널, CPU 수, 메모리, 디스크 여유";
  "env_npu"           = "NPU 인식 — lspci 의 FuriosaAI RNGD(PCI 벤더 1ed2), furiosa-smi info(펌웨어·온도·전력·PCI 주소), furiosa-smi status(유휴: 메모리 0, 코어 '-')";
  "env_sdk"           = "드라이버·SDK 버전 — furiosa-driver-rngd·furiosa-smi(apt 패키지), furiosa-llm(venv) — 검증한 고정 조합, python 버전";
  "env_models"        = "모델 파일 — 원본 가중치 safetensors 4개(16.06 GB, 파라미터 수 산출용)와 RNGD 컴파일 artifact(16.52 GB, v2026.3, 서빙용)";
  "env_kit"           = "시험 키트 커밋과 설정 파일(tc3.env)의 값 — 백엔드·모델 이름·포트·연속 요청 횟수·경로";
  "start_menu"        = "시험 실행기 ./start.sh 메뉴 — 1 사전준비 확인 / 2 시험 스크립트 재생 / 3 결과 보기 / a 전부, 각 항목이 실행하는 bin/tc3 명령";
  "start1_preflight"  = "./start.sh 1 = bin/tc3 preflight — 사전준비 항목(버전·모델 파일·포트·디스크·시계·NPU 점유)을 기대값/실제값 표로 확인 → PASS, 다음 단계 안내";
  "run_preflight"     = "./start.sh 2 = bin/tc3 live 시작 — 왼쪽: 재생 전 자동 사전준비 확인(실패하면 시험을 시작하지 않음), 오른쪽: NPU 상태 패널(1초 갱신)";
  "step04_env"        = "절차 4 env — lspci 로 RNGD 확인, furiosa-smi info/status, furiosa-llm·python·커널 버전 → PASS";
  "step05_model_size" = "절차 5 model-size — 원본 safetensors 의 텐서 합산: total parameters = 8,030,261,248 (8.03 B) → PASS";
  "serve_loading"     = "절차 6 serve 진행 중 — furiosa-llm serve 기동·준비 대기. NPU 를 여는 동안 오른쪽 패널은 조회를 잠시 멈춤(장치 충돌 방지)";
  "step06_serve"      = "절차 6 serve 완료 — 서버 준비, 기동 로그, NPU 메모리 적재(약 42.5/47.5 GiB), furiosa-smi ps 에 furiosa-llm 프로세스 → PASS";
  "step07_models"     = "절차 7 — /v1/models 응답: id = Llama-3.1-8B-Instruct (요청에 쓰는 모델 이름과 일치) → PASS";
  "step08_chat_ko"    = "절차 8 — 한국어 고정 프롬프트 추론: 요청 JSON 과 한국어 응답, finish_reason=stop → PASS";
  "step09_chat_en"    = "절차 9 — 영어 고정 프롬프트 추론: 요청 JSON 과 영어 응답, finish_reason=stop → PASS";
  "soak_progress"     = "절차 10 soak 진행 — 서로 다른 100문항(한국어 50·영어 50, 10개 유형)을 연속 요청: 줄마다 순번·소요·토큰·언어·유형·응답 앞부분, 오른쪽은 NPU 코어 사용률";
  "step10_soak"       = "절차 10 soak 완료 — 성공 100/100(100%), 언어별 성공 수, 응답시간 p50/p95/최대 → PASS";
  "step11_stop"       = "절차 11 stop — 서버 정지(connection refused), NPU 메모리 해제·점유 프로세스 없음 → PASS";
  "step12_report"     = "절차 12 report — NPU 점유 요약(구간별 평균·최대 사용률, 메모리, 전력, 온도)과 판정 보고서(A~D) → 종합 PASS";
  "done"              = "재생 종료 — 단계별 결과·소요 시간 표와 총 소요, '재생 완료'";
  "start2_summary"    = "./start.sh 2 종료 — 실행기의 한 줄 요약(완료·소요·결과 경로)과 다음 단계(3) 안내";
  "start3_result"     = "./start.sh 3 = bin/tc3 result && bin/tc3 result --files — RESULT.md 생성·출력 후 주요 로그 출력 (화면은 끝부분, 실행기 요약)";
  "result_md_1"       = "RESULT.md (1) — 시험항목·VM/OS·가속기·모델·키트·재생 시각·사전준비 결과, 종합 판정과 판정 증빙 A~D";
  "result_md_2"       = "RESULT.md (2) — E. NPU 점유 요약표, 연속 요청(D) 통계";
  "result_md_3"       = "RESULT.md (3) — 단계별 결과(절차 04~11)와 단계별 소요 시간";
  "result_md_4"       = "RESULT.md (4) — 증빙 파일 목록(크기·sha256 앞 16자)과 결론";
  "files_prep_check"  = "result --files: 사전준비 확인 표 원본 (prep_check.log)";
  "files_env"         = "result --files: 절차 4 로그 — lspci·furiosa-smi info/status·버전";
  "files_params"      = "result --files: 절차 5 로그 — 파라미터 수 산출 상세(파일별 크기, 텐서 수, config, index 교차확인)";
  "files_serve_log"   = "result --files: 절차 6 서버 기동 로그(furiosa-llm: artifact 적재, 병렬 구성, KV 캐시, Uvicorn 시작)";
  "files_npu_status"  = "result --files: 절차 6 NPU 상태 로그 — 적재 후 메모리·코어, 점유 프로세스";
  "files_models"      = "result --files: 절차 7 로그 — /v1/models 응답";
  "files_chat_ko"     = "result --files: 절차 8 로그 — 한국어 요청·응답 전문";
  "files_chat_en"     = "result --files: 절차 9 로그 — 영어 요청·응답 전문";
  "files_soak"        = "result --files: 절차 10 로그 요약(성공률·언어별·응답시간) + 한국어/영어 질의응답 표본 12건";
  "files_stop"        = "result --files: 절차 11 로그 — 서버 정지 확인, NPU 해제";
  "files_npu_summary" = "result --files: NPU 점유 요약(npu_summary.txt)";
  "evidence_ls"       = "증빙 디렉터리 전체 파일 목록";
  "evidence_sha"      = "증빙 무결성 — SHA256SUMS 로 모든 파일 해시 확인";
  "result_zip"        = "제출용 압축 생성 — bin/tc3 result --zip";
}
function Next-Name([string]$label) { $script:Seq++; return ("TC3_{0:D2}_{1}" -f $script:Seq, $label) }
function Add-Index([string]$file, [string]$stage, [string]$cmd, [string]$desc) {
  $script:Index.Add([pscustomobject]@{ Seq = $script:Seq; File = "$file.png"; Stage = $stage; Cmd = $cmd; Desc = $desc })
}
# Cap <라벨> <단계> <명령들> — 한 장 캡처 + 목록 기록
function Cap([string]$label, [string]$stage, [string[]]$commands) {
  $n = Next-Name $label
  $rc = Step $n $commands
  Add-Index $n $stage ($commands -join " ; ") $D[$label]
  $Results[$n] = $rc
  return $rc
}

# 시험 스크립트 재생 캡처: 재생을 띄워 둔 채, VM 의 <현재 run> 을 SSH 한 연결로 지켜보며
#   절차 단계 기록(status.tsv) 마다 · serve 기동 중 · soak 진행 중(일정 간격) · report · 재생 종료 · 실행기 요약을 찍는다.
function Run-Phases([string]$cmd) {
  $stepLabel = @{ "04" = "step04_env"; "05" = "step05_model_size"; "06" = "step06_serve"; "07" = "step07_models";
                  "08" = "step08_chat_ko"; "09" = "step09_chat_en"; "10" = "step10_soak"; "11" = "step11_stop" }
  $watch = @(('cd ' + $KitDir + ' 2>/dev/null || exit 1'), 'run=""; rows=0; srows=0; last=""; first=1',
             'while :; do',
             '  r="$(cat evidence/.current_run 2>/dev/null)"; f="$r/run_timing.tsv"; s="$r/status.tsv"',
             '  if [ "$r" != "$run" ]; then',
             '    if [ $first = 1 ]; then rows=$(cat "$f" 2>/dev/null | wc -l); srows=$(cat "$s" 2>/dev/null | wc -l); first=0; else rows=0; srows=0; fi',
             '    run="$r"; echo "BASE|$r|$rows|$srows"',
             '  fi',
             '  new="$(tail -n +$((rows + 1)) "$f" 2>/dev/null)"',
             '  if [ -n "$new" ]; then printf "%s\n" "$new" | awk -F "\t" ''NF >= 6 && $1 != "phase" { print "ROW|" $1 "|" $6 }''; rows=$((rows + $(printf "%s\n" "$new" | wc -l))); fi',
             '  n=$(cat "$s" 2>/dev/null | wc -l); [ "$n" -lt "$srows" ] && srows=$n',
             '  if [ "$n" -gt "$srows" ]; then tail -n +$((srows + 1)) "$s" | awk -F "\t" ''NF >= 3 && $1 != "step" { print "STEP|" $1 "|" $2 "|" $3 }''; srows=$n; fi',
             '  p="$(cat "$r/phase" 2>/dev/null)"; if [ "$p" != "$last" ]; then echo "PHASE|$p"; last="$p"; fi',
             '  sleep 0.3',
             'done') -join "`n"
  $wb64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($watch + "`n"))
  $wout = Join-Path $CapDir ".phase_watch.txt"; $werr = Join-Path $CapDir ".phase_watch.err"
  $wargs = ($NonInteractive + $SshArgs + @($Target, "echo $wb64 | base64 -d | bash")) | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
  $wp = Start-Process -FilePath "ssh" -ArgumentList ($wargs -join ' ') -NoNewWindow -PassThru -RedirectStandardOutput $wout -RedirectStandardError $werr
  $t0 = Get-Date; while (-not ((Test-Path $wout) -and (Get-Item $wout).Length -gt 0) -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
  Clear-Host
  $script:SnapQuiet = $true
  $stage = "② $cmd"
  $p = Invoke-Vm @($cmd) -NoWait -Exports @("TC3_PHASE_HOLD=$PhaseHold")
  $seen = 0; $phase = ""; $done = $false; $shot = @{}; $serveAt = $null; $soakAt = $null; $prog = 0
  $log = Join-Path $CapDir "steps.tsv"
  function Shot([string]$label, [string]$descKey, [int]$delayMs = 300) {
    if ($shot.ContainsKey($label)) { return }
    Start-Sleep -Milliseconds $delayMs
    $n = Next-Name $label
    Snap $n; $shot[$label] = 1
    Add-Index $n $stage $cmd $D[$descKey]
    "{0}`t-`t{1} ({2})" -f $n, $cmd, $label | Out-File -Append -Encoding utf8 $log
  }
  while (-not $p.HasExited) {
    Start-Sleep -Milliseconds 300
    $lines = @(Get-Content $wout -Encoding UTF8 -ErrorAction SilentlyContinue)
    while ($seen -lt $lines.Count) {
      $f = $lines[$seen] -split '\|'; $seen++
      switch ($f[0]) {
        "STEP" { if ($f.Count -ge 4 -and $stepLabel.ContainsKey($f[1])) { Shot $stepLabel[$f[1]] $stepLabel[$f[1]] } }
        "ROW"  { if ($f.Count -ge 3 -and $f[1] -eq "report") { Shot "step12_report" "step12_report" } }
        "PHASE" {
          $phase = $(if ($f.Count -ge 2) { $f[1] } else { "" })
          if ($phase -eq "preflight-done") { Shot "run_preflight" "run_preflight" }
          if ($phase -eq "serve") { $serveAt = Get-Date }
          if ($phase -eq "soak") { $soakAt = Get-Date }
          if ($phase -in @("done", "aborted") -and -not $done) {
            $done = $true
            Shot "done" "done" 4000   # NPU 요약·단계별 경과·총 소요가 출력될 시간
            # live(tmux)는 Enter 를 기다린다 → 마지막 화면을 찍었으니 닫기 신호
            $null = Get-Vm "cd $KitDir && touch `"`$(cat evidence/.current_run)/.live_close`""
          }
        }
      }
    }
    if ($phase -eq "serve" -and $serveAt -and ((Get-Date) - $serveAt).TotalSeconds -ge 5) { Shot "serve_loading" "serve_loading" 0 }
    if ($phase -eq "soak" -and $soakAt -and ((Get-Date) - $soakAt).TotalSeconds -ge $SoakEvery) {
      $prog++; Shot ("soak_progress_{0}" -f $prog) "soak_progress" 0; $soakAt = Get-Date
    }
  }
  $p.WaitForExit()
  Start-Sleep -Milliseconds 800
  Shot "start2_summary" "start2_summary" 0
  $script:SnapQuiet = $false
  try { if (-not $wp.HasExited) { $wp.Kill() } } catch { }
  $miss = @((@($stepLabel.Values) + @("step12_report", "done")) | Where-Object { -not $shot.ContainsKey($_) })
  if ($miss.Count) { Write-Warning ("캡처 안 된 단계: {0} (실패로 건너뛴 단계이거나 재생이 중단됨)" -f ($miss -join ', ')) }
  "{0}`t{1}`t{2}" -f "TC3_run", $p.ExitCode, $cmd | Out-File -Append -Encoding utf8 $log
  return $p.ExitCode
}

# ---------- 0) 접속·키트 ----------
Write-Host "VM 접속 확인: ssh $Target" -ForegroundColor Cyan
$hn = Get-Vm "hostname"
if (-not $hn) { Write-Error "ssh $Target 접속 실패 — ~/.ssh/config, 키, 점프 호스트 확인"; exit 1 }

$Results = [ordered]@{}
if ($Clone) {
  if (-not $RepoUrl) { Write-Error "-Clone 에는 -RepoUrl 이 필요합니다"; exit 1 }
  # 비공개 저장소면 git 이 Username/Password(토큰)를 묻는다 — 사람이 이 창에 입력 (스크립트는 입력하지 않음)
  if ($RepoUrl -match '^https://') { try { [console]::Beep(880, 250); [console]::Beep(1175, 250) } catch { } }
  if ($Proxy) {
    $cloneCmds = @("git -c http.proxy=$Proxy clone $RepoUrl $KitDir",
                   "cd $KitDir && cp tc3.env.example tc3.env && sed -i 's|^TC3_PROXY=.*|TC3_PROXY=$Proxy|' tc3.env && grep '^TC3_PROXY=' tc3.env && git log -1 --oneline")
  } else {
    $cloneCmds = @("git clone $RepoUrl $KitDir", "cd $KitDir && cp tc3.env.example tc3.env && git log -1 --oneline")
  }
  $Results["TC3_step00a_clone"] = Step "TC3_step00a_clone" $cloneCmds "~"
  if ($Results["TC3_step00a_clone"] -ne 0) {
    Write-Error "git clone 실패 (이미 $KitDir 가 있거나 저장소 접근 불가) — 이전 키트로 진행하지 않도록 중단합니다"; exit 1
  }
} elseif ($Proxy) {
  # 이미 있는 키트: tc3.env 의 TC3_PROXY 를 맞춰 둔다 (캡처 없이)
  $px = Get-Vm "cd $KitDir && { [ -f tc3.env ] || cp tc3.env.example tc3.env; } && { grep -q '^TC3_PROXY=' tc3.env || echo 'TC3_PROXY=' >> tc3.env; } && sed -i 's|^TC3_PROXY=.*|TC3_PROXY=$Proxy|' tc3.env && grep '^TC3_PROXY=' tc3.env"
  if ("$px" -ne "TC3_PROXY=$Proxy") { Write-Error "tc3.env 에 TC3_PROXY 를 설정하지 못함 ($KitDir/tc3.env 확인): $px"; exit 1 }
  Write-Host "tc3.env: $px" -ForegroundColor Cyan
}
if ($Mode.Count -eq 0) { $Results["TC3_step00_vm_and_kit"] = Step "TC3_step00_vm_and_kit" @("hostname; grep PRETTY_NAME /etc/os-release; uname -r", "git log -1 --oneline", "grep -E '^TC3_(BACKEND|MODEL_NAME|MODEL_DIR|ARTIFACT_DIR|DEVICES|SOAK_N|PORT)=' tc3.env") }

function Show-Summary([int]$code) {
  Write-Host ""
  $Results.GetEnumerator() | ForEach-Object { "{0,-26} {1}" -f $_.Key, $(if ("$($_.Value)" -eq "0") { "ok" } elseif ($_.Value -eq "skip") { "SKIP" } else { "rc=$($_.Value)" }) } | Out-Host
  Write-Host "캡처: $CapDir" -ForegroundColor $(if ($code -eq 0) { "Green" } else { "Red" })
  exit $code
}
# 재부팅 후 SSH 가 다시 될 때까지 대기 (최대 15분)
function Wait-VmBack {
  Write-Host "VM 재부팅 대기..." -ForegroundColor Cyan
  Start-Sleep -Seconds 20
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalMinutes -lt 15) {
    if (Get-Vm "hostname") { Write-Host "VM 재접속 OK ($([int]((Get-Date) - $t0).TotalSeconds + 20)s)" -ForegroundColor Cyan; return $true }
    Start-Sleep -Seconds 10
  }
  return $false
}

# ---------- 사전 준비: install (재부팅 포함) · fetch-model — 깨끗한 VM 에서 시작하는 당일 순서 ----------
if ($Install) {
  $Results["TC3_step00c_install"] = Step "TC3_step00c_install" @("bin/tc3 install")
  if ($Results["TC3_step00c_install"] -eq 3) {
    if (-not $AllowReboot) { Write-Warning "install: 재부팅 필요 — -AllowReboot 가 없어 여기서 멈춥니다"; Show-Summary 1 }
    $r = Step "TC3_step00c_reboot" @("sudo reboot")
    $Results["TC3_step00c_reboot"] = $(if ($r -in 0, 255, -1) { 0 } else { $r })   # 접속이 끊기는 것이 정상
    if (-not (Wait-VmBack)) { Write-Error "재부팅 후 15분 안에 VM 에 다시 접속하지 못함"; Show-Summary 1 }
    $Results["TC3_step00c_install2"] = Step "TC3_step00c_install2" @("bin/tc3 install")
  }
  if ("$($Results[@($Results.Keys)[-1]])" -ne "0") { Write-Error "install 실패 — 이후 단계 중단"; Show-Summary 1 }
}
if ($HfLogin) {
  # 사람이 이 창에 토큰을 입력해야 하는 단계 — 알림음으로 알린다 (스크립트는 토큰을 입력하지 않음)
  try { [console]::Beep(880, 250); [console]::Beep(1175, 250) } catch { }
  $Results["TC3_step00e_hf_login"] = Step "TC3_step00e_hf_login" @("bin/tc3 hf-login")
  if ($Results["TC3_step00e_hf_login"] -ne 0) { Write-Error "hf-login 실패 — 이후 단계 중단"; Show-Summary 1 }
}
if ($Fetch) {
  $Results["TC3_step00d_fetch_model"] = Step "TC3_step00d_fetch_model" @("bin/tc3 fetch-model")
  if ($Results["TC3_step00d_fetch_model"] -ne 0) { Write-Error "fetch-model 실패 — 이후 단계 중단"; Show-Summary 1 }
}
if ($Mode.Count -gt 0) {
  # ---------- 시험 당일 흐름을 시험 실행기(start.sh) 항목별로: 0 시험 환경 → ① ./start.sh 1 → ② ./start.sh 2 → ③ ./start.sh 3 + 결과 상세 ----------
  if ("prep" -in $Mode) {
    $null = Cap "env_vm" "0 시험 환경" @("hostname; grep PRETTY_NAME /etc/os-release; uname -r", "nproc; free -h | head -2; df -h ~ | tail -1")
    $null = Cap "env_npu" "0 시험 환경" @("lspci -nn | grep -iE 'furiosa|1ed2'", "furiosa-smi info", "furiosa-smi status")
    $null = Cap "env_sdk" "0 시험 환경" @("dpkg -l | grep -E '^ii +furiosa-(driver-rngd|smi) '",
                                          '~/furiosa-venv/bin/python -c "from importlib.metadata import version as v; print(''furiosa-llm'', v(''furiosa-llm''))"',
                                          "python3 --version")
    $null = Cap "env_models" "0 시험 환경" @("grep -E '^TC3_(MODEL_DIR|ARTIFACT_DIR|HF_ARTIFACT_REVISION)=' tc3.env",
                                             'ls -lh "$(grep ^TC3_MODEL_DIR= tc3.env | cut -d= -f2)"',
                                             'ls -lh "$(grep ^TC3_ARTIFACT_DIR= tc3.env | cut -d= -f2)" | cut -c1-120',
                                             'du -sh "$(grep ^TC3_MODEL_DIR= tc3.env | cut -d= -f2)" "$(grep ^TC3_ARTIFACT_DIR= tc3.env | cut -d= -f2)"')
    $null = Cap "env_kit" "0 시험 환경" @("git log -1 --oneline", "grep -vE '^[[:space:]]*(#|$)' tc3.env | grep -v TOKEN")
    $null = Cap "start_menu" "① 시험 실행기" @("printf 'q\n' | ./start.sh")
    $rc = Cap "start1_preflight" "① ./start.sh 1" @("./start.sh 1")
    if ($rc -ne 0) { Write-Error "사전준비 확인 실패 — 재생하지 않음 (prep_check.log 확인)"; Show-Summary 1 }
  }
  if ("run" -in $Mode) {
    $Results["TC3_run"] = Run-Phases "./start.sh 2"
  }
  if ("result" -in $Mode) {
    $null = Cap "start3_result" "③ ./start.sh 3" @("./start.sh 3")
    $run = Get-Vm "cat $KitDir/evidence/.current_run 2>/dev/null"
    $rel = "evidence/" + ($run -split '/')[-1]
    $null = Cap "result_md_1" "③ 결과 상세" @("sed -n '1,/^## E\./p' $rel/RESULT.md")
    $null = Cap "result_md_2" "③ 결과 상세" @("sed -n '/^## E\./,/^## 단계별 결과/p' $rel/RESULT.md")
    $null = Cap "result_md_3" "③ 결과 상세" @("sed -n '/^## 단계별 결과/,/^## 증빙 파일/p' $rel/RESULT.md")
    $null = Cap "result_md_4" "③ 결과 상세" @("sed -n '/^## 증빙 파일/,`$p' $rel/RESULT.md")
    $files = @(
      [pscustomobject]@{ L = "files_prep_check";  F = "prep_check.log" },
      [pscustomobject]@{ L = "files_env";         F = "step04_*" },
      [pscustomobject]@{ L = "files_params";      F = "step05_model_params.log" },
      [pscustomobject]@{ L = "files_serve_log";   F = "step06_serve_log.log" },
      [pscustomobject]@{ L = "files_npu_status";  F = "step06_*status.log" },
      [pscustomobject]@{ L = "files_models";      F = "step07_models.log" },
      [pscustomobject]@{ L = "files_chat_ko";     F = "step08_chat_ko.log" },
      [pscustomobject]@{ L = "files_chat_en";     F = "step09_chat_en.log" },
      [pscustomobject]@{ L = "files_soak";        F = "step10_soak.log" },
      [pscustomobject]@{ L = "files_stop";        F = "step11_*" },
      [pscustomobject]@{ L = "files_npu_summary"; F = "npu_summary.txt" }
    )
    foreach ($it in $files) { $null = Cap $it.L "③ 결과 상세 (result --files)" @("bin/tc3 result --files --only '$($it.F)'") }
    $null = Cap "evidence_ls" "③ 결과 상세" @("ls -l $rel")
    $null = Cap "evidence_sha" "③ 결과 상세" @("(cd $rel && sha256sum -c SHA256SUMS | tail -n 12)", "(cd $rel && sha256sum -c --quiet SHA256SUMS) && echo 'SHA256SUMS: 모든 파일 해시 일치'")
    $null = Cap "result_zip" "③ 결과 상세" @("bin/tc3 result --zip", "ls -lh $rel.zip")
  }
} else {
  if (-not $NoPreflight) { $Results["TC3_step00b_preflight"] = Step "TC3_step00b_preflight" @("bin/tc3 preflight") }
  # ---------- 1) 절차 4~12 (개별 단계) ----------
  $names = @{ "env" = "TC3_step04_env"; "model-size" = "TC3_step05_model_size"; "serve" = "TC3_step06_serve"; "verify" = "TC3_step07-09_verify";
              "soak" = "TC3_step10_soak"; "stop" = "TC3_step11_stop"; "report" = "TC3_step12_report" }
  $serveFailed = $false
  foreach ($s in $Steps) {
    $n = $(if ($names.ContainsKey($s)) { $names[$s] } else { "TC3_step_" + $s })
    if ($serveFailed -and $s -in @("verify", "soak")) { Write-Warning "serve 실패 → $s 생략"; $Results[$n] = "skip"; continue }
    $Results[$n] = Step $n @("bin/tc3 $s")
    if ($s -eq "serve" -and $Results[$n] -ne 0) { $serveFailed = $true }
  }
}

# report.md 전체 + 증빙 목록 + status (개별 단계 모드) · 증빙 가져오기 (공통)
$run = Get-Vm "cat $KitDir/evidence/.current_run 2>/dev/null"
if ($run) {
  $rel = "evidence/" + ($run -split '/')[-1]
  if ($Mode.Count -eq 0) {
    $Results["TC3_step12_report_md"] = Step "TC3_step12_report_md" @("cat $rel/report.md")
    $Results["TC3_step12b_evidence"] = Step "TC3_step12b_evidence" @("ls -l $rel", "bin/tc3 status")
  }
  if (-not $NoFetch) {
    $dst = Join-Path $CapDir "evidence"; New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Write-Host "증빙 가져오기: scp -r ${Target}:$run $dst" -ForegroundColor Cyan
    $ScpArgs = @($SshArgs | ForEach-Object { if ($_ -ceq '-p') { '-P' } else { $_ } })   # scp 의 포트 옵션은 -P
    & scp -r -q -o BatchMode=yes -o ConnectTimeout=15 @ScpArgs "${Target}:$run" $dst
  }
}


# ---------- INDEX.md (시험절차서 작성용 캡처 목록) + 전달용 압축 ----------
if ($script:Index.Count -gt 0) {
  $runBase = $(if ($run) { ($run -split '/')[-1] } else { "" })
  $ev = $(if ($runBase) { Join-Path $CapDir "evidence\$runBase" } else { "" })
  $sum = $null; $npu = $null; $soakS = $null
  if ($ev -and (Test-Path "$ev\summary.json")) { try { $sum = Get-Content "$ev\summary.json" -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
  if ($ev -and (Test-Path "$ev\npu_summary.json")) { try { $npu = Get-Content "$ev\npu_summary.json" -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
  if ($ev -and (Test-Path "$ev\soak_summary.json")) { try { $soakS = Get-Content "$ev\soak_summary.json" -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
  $kitRev = Get-Vm "cd $KitDir && git log -1 --oneline"
  $md = New-Object System.Collections.Generic.List[string]
  $md.Add("# TC3 시험 절차 화면 캡처 목록 — $Stamp")
  $md.Add("")
  $md.Add("시험절차서 작성용. 시험 실행기 ``./start.sh`` 의 항목 순서대로 실제 터미널 화면을 캡처했다.")
  $md.Add("")
  $md.Add("| 항목 | 내용 |")
  $md.Add("|---|---|")
  $md.Add("| 대상 | ``$hn`` (ssh $Target) |")
  $md.Add("| 키트 | ``$kitRev`` |")
  if ($runBase) { $md.Add("| 증빙 run | ``evidence/$runBase`` (이 폴더의 ``evidence/$runBase/`` 에 원본 전체) |") }
  if ($sum) {
    $md.Add("| 종합 판정 | **$($sum.overall)** — $((@($sum.criteria.PSObject.Properties) | ForEach-Object { "$($_.Name): $($_.Value)" }) -join ' · ') |")
    if ($sum.total_params) { $md.Add("| 모델 | $($sum.model) — 파라미터 $('{0:N0}' -f [int64]$sum.total_params) |") }
  }
  if ($soakS) { $md.Add(("| 연속 요청 | {0}/{1} 성공 ({2}%), p50 {3:N3} s · p95 {4:N3} s · 최대 {5:N3} s |" -f $soakS.ok, $soakS.n, $soakS.success_pct, $soakS.p50, $soakS.p95, $soakS.max)) }
  if ($npu) { $md.Add(("| NPU 점유(참고) | 평균 {0}% · 최대 {1}% · 메모리 최대 {2} / {3} GiB |" -f $npu.overall.util_avg, $npu.overall.util_max, $npu.overall.mem_max_gib, $npu.mem_total_gib)) }
  $md.Add("")
  $md.Add("## 시험 실행기 start.sh 의 명령")
  $md.Add("")
  $md.Add("| 메뉴 | 실행하는 명령 | 하는 일 |")
  $md.Add("|---|---|---|")
  $md.Add("| 1 사전준비 확인 | ``bin/tc3 preflight`` | 미리 준비한 버전·모델 파일·포트·디스크·시계·NPU 를 기대값/실제값 표로 확인, 결과를 ``prep_check.log/json`` 에 저장 |")
  $md.Add("| 2 시험 스크립트 재생 | ``bin/tc3 live`` | 절차 4~12(env → model-size → serve → verify → soak → stop → report)를 한 번에 실행. 왼쪽 실시간 출력, 오른쪽 NPU 상태(1초), NPU 사용률 기록·그래프 |")
  $md.Add("| 3 결과 보기 | ``bin/tc3 result && bin/tc3 result --files`` | ``RESULT.md``(판정 A~D, NPU 점유, 소크 통계, 단계별 결과·소요, 증빙 파일·해시) 생성·출력 후 주요 로그 출력 |")
  $md.Add("")
  $md.Add("## 캡처 ($($script:Index.Count)장)")
  $md.Add("")
  $md.Add("| # | 파일 | 단계 | 화면의 명령 | 화면 내용 |")
  $md.Add("|---|---|---|---|---|")
  foreach ($r in $script:Index) {
    $c = ($r.Cmd -replace '\|', '\|'); if ($c.Length -gt 90) { $c = $c.Substring(0, 87) + "..." }
    $md.Add("| $($r.Seq) | ``$($r.File)`` | $($r.Stage) | ``$c`` | $($r.Desc) |")
  }
  $md.Add("")
  $md.Add("## 함께 전달하는 파일")
  $md.Add("")
  if ($runBase) {
    $md.Add("- ``evidence/$runBase/RESULT.md`` — 결과 문서 (판정·NPU·소크·단계·증빙 파일 목록)")
    $md.Add("- ``evidence/$runBase/npu_utilization.png`` — NPU 사용률·메모리 타임라인 그래프 (화면 캡처가 아닌 그래프 이미지)")
    $md.Add("- ``evidence/$runBase/soak_answers.jsonl`` — 연속 요청 100건의 질문·응답 전문 (한국어 50·영어 50)")
    $md.Add("- ``evidence/$runBase/`` — 단계별 로그(stepNN_*.log), prep_check, report.md, summary.json, SHA256SUMS 등 원본 전체")
  }
  $md.Add("- ``steps.tsv`` — 캡처 순서와 각 명령의 종료코드")
  [IO.File]::WriteAllLines((Join-Path $CapDir "INDEX.md"), $md, (New-Object Text.UTF8Encoding($false)))
  Get-ChildItem $CapDir -Filter ".phase_watch*" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  $zip = "$CapDir.zip"
  try { Compress-Archive -Path (Join-Path $CapDir "*") -DestinationPath $zip -Force; Write-Host "전달용 압축: $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)" -ForegroundColor Cyan }
  catch { Write-Warning "압축 실패: $($_.Exception.Message)" }
  Write-Host "캡처 목록: $(Join-Path $CapDir 'INDEX.md') — $($script:Index.Count)장" -ForegroundColor Cyan
}

Write-Host ""
$failed = @($Results.Keys | Where-Object { "$($Results[$_])" -ne "0" })
$Results.GetEnumerator() | ForEach-Object { "{0,-26} {1}" -f $_.Key, $(if ("$($_.Value)" -eq "0") { "ok" } elseif ($_.Value -eq "skip") { "SKIP" } else { "rc=$($_.Value)" }) } | Out-Host
if ($failed.Count -gt 0) {
  Write-Host "완료(실패 단계 있음: $($failed -join ', ')) — 캡처: $CapDir" -ForegroundColor Red
} else {
  Write-Host "완료 — 모든 단계 정상. 캡처: $CapDir" -ForegroundColor Green
}
Get-ChildItem $CapDir -Filter *.png | Select-Object Name, Length | Format-Table -AutoSize
if ($failed.Count -gt 0) { exit 1 }

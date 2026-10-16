<#
.SYNOPSIS
  TC3 로컬 시뮬레이션 — Docker(VM 대용)로 tc3-kit 절차를 단계별로 실행하고, 각 단계가 끝날 때마다
  현재 터미널 창을 그대로 PNG 로 캡처한다 (실제 화면 캡처: GDI CopyFromScreen).

.USAGE  (Windows PowerShell 5.1 / PowerShell 7, Docker Desktop 실행 중)
  cd $HOME\repos\tc3-kit
  Set-ExecutionPolicy -Scope Process Bypass -Force
  .\tc3-capture.ps1                 # 기본: 소크 10회, 파라미터 수는 fixture(합성) 사용
  .\tc3-capture.ps1 -SoakN 20       # 소크 횟수 변경
  .\tc3-capture.ps1 -RealWeights    # models\Llama-3.1-8B-Instruct 에 원본 safetensors 가 있으면 실측(8,030,261,248)
  .\tc3-capture.ps1 -SkipBuild      # tester 이미지 빌드 생략

.OUTPUT
  captures\<YYYYMMDD-HHMMSS>\TC3_stepNN_*.png   — 단계별 터미널 창 캡처 (실제 화면)
  captures\<YYYYMMDD-HHMMSS>\TC3_stepNN_*.txt   — 같은 단계의 전체 출력 텍스트
  evidence\<run>\                                — 키트가 저장하는 증빙 로그 (컨테이너가 /kit 에 기록)
#>
param(
  [int]$SoakN = 10,
  [switch]$RealWeights,
  [switch]$SkipBuild,
  [int]$ReadyTimeoutSec = 2400
)
$ErrorActionPreference = "Continue"
# 컨테이너 출력(UTF-8)의 한글이 깨지지 않도록 콘솔 인코딩을 UTF-8 로 (Windows PowerShell 5.1 기본은 CP949)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$Kit = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Kit
$Compose = @("compose", "-f", "docker/compose.local.yml")
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$CapDir = Join-Path $Kit "captures\$Stamp"
New-Item -ItemType Directory -Force -Path $CapDir | Out-Null
# 이전 실행의 run 포인터가 남아 있으면 새 증빙 디렉터리 대신 옛 run 에 누적되므로 제거
Remove-Item (Join-Path $Kit "evidence\.current_run") -ErrorAction SilentlyContinue

# ---------- 화면 캡처 (현재 전면 창) ----------
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class TC3Win {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[TC3Win]::SetProcessDPIAware() | Out-Null

# 캡처 대상 = 스크립트 시작 시점의 전면 창(이 스크립트를 띄운 터미널). 이후 사용자가 다른 창을 앞으로 가져와도
# 같은 터미널 창을 PrintWindow 로 찍는다 (가려져 있어도 창 내용 그대로, 포커스를 뺏지 않음).
$script:TermHwnd = [TC3Win]::GetForegroundWindow()
$cls = New-Object System.Text.StringBuilder 256; [TC3Win]::GetClassName($script:TermHwnd, $cls, 256) | Out-Null
if ($cls.ToString() -notin @("CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass")) {
  Write-Warning "시작 시 전면 창이 터미널이 아닙니다 (class=$cls) — 단계마다 그 시점의 전면 창을 캡처합니다"
  $script:TermHwnd = [IntPtr]::Zero
}

function Snap([string]$name) {
  Start-Sleep -Milliseconds 700
  $h = $(if ($script:TermHwnd -ne [IntPtr]::Zero) { $script:TermHwnd } else { [TC3Win]::GetForegroundWindow() })
  if ([TC3Win]::IsIconic($h)) { Write-Warning "터미널 창이 최소화되어 있어 캡처가 비어 보일 수 있습니다" }
  $wr = New-Object TC3Win+RECT
  [TC3Win]::GetWindowRect($h, [ref]$wr) | Out-Null
  $r = New-Object TC3Win+RECT
  # DWMWA_EXTENDED_FRAME_BOUNDS(9): Windows 10/11 의 보이지 않는 테두리를 뺀 실제 창 영역 (실패 시 GetWindowRect)
  if ([TC3Win]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { $r = $wr }
  $w = $r.R - $r.L; $hh = $r.B - $r.T
  if ($w -le 0 -or $hh -le 0) { Write-Warning "창 크기를 읽지 못해 전체 화면을 캡처합니다"; $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $r.L=$b.Left; $r.T=$b.Top; $r.R=$b.Right; $r.B=$b.Bottom; $wr=$r; $w=$b.Width; $hh=$b.Height; $h=[IntPtr]::Zero }
  $p = Join-Path $CapDir "$name.png"
  # PrintWindow(PW_RENDERFULLCONTENT=2): 창 전체(테두리 포함)를 그린 뒤 실제 창 영역만 잘라 저장
  $full = New-Object System.Drawing.Bitmap ($wr.R - $wr.L), ($wr.B - $wr.T)
  $g = [System.Drawing.Graphics]::FromImage($full); $hdc = $g.GetHdc()
  $ok = ($h -ne [IntPtr]::Zero) -and [TC3Win]::PrintWindow($h, $hdc, 2)
  $g.ReleaseHdc($hdc); $g.Dispose()
  if ($ok) {
    $bmp = $full.Clone((New-Object System.Drawing.Rectangle ($r.L - $wr.L), ($r.T - $wr.T), $w, $hh), $full.PixelFormat)
  } else {
    # 대체: 화면에서 창 영역을 그대로 복사 (가려져 있으면 가린 창이 찍힘)
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g2 = [System.Drawing.Graphics]::FromImage($bmp); $g2.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size); $g2.Dispose()
  }
  $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $full.Dispose()
  Write-Host "  [capture] $p" -ForegroundColor DarkGray
}

function Prompt-Line([string]$cmd) {
  Write-Host ("PS " + (Get-Location).Path + "> ") -NoNewline -ForegroundColor Yellow
  Write-Host $cmd -ForegroundColor White
}

function Run-Step([string]$name, [string[]]$dockerArgs, [string]$shown) {
  # $args 는 PowerShell 자동 변수라 파라미터 이름으로 쓰면 바인딩되지 않는다 → $dockerArgs
  Clear-Host
  Prompt-Line $shown
  $log = Join-Path $CapDir "$name.txt"
  $sw = New-Object System.IO.StreamWriter($log, $false, (New-Object System.Text.UTF8Encoding($false)))
  $sw.WriteLine("PS> $shown")
  # 출력은 Out-Host 로 화면에 직접 보낸다 (함수 출력은 호출측 | Out-Null 에 버려짐). stderr 레코드는 문자열로 변환.
  & docker @dockerArgs 2>&1 | ForEach-Object { $line = "$_"; $sw.WriteLine($line); $sw.Flush(); $line } | Out-Host
  $code = $LASTEXITCODE
  $sw.Close()
  Write-Host ""
  Prompt-Line ""
  Snap $name
  return $code
}

# ---------- 0) 준비 ----------
Clear-Host
Prompt-Line "docker version"
docker version
if ($LASTEXITCODE -ne 0) { Write-Error "Docker 엔진에 연결할 수 없습니다. Docker Desktop 을 실행한 뒤 다시 시도하세요."; exit 1 }
Prompt-Line "git log -1 --oneline"
git log -1 --oneline 2>$null
Snap "TC3_step00_docker_and_kit"

if (-not $SkipBuild) {
  Clear-Host; Prompt-Line "docker compose -f docker/compose.local.yml build tester"
  & docker @Compose build tester
}

$env:TC3_SOAK_N = "$SoakN"
$env:TC3_FIXTURE = $(if ($RealWeights) { "0" } else { "1" })
if ($RealWeights -and -not (Test-Path "$Kit\models\Llama-3.1-8B-Instruct\config.json")) {
  Write-Warning "models\Llama-3.1-8B-Instruct 가 없어 fixture 로 진행합니다 (README B절 참고)"; $env:TC3_FIXTURE = "1"
}

# ---------- 1) 추론 서버(llama.cpp + Llama-3.1-8B-Instruct GGUF) ----------
Clear-Host
Prompt-Line "docker compose -f docker/compose.local.yml up -d llm"
& docker @Compose up -d llm
$cid = (& docker @Compose ps -q llm)
Write-Host "llama.cpp 서버 준비 대기 (첫 실행은 GGUF 4.9GB 다운로드 + 적재) ..." -ForegroundColor Cyan
$t0 = Get-Date
do {
  Start-Sleep -Seconds 15
  $st = (& docker inspect -f '{{.State.Health.Status}}' $cid 2>$null)
  $el = [int]((Get-Date) - $t0).TotalSeconds
  Write-Host ("  [{0,5}s] health = {1}" -f $el, $st)
  if ($el -gt $ReadyTimeoutSec) { Write-Error "서버 준비 시간 초과 — docker compose logs llm 확인"; exit 2 }
} while ($st -ne "healthy")
Prompt-Line "docker compose -f docker/compose.local.yml ps; docker compose -f docker/compose.local.yml logs --tail 12 llm"
& docker @Compose ps
& docker @Compose logs --tail 12 llm
Prompt-Line "curl.exe -s http://localhost:8000/v1/models"
curl.exe -s http://localhost:8000/v1/models | ConvertFrom-Json | ConvertTo-Json -Depth 6
Snap "TC3_step06a_llm_server_ready"

# ---------- 2) 절차 4~12 ----------
$steps = @(
  @{ n = "TC3_step04_env";        c = "env" },
  @{ n = "TC3_step05_model_size"; c = "model-size" },
  @{ n = "TC3_step06_serve";      c = "serve" },
  @{ n = "TC3_step07-09_verify";  c = "verify" },
  @{ n = "TC3_step10_soak";       c = "soak" },
  @{ n = "TC3_step11_stop";       c = "stop" },
  @{ n = "TC3_step12_report";     c = "report" }
)
foreach ($s in $steps) {
  $shown = "docker compose -f docker/compose.local.yml run --rm tester " + $s.c
  Run-Step $s.n ($Compose + @("run", "--rm", "tester", $s.c)) $shown | Out-Null
}

# report.md 전체 + 증빙 디렉터리
$run = Get-Content (Join-Path $Kit "evidence\.current_run") -ErrorAction SilentlyContinue
if ($run) {
  $runWin = $run -replace '^/kit/', "$Kit\" -replace '/', '\'
  Clear-Host
  Prompt-Line "Get-Content $runWin\report.md"
  Get-Content "$runWin\report.md" -Encoding UTF8
  Snap "TC3_step12_report_md"
  Clear-Host
  Prompt-Line "Get-ChildItem $runWin"
  Get-ChildItem $runWin
  Prompt-Line "docker compose -f docker/compose.local.yml run --rm tester status"
  & docker @Compose run --rm tester status
  Snap "TC3_step12b_evidence"
}

# ---------- 3) 정리 ----------
Clear-Host
Prompt-Line "docker compose -f docker/compose.local.yml stop llm"
& docker @Compose stop llm
Snap "TC3_step13_cleanup"

Write-Host ""
Write-Host "완료 — 캡처: $CapDir" -ForegroundColor Green
Get-ChildItem $CapDir -Filter *.png | Select-Object Name, Length | Format-Table -AutoSize

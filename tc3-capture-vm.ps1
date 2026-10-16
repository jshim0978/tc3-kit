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
  [switch]$NoFetch
)
$ErrorActionPreference = "Continue"
# powershell -File 로 실행하면 배열 인자가 "a,b" 한 문자열로 들어오므로 쉼표로 나눈다
$Steps   = @($Steps   | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$SshArgs = @($SshArgs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
# 별도 ssh 설정 파일 (점프 호스트·포트·키를 담은 config) — powershell -File 로도 넘길 수 있는 단일 문자열 인자
if ($SshConfig) { $SshArgs = @("-F", $SshConfig) + $SshArgs }
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
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[TC3VmWin]::SetProcessDPIAware() | Out-Null
$script:TermHwnd = [TC3VmWin]::GetForegroundWindow()
$cls = New-Object System.Text.StringBuilder 256; [TC3VmWin]::GetClassName($script:TermHwnd, $cls, 256) | Out-Null
if ($cls.ToString() -notin @("CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass")) {
  Write-Warning "시작 시 전면 창이 터미널이 아닙니다 (class=$cls) — 단계마다 그 시점의 전면 창을 캡처합니다"
  $script:TermHwnd = [IntPtr]::Zero
}

function Snap([string]$name) {
  Start-Sleep -Milliseconds 700
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
  Write-Host "  [capture] $p" -ForegroundColor DarkGray
}

# ---------- VM 실행 ----------
# 명령을 VM 의 bash 스크립트로 만들어 base64 로 보낸다 (PowerShell 5.1 의 인자 따옴표 문제 회피).
# 스크립트는 VM 의 실제 프롬프트 형식(Ubuntu 기본 PS1 색)으로 "user@host:~/dir$ 명령" 을 찍고 명령을 실행한다.
function Invoke-Vm([string[]]$commands, [string]$cwd = $KitDir, [switch]$Quiet) {
  # 주의: PowerShell 에서 , 가 + 보다 먼저 결합 → 첫 원소는 괄호로 감싸야 함
  $lines = @(('cd ' + $cwd + ' 2>/dev/null || cd ~'),
             'P="$(printf ''\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m$ '' "$(id -un)" "$(hostname -s)" "$(dirs +0)")"',
             'rc=0')
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
  $argv = @("-t") + $SshArgs + @($Target, $remote) | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
  $p = Start-Process -FilePath "ssh" -ArgumentList ($argv -join ' ') -NoNewWindow -PassThru
  $null = $p.Handle   # PS 5.1: 핸들을 잡아 두지 않으면 ExitCode 가 비는 문제
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

# ---------- 0) 접속·키트 ----------
Write-Host "VM 접속 확인: ssh $Target" -ForegroundColor Cyan
$hn = Get-Vm "hostname"
if (-not $hn) { Write-Error "ssh $Target 접속 실패 — ~/.ssh/config, 키, 점프 호스트 확인"; exit 1 }

$Results = [ordered]@{}
if ($Clone) {
  if (-not $RepoUrl) { Write-Error "-Clone 에는 -RepoUrl 이 필요합니다"; exit 1 }
  # 비공개 저장소면 git 이 Username/Password(토큰)를 묻는다 — 사람이 이 창에 입력 (스크립트는 입력하지 않음)
  if ($RepoUrl -match '^https://') { try { [console]::Beep(880, 250); [console]::Beep(1175, 250) } catch { } }
  $Results["TC3_step00a_clone"] = Step "TC3_step00a_clone" @("git clone $RepoUrl $KitDir", "cd $KitDir && cp tc3.env.example tc3.env && git log -1 --oneline") "~"
  if ($Results["TC3_step00a_clone"] -ne 0) {
    Write-Error "git clone 실패 (이미 $KitDir 가 있거나 저장소 접근 불가) — 이전 키트로 진행하지 않도록 중단합니다"; exit 1
  }
}
$Results["TC3_step00_vm_and_kit"] = Step "TC3_step00_vm_and_kit" @("hostname; grep PRETTY_NAME /etc/os-release; uname -r", "git log -1 --oneline", "grep -E '^TC3_(BACKEND|MODEL_NAME|MODEL_DIR|ARTIFACT_DIR|DEVICES|SOAK_N|PORT)=' tc3.env")

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
if (-not $NoPreflight) { $Results["TC3_step00b_preflight"] = Step "TC3_step00b_preflight" @("bin/tc3 preflight") }

# ---------- 1) 절차 4~12 ----------
$names = @{ "env" = "TC3_step04_env"; "model-size" = "TC3_step05_model_size"; "serve" = "TC3_step06_serve"; "verify" = "TC3_step07-09_verify";
            "soak" = "TC3_step10_soak"; "stop" = "TC3_step11_stop"; "report" = "TC3_step12_report" }
$serveFailed = $false
foreach ($s in $Steps) {
  $n = $(if ($names.ContainsKey($s)) { $names[$s] } else { "TC3_step_" + $s })
  if ($serveFailed -and $s -in @("verify", "soak")) { Write-Warning "serve 실패 → $s 생략"; $Results[$n] = "skip"; continue }
  $Results[$n] = Step $n @("bin/tc3 $s")
  if ($s -eq "serve" -and $Results[$n] -ne 0) { $serveFailed = $true }
}

# report.md 전체 + 증빙 목록 + status
$run = Get-Vm "cat $KitDir/evidence/.current_run 2>/dev/null"
if ($run) {
  $rel = "evidence/" + ($run -split '/')[-1]
  $Results["TC3_step12_report_md"] = Step "TC3_step12_report_md" @("cat $rel/report.md")
  $Results["TC3_step12b_evidence"] = Step "TC3_step12b_evidence" @("ls -l $rel", "bin/tc3 status")
  if (-not $NoFetch) {
    $dst = Join-Path $CapDir "evidence"; New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Write-Host "증빙 가져오기: scp -r ${Target}:$run $dst" -ForegroundColor Cyan
    $ScpArgs = @($SshArgs | ForEach-Object { if ($_ -ceq '-p') { '-P' } else { $_ } })   # scp 의 포트 옵션은 -P
    & scp -r -q -o BatchMode=yes -o ConnectTimeout=15 @ScpArgs "${Target}:$run" $dst
  }
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

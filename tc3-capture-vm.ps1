<#
.SYNOPSIS
  TC3 — 시험용 VM 에서 키트 절차를 SSH 로 실행하고, 단계마다 이 PC 의 터미널 창을 PNG 로 캡처한다.
  시험 당일과 같은 화면: VM 의 bash 프롬프트(user@host:~/tc3-kit$) + 명령 + 실제 출력(색 포함, ssh pty).

.USAGE  (보이는 새 Windows Terminal 창에서 실행 — 캡처 대상은 이 스크립트를 띄운 터미널 창)
  Start-Process wt.exe -ArgumentList '-w new --size 160,60 -d C:\Users\etri-jws\repos\tc3-kit powershell -NoExit -ExecutionPolicy Bypass -File .\tc3-capture-vm.ps1 -Target llmvm'
  옵션: -KitDir ~/tc3-kit  -Steps env,model-size,...  -RepoUrl <url> (-Clone 과 함께: 새로 clone 하는 장면부터 캡처)
        -SshArgs '-p','2222','-i','key'  -NoPreflight  -NoFetch

.OUTPUT
  captures\<YYYYMMDD-HHMMSS>-vm\TC3_stepNN_*.png  + evidence\<run>\ (VM 에서 scp 로 가져온 증빙)
#>
param(
  [Parameter(Mandatory = $true)] [string]$Target,
  [string]$KitDir = "~/tc3-kit",
  [string[]]$Steps = @("env", "model-size", "serve", "verify", "soak", "stop", "report"),
  [string[]]$SshArgs = @(),
  [string]$RepoUrl = "",
  [switch]$Clone,
  [switch]$NoPreflight,
  [switch]$NoFetch
)
$ErrorActionPreference = "Continue"
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
  $lines = @('cd ' + $cwd + ' 2>/dev/null || cd ~',
             'P="$(printf ''\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m$ '' "$(id -un)" "$(hostname -s)" "$(dirs +0)")"',
             'rc=0')
  foreach ($c in $commands) {
    $q = $c.Replace("'", "'\''")
    if (-not $Quiet) { $lines += "printf '%s%s\n' `"`$P`" '$q'" }
    $lines += "$c; rc=`$?"
  }
  if (-not $Quiet) { $lines += 'printf ''%s\n'' "$P"' }
  $lines += 'exit $rc'
  $script = ($lines -join "`n") + "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
  $remote = "echo $b64 | base64 -d > /tmp/.tc3_capture_step.sh && bash /tmp/.tc3_capture_step.sh; r=`$?; rm -f /tmp/.tc3_capture_step.sh; exit `$r"
  & ssh -t @SshArgs $Target $remote
  return $LASTEXITCODE
}
function Get-Vm([string]$cmd) { (& ssh @SshArgs $Target $cmd 2>$null | Out-String).Trim() }

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

if ($Clone) {
  if (-not $RepoUrl) { Write-Error "-Clone 에는 -RepoUrl 이 필요합니다"; exit 1 }
  Step "TC3_step00a_clone" @("git clone $RepoUrl $KitDir", "cd $KitDir && cp tc3.env.example tc3.env && git log -1 --oneline") "~" | Out-Null
}
Step "TC3_step00_vm_and_kit" @("hostname; grep PRETTY_NAME /etc/os-release; uname -r", "git log -1 --oneline", "grep -E '^TC3_(BACKEND|MODEL_NAME|MODEL_DIR|ARTIFACT_DIR|DEVICES|SOAK_N|PORT)=' tc3.env") | Out-Null
if (-not $NoPreflight) { Step "TC3_step00b_preflight" @("bin/tc3 preflight") | Out-Null }

# ---------- 1) 절차 4~12 ----------
$names = @{ "env" = "TC3_step04_env"; "model-size" = "TC3_step05_model_size"; "serve" = "TC3_step06_serve"; "verify" = "TC3_step07-09_verify";
            "soak" = "TC3_step10_soak"; "stop" = "TC3_step11_stop"; "report" = "TC3_step12_report" }
foreach ($s in $Steps) {
  $n = $(if ($names.ContainsKey($s)) { $names[$s] } else { "TC3_step_" + $s })
  Step $n @("bin/tc3 $s") | Out-Null
}

# report.md 전체 + 증빙 목록 + status
$run = Get-Vm "cat $KitDir/evidence/.current_run 2>/dev/null"
if ($run) {
  $rel = "evidence/" + ($run -split '/')[-1]
  Step "TC3_step12_report_md" @("cat $rel/report.md") | Out-Null
  Step "TC3_step12b_evidence" @("ls -l $rel", "bin/tc3 status") | Out-Null
  if (-not $NoFetch) {
    $dst = Join-Path $CapDir "evidence"; New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Write-Host "증빙 가져오기: scp -r ${Target}:$run $dst" -ForegroundColor Cyan
    $ScpArgs = @($SshArgs | ForEach-Object { if ($_ -ceq '-p') { '-P' } else { $_ } })   # scp 의 포트 옵션은 -P
    & scp -r -q @ScpArgs "${Target}:$run" $dst
  }
}

Write-Host ""
Write-Host "완료 — 캡처: $CapDir" -ForegroundColor Green
Get-ChildItem $CapDir -Filter *.png | Select-Object Name, Length | Format-Table -AutoSize

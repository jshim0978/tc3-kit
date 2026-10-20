<#
.SYNOPSIS
  kcloud 시범서비스 포털(Horizon/portal) 접속 준비 — 이 PC 설정 (관리자 권한: UAC 확인 창에서 '예')

.DESCRIPTION
  1) kcloud-root-ca 를 '신뢰할 수 있는 루트 인증 기관'(로컬 컴퓨터)에 등록 — SHA-256 지문이 맞을 때만
  2) hosts 에 127.0.0.1 horizon|portal|temporal|keycloak.kcloud.etri 추가 (원본은 hosts.tc3-bak-<시각> 으로 백업)
  3) 터널(127.0.0.1:25443)이 떠 있으면 https://<이름>.kcloud.etri:25443 을 Windows 인증서 검증으로 확인
  -Undo : 1)·2) 를 되돌림 (2026-11 시험이 끝나면)

  터널은 별도 창에서 (창을 닫으면 끊김):
    ssh -F ~/.ssh/tc3_kcloud_config -N kcloud-tunnel
    (= ssh -L 25443:210.114.95.50:25443 openkcloud@101.79.0.102 -p 122)

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\kcloud-pc-access.ps1
  powershell -ExecutionPolicy Bypass -File tools\kcloud-pc-access.ps1 -Undo
#>
param(
    [string]$CaPath = "$env:USERPROFILE\Downloads\kcloud-ca.crt",
    # CN=kcloud-root-ca (2026-06-25 ~ 2036-06-22). 2026-10-20 확인: 포털이 내보내는 *.kcloud.etri 인증서를 이 CA 가 서명함
    [string]$Sha256 = '4D90B9819070692A5FF6CD8BA287B3F6009A3A1503DBC73EBC7224AF2EF9C6AF',
    [switch]$Undo
)
$ErrorActionPreference = 'Stop'
$Names = @('horizon', 'portal', 'temporal', 'keycloak') | ForEach-Object { "$_.kcloud.etri" }
$Port = 25443
$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$Tag = '# tc3 kcloud tunnel'
$Off = '# [tc3 off] '
$Want = ($Sha256 -replace '[:\s]', '').ToUpper()

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # 관리자 창으로 다시 실행
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-CaPath', "`"$CaPath`"", '-Sha256', $Want)
    if ($Undo) { $argv += '-Undo' }
    Start-Process powershell -Verb RunAs -ArgumentList $argv
    return
}

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }

function Get-Sha256Hex($cert) {
    (([Security.Cryptography.SHA256]::Create().ComputeHash($cert.RawData)) | ForEach-Object { $_.ToString('X2') }) -join ''
}

function Open-Root {
    $s = New-Object Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
    $s.Open('ReadWrite')
    $s
}

function Add-Ca {
    if (-not (Test-Path -LiteralPath $CaPath)) { throw "CA 파일이 없습니다: $CaPath  (Dooray 첨부 kcloud-ca.crt 를 받아 두거나 -CaPath 로 지정)" }
    $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path -LiteralPath $CaPath).Path)
    $fp = Get-Sha256Hex $c
    if ($fp -ne $Want) { throw "지문이 다릅니다 — 등록하지 않습니다.`n  파일: $fp`n  기대: $Want" }
    if ($c.Subject -ne 'CN=kcloud-root-ca' -or $c.Issuer -ne $c.Subject) { throw "kcloud 루트 CA 가 아닙니다: subject=$($c.Subject) issuer=$($c.Issuer)" }
    $s = Open-Root
    try {
        if ($s.Certificates.Find('FindByThumbprint', $c.Thumbprint, $false).Count -gt 0) {
            Say "  이미 등록됨: $($c.Subject)  SHA1 $($c.Thumbprint)"
        } else {
            $s.Add($c)
            Say "  등록: $($c.Subject)  만료 $($c.NotAfter.ToString('yyyy-MM-dd'))  SHA1 $($c.Thumbprint)" Green
        }
    } finally { $s.Close() }
}

function Remove-Ca {
    $s = Open-Root
    try {
        $hit = @($s.Certificates | Where-Object { $_.Subject -eq 'CN=kcloud-root-ca' -and (Get-Sha256Hex $_) -eq $Want })
        if ($hit.Count -eq 0) { Say '  등록된 kcloud-root-ca 없음' }
        foreach ($c in $hit) { $s.Remove($c); Say "  해제: $($c.Subject)  SHA1 $($c.Thumbprint)" Green }
    } finally { $s.Close() }
}

# hosts 는 보통 ASCII. UTF-8 이 아니면(예: CP949 주석) 시스템 ANSI 코드페이지로 읽고 같은 인코딩으로 다시 쓴다
$script:HostsEnc = New-Object Text.UTF8Encoding($false)
function Read-Hosts {
    if (-not (Test-Path -LiteralPath $HostsPath)) { return @() }
    $bytes = [IO.File]::ReadAllBytes($HostsPath)
    $script:HostsEnc = New-Object Text.UTF8Encoding($false)
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { $script:HostsEnc = [Text.Encoding]::Default; $text = $script:HostsEnc.GetString($bytes) }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    if ($text.Length -eq 0) { return @() }
    $lines = @($text -split "`r?`n")
    if ($lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }   # 마지막 줄바꿈
    $lines
}

function Write-Hosts([string[]]$lines) {
    if (Test-Path -LiteralPath $HostsPath) {
        $bak = "$HostsPath.tc3-bak-$(Get-Date -Format yyyyMMdd-HHmmss-fff)"
        Copy-Item -LiteralPath $HostsPath $bak
        Say "  백업: $bak"
    }
    [IO.File]::WriteAllLines($HostsPath, $lines, $script:HostsEnc)
}

# 주석이 아닌 부분에 이름이 별칭으로 들어 있으면 그 줄의 IP, 아니면 $null
function Get-LineIp([string]$line, [string]$name) {
    $body = ($line -split '#', 2)[0].Trim()
    if (-not $body) { return $null }
    $tok = @($body -split '\s+')
    if ($tok.Count -ge 2 -and ($tok[1..($tok.Count - 1)] -contains $name)) { return $tok[0] }
    $null
}

function Add-HostsEntries {
    $lines = Read-Hosts
    $out = New-Object System.Collections.Generic.List[string]
    $have = @{}
    $changed = $false
    foreach ($l in $lines) {
        $ips = @($Names | ForEach-Object { $ip = Get-LineIp $l $_; if ($ip) { [pscustomobject]@{ Name = $_; Ip = $ip } } })
        if ($ips.Count -eq 0) { $out.Add($l); continue }
        if (@($ips | Where-Object { $_.Ip -ne '127.0.0.1' }).Count -eq 0) {
            foreach ($x in $ips) { $have[$x.Name] = $true }
            $out.Add($l); continue
        }
        Say "  다른 주소로 잡힌 줄 → 주석 처리 (-Undo 로 복원): $l" Yellow
        $out.Add($Off + $l); $changed = $true
    }
    foreach ($n in $Names) {
        if (-not $have[$n]) { $out.Add("127.0.0.1 $n $Tag"); $changed = $true; Say "  추가: 127.0.0.1 $n" Green }
        else { Say "  이미 있음: 127.0.0.1 $n" }
    }
    if ($changed) { Write-Hosts $out.ToArray() }
}

function Remove-HostsEntries {
    $lines = Read-Hosts
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        if ($l.EndsWith($Tag)) { Say "  제거: $l" Green; continue }
        if ($l.StartsWith($Off)) { $out.Add($l.Substring($Off.Length)); Say "  복원: $($l.Substring($Off.Length))" Green; continue }
        $out.Add($l)
    }
    if ($out.Count -ne $lines.Count -or ($out.ToArray() -join "`n") -ne ($lines -join "`n")) { Write-Hosts $out.ToArray() }
    else { Say '  hosts 에 tc3 항목 없음' }
}

function Test-Portal {
    $tcp = New-Object Net.Sockets.TcpClient
    $up = $false
    try { $up = $tcp.ConnectAsync('127.0.0.1', $Port).Wait(2000) } catch { $up = $false } finally { $tcp.Close() }
    foreach ($n in $Names) {
        $ip = try { ([Net.Dns]::GetHostAddresses($n) | ForEach-Object { $_.IPAddressToString }) -join ',' } catch { '(이름 풀이 실패)' }
        if (-not $up) { Say "  $n → $ip" ; continue }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = [Net.HttpWebRequest]::Create("https://${n}:$Port/")
        $r.AllowAutoRedirect = $false; $r.Timeout = 15000; $r.Proxy = $null
        $res = ''
        try { $resp = $r.GetResponse(); $res = "HTTP $([int]$resp.StatusCode)"; $resp.Close() }
        catch [Net.WebException] {
            if ($_.Exception.Response) { $res = "HTTP $([int]$_.Exception.Response.StatusCode)"; $_.Exception.Response.Close() }
            else { $res = "실패 ($($_.Exception.Status))" }
        }
        $ok = $res -like 'HTTP *'
        Say ("  {0} → {1}  https {2}{3}" -f $n, $ip, $res, $(if ($ok) { ' — 인증서 신뢰됨' } else { '' })) $(if ($ok) { 'Green' } else { 'Red' })
    }
    if (-not $up) { Say "  터널이 꺼져 있습니다 (127.0.0.1:$Port). 별도 창에서: ssh -F ~/.ssh/tc3_kcloud_config -N kcloud-tunnel" Yellow }
}

$Host.UI.RawUI.WindowTitle = 'kcloud 포털 접속 준비'
try {
    if ($Undo) {
        Say '[1/2] kcloud-root-ca 신뢰 해제' Cyan; Remove-Ca
        Say '[2/2] hosts 의 tc3 항목 제거' Cyan; Remove-HostsEntries
        ipconfig /flushdns | Out-Null
        Say '되돌리기 완료.' Green
    } else {
        Say '[1/3] kcloud-root-ca 를 신뢰할 수 있는 루트 인증 기관(로컬 컴퓨터)에 등록' Cyan; Add-Ca
        Say '[2/3] hosts: 127.0.0.1 → horizon|portal|temporal|keycloak.kcloud.etri' Cyan; Add-HostsEntries
        ipconfig /flushdns | Out-Null
        Say '[3/3] 확인' Cyan; Test-Portal
        Say ''
        Say "브라우저에서 https://horizon.kcloud.etri:$Port , https://portal.kcloud.etri:$Port  (열려 있던 브라우저는 다시 시작)" Cyan
    }
} catch {
    Say "실패: $($_.Exception.Message)" Red
}
Write-Host ''
Read-Host '엔터를 누르면 창을 닫습니다' | Out-Null

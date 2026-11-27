# probe-camera-winshadow: the shadow server's virtual camera on a hosted Windows runner, as
# shipped: the Windows host built with HOST_CAMERA=1 (WITH_SHADOW_CAMERA, its media source
# freerdp-shadow-camera-source.dll), run by freerdp-shadow-service as SYSTEM on the console
# session. A record for freerdp-comp-camera-g1 (2026-11-27); run by
# .github/workflows/probe-camera-winshadow.yml; publishes nothing.
#
#   probe-camera-winshadow.ps1 -HostZip <zip> -Out <dir> [-Client <sdl-freerdp.exe>
#                              -ClientCamera "<the client's camera option>"]
#
# 1. the build: below Windows build 22000 (Server 2022) the server logs exactly
#    "camera: needs Windows 11 or Windows Server 2025 (build 22000 or later); this system is build
#    <N>, so no virtual camera" and runs without one; that line is the check there, and the end
# 2. the service starts the server; it registers "FreeRDP Camera" as SYSTEM: the row
#    "registration as the SYSTEM service" names the mode it took (all users + session, else all
#    users + until removed) and each mode's create/start HRESULT, from the server's log; an app (camera-reader.exe) finds "FreeRDP Camera (Windows Virtual Camera)"
#    and reads it through Frame Server: the still (no client), every frame the same, not black;
#    the server says when an app reads the camera and when none does any more
# 3. with -Client (the CI-only test client with a camera of its own, e.g. /dvc:rdpecam,sys:mf,
#    file:clip.mp4): on demand. The client's camera owns the virtual camera, but the server sends
#    no Start Streams before an app reads it; an app reads: Start Streams, moving frames; the app
#    stops: Stop Streams. Its PASS is the check the README's last camera sentence waits for
#    (make-readme-camera.py, ON_DEMAND_PROVEN).
#
# Every check writes "PASS|FAIL|SKIP|INFO <name>: <detail>" to $Out\checks.txt; $Out\result.txt
# and the job summary are made from it. A FAIL fails the job: the camera is our code.
param(
    [Parameter(Mandatory)] [string] $HostZip,
    [Parameter(Mandatory)] [string] $Out,
    [string] $Client = "",
    [string] $ClientCamera = ""
)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$checks = "$Out\checks.txt"
$failed = 0
function Say($verdict, $name, $detail = "") {
    $line = "$verdict $name" + $(if ($detail) { ": $detail" } else { "" })
    Write-Host $line
    Add-Content -Path $checks -Value $line -Encoding utf8
}
function Check($name, $ok, $detail = "") {
    if ($ok) { Say "PASS" $name $detail } else { Say "FAIL" $name $detail; $script:failed++ }
}
function Until($seconds, [scriptblock] $condition) {
    for ($i = 0; $i -lt $seconds * 2; $i++) { if (& $condition) { return $true }; Start-Sleep -Milliseconds 500 }
    return [bool](& $condition)
}
function Listening($p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }

$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$os = (Get-CimInstance Win32_OperatingSystem).Caption
Say "INFO" "os" "$os, build $build, $env:PROCESSOR_ARCHITECTURE"

# ---- the host and the reader
$hostDir = "$Out\host"
Expand-Archive -Path $HostZip -DestinationPath $hostDir -Force
$hostDir = (Get-ChildItem $hostDir -Directory | Select-Object -First 1).FullName
Check "package: freerdp-shadow-camera-source.dll beside the server" (Test-Path "$hostDir\freerdp-shadow-camera-source.dll")

$reader = "$Out\camera-reader.exe"
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$src = Join-Path $PSScriptRoot 'camera-reader.c'
cmd /c "`"$vcvars`" $arch >nul && cd /d $Out && cl /nologo /W3 /O2 $src mfplat.lib mf.lib mfreadwrite.lib mfuuid.lib ole32.lib" 2>&1 | Out-File "$Out\reader-build.txt" -Encoding utf8
Check "reader: built with the image's MSVC ($arch)" (Test-Path $reader)

function Read-Camera($seconds, $tag) {
    $dir = "$Out\reader-$tag"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $lines = & $reader "FreeRDP Camera" $seconds $dir 2>&1
    $code = $LASTEXITCODE
    $lines | Out-File "$dir\reader.txt" -Encoding utf8
    $r = @{ code = $code; devices = @() }
    foreach ($l in $lines) {
        if ("$l" -match '^READER device "(.*)"$') { $r.devices += $Matches[1] }
        elseif ("$l" -match '^READER (\S+) (.*)$') { $r[$Matches[1]] = $Matches[2] }
    }
    return $r
}

# ---- the service: the server as SYSTEM on the console session
$user = "kit"
$pass = "Shadow-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $user -Password (ConvertTo-SecureString $pass -AsPlainText -Force) -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name $user -Password (ConvertTo-SecureString $pass -AsPlainText -Force)
}
Add-LocalGroupMember -Group "Remote Desktop Users" -Member $user -ErrorAction SilentlyContinue
# the media source logs where a "logs" folder is beside it (Local Service may write there)
$cameraDir = "$env:ProgramData\FreeRDP\Camera"
New-Item -ItemType Directory -Force -Path "$cameraDir\logs" | Out-Null
icacls "$cameraDir\logs" /grant '*S-1-5-19:(OI)(CI)M' 2>&1 | Out-Null

$port = 4495
$logs = "$Out\service"
& "$hostDir\freerdp-shadow-service.exe" install --log $logs -- `
    /bind-address:127.0.0.1 /port:$port /log-level:INFO 2>&1 | Out-File "$Out\install.txt" -Encoding utf8
Check "service: install" ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
function ServerLog { (Get-ChildItem "$logs\shadow-*.log" -ErrorAction SilentlyContinue | Get-Content) -join "`n" }
[void](Until 60 { Listening $port })
Check "service: the server listens on 127.0.0.1:$port" (Listening $port)
$cli = Get-CimInstance Win32_Process -Filter "Name='freerdp-shadow-cli.exe'" | Select-Object -First 1
$owner = if ($cli) { $cli | Invoke-CimMethod -MethodName GetOwner } else { $null }
Say "INFO" "service: the server runs as" "$($owner.Domain)\$($owner.User), session $($cli.SessionId)"

$noApi = "camera: needs Windows 11 or Windows Server 2025 (build 22000 or later); this system is build $build, so no virtual camera"
if ($build -lt 22000) {
    [void](Until 30 { (ServerLog).Contains($noApi) })
    Check "below build 22000: the server says exactly why there is no camera" ((ServerLog).Contains($noApi)) $noApi
    Check "below build 22000: the server runs without one" (Listening $port)
} else {
    [void](Until 60 { ((ServerLog) -match 'camera: virtual camera "FreeRDP Camera", NV12') -or ((ServerLog) -match 'so no virtual camera') })
    # the registration as the SYSTEM service, its own row: which mode it took, and what each
    # mode tried answered (sink_win.c's lines: "MFCreateVirtualCamera (<mode>) failed: <hr>",
    # "starting the virtual camera (<mode>) failed: <hr>", "virtual camera ... (<mode>) registered")
    $log = ServerLog
    $tried = @()
    $used = ""
    foreach ($mode in @("all users, this session", "all users, until removed")) {
        $m = [regex]::Escape($mode)
        $create = [regex]::Match($log, "MFCreateVirtualCamera \($m\) failed: (0x[0-9A-Fa-f]+)")
        $start = [regex]::Match($log, "starting the virtual camera \($m\) failed: (0x[0-9A-Fa-f]+)")
        $ok = [regex]::Match($log, "camera: virtual camera `"FreeRDP Camera`" \($m\) registered")
        if ($create.Success) { $tried += "$mode`: create $($create.Groups[1].Value)" }
        elseif ($start.Success) { $tried += "$mode`: create 0x00000000, start $($start.Groups[1].Value)" }
        elseif ($ok.Success) { $tried += "$mode`: create 0x00000000, start 0x00000000"; $used = $mode; break }
    }
    $label = switch ($used) { "all users, this session" { "all users + session" } "all users, until removed" { "all users + until removed" } default { "none" } }
    $asSystem = ($owner -and $owner.User -eq "SYSTEM")
    Check "registration as the SYSTEM service: $label" ($asSystem -and $used) ("run as $($owner.Domain)\$($owner.User); " + $(if ($tried) { $tried -join "; " } else { "no registration line in the server's log" }))
    Check "camera: for all users, this session (the mode W0 proved)" ($used -eq "all users, this session") $(if ($used) { $used } else { "none" })

    # Camera privacy for desktop apps: Windows 11 allows it by default, Windows Server 2025
    # leaves the user's own setting unset and the reader's ActivateObject fails with
    # E_ACCESSDENIED (run 46066264731; W0 set it too). The values before, then allowed for the run.
    $consent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
    foreach ($key in @("HKLM:\$consent", "HKCU:\$consent", "HKCU:\$consent\NonPackaged")) {
        $before = (Get-ItemProperty -Path $key -Name Value -ErrorAction SilentlyContinue).Value
        New-Item -Path $key -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path $key -Name Value -Value 'Allow' -ErrorAction SilentlyContinue
        Say "INFO" "camera privacy" "$key was $(if ($before) { $before } else { '(unset)' }), Allow for the run"
    }

    # ---- the still, no client
    $r = Read-Camera 6 "still"
    Check "reader: finds FreeRDP Camera" ($r.found -eq "yes") ($r.devices -join "; ")
    Check "reader: Windows names it FreeRDP Camera (Windows Virtual Camera)" ($r.devices -contains "FreeRDP Camera (Windows Virtual Camera)") ($r.devices -join "; ")
    Check "reader: NV12 at the camera's size" ($r.type -match '^NV12 \d+x\d+$') $r.type
    Check "reader: frames through Frame Server" ([int]$r.frames -ge 60) "$($r.frames) in 6 s"
    Check "reader: the still repeats (no client)" ([int]$r.changes -eq 0) "$($r.changes) changes"
    Check "reader: the still is not black" ([double]$r.'luma-first' -gt 20) "mean luma $($r.'luma-first')"
    Check "server: an app reads the virtual camera" ((ServerLog) -match 'camera: an app reads the virtual camera')
    [void](Until 10 { (ServerLog) -match 'camera: no app reads the virtual camera' })
    Check "server: then no app reads it" ((ServerLog) -match 'camera: no app reads the virtual camera')

    # ---- on demand, with a client that has a camera
    if (-not $Client -or -not (Test-Path $Client)) {
        Say "SKIP" "on demand" "no test client with a camera (-Client): the README's last camera sentence stays out"
    } else {
        $env:WLOG_APPENDER = "FILE"
        $env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out
        $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "client.wlog"
        $env:WLOG_LEVEL = "INFO"
        $c = Start-Process -FilePath $Client -PassThru -ArgumentList @("/v:127.0.0.1:$port", "/u:$user", "/p:$pass", "/cert:ignore", "`"$ClientCamera`"")
        [void](Until 60 { (ServerLog) -match 'owns the virtual camera' })
        Check "on demand: the client's camera owns the virtual camera" ((ServerLog) -match 'owns the virtual camera')
        Start-Sleep -Seconds 5
        Check "on demand: no Start Streams before an app reads" (-not ((ServerLog) -match 'Start Streams #'))
        $r = Read-Camera 12 "client"
        Check "on demand: Start Streams once an app reads" ((ServerLog) -match 'Start Streams #') ([regex]::Match((ServerLog), '[^\n]*Start Streams #[^\n]*').Value)
        Check "on demand: the client's frames reach the app (they move)" ([int]$r.changes -ge 10) "$($r.frames) frames, $($r.changes) changes"
        [void](Until 10 { (ServerLog) -match 'Stop Streams \(no app reads the camera\)' })
        Check "on demand: Stop Streams after the app stops" ((ServerLog) -match 'Stop Streams \(no app reads the camera\)')
        $onDemand = ((Get-Content $checks) | Where-Object { $_ -match '^FAIL on demand' }).Count -eq 0
        Say $(if ($onDemand) { "PASS" } else { "FAIL" }) "ON-DEMAND" "the README's last camera sentence may ship: $onDemand"
        if ($c -and -not $c.HasExited) { Stop-Process -Id $c.Id -Force }
    }
}

# ---- stop: the service, then the camera must be gone
& "$hostDir\freerdp-shadow-service.exe" uninstall 2>&1 | Out-File "$Out\uninstall.txt" -Encoding utf8
if ($build -ge 22000) {
    # freerdp-shadow-service ends the server with TerminateProcess (shadow_service.c, stop_shadow):
    # the server never runs its own stop, and Windows takes a camera of this session's lifetime
    # away with the process. So the check is that the camera is gone; the server's own
    # "virtual camera removed" comes only from a server that stops by itself (a record here).
    $removed = [bool]((ServerLog) -match 'camera: virtual camera removed')
    Say "INFO" "stop: the server's own removal line" $(if ($removed) { "logged" } else { "not logged (the service ended the process)" })
    $r = Read-Camera 1 "after"
    Check "stop: no FreeRDP Camera once the server is gone" ($r.found -ne "yes") ($r.devices -join "; ")
}
Copy-Item -Path "$cameraDir\logs" -Destination "$Out\source-logs" -Recurse -Force -ErrorAction SilentlyContinue
# what each process that loaded the media source got: the ring, the readers' section, and the
# token of one that was refused (who it is, its groups, restricted SIDs, integrity level)
foreach ($f in (Get-ChildItem "$Out\source-logs\*.log" -ErrorAction SilentlyContinue)) {
    $who = (Select-String -Path $f.FullName -Pattern 'loaded by (.*)$' | Select-Object -First 1).Matches.Groups[1].Value
    $ring = (Select-String -Path $f.FullName -Pattern "ring (not )?open \(error \d+\), readers' section (not )?open \(error \d+\)" | Select-Object -First 1).Matches.Value
    Say "INFO" "media source in $who" $(if ($ring) { $ring } else { "(no ring line)" })
    foreach ($t in (Select-String -Path $f.FullName -Pattern 'token (user|integrity|app container|\(.*\): restricted)' | Select-Object -First 4)) {
        Say "INFO" "media source in $who" (($t.Line -replace '^\S+ pid \d+ tid \d+ ', ''))
    }
}
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddMinutes(-30); Level = 1, 2, 3 } -ErrorAction SilentlyContinue |
    Format-List TimeCreated, Id, ProviderName, Message | Out-File "$Out\application-events.txt" -Width 400

$result = @("probe-camera-winshadow: $os (build $build), $env:PROCESSOR_ARCHITECTURE: " + $(if ($failed -gt 0) { "FAIL ($failed)" } else { "PASS" }))
$result += Get-Content $checks
$result | Out-File "$Out\result.txt" -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### probe-camera-winshadow: $os (build $build)", "", "| Result | Check |", "|---|---|")
    foreach ($l in (Get-Content $checks)) { $p = $l -split ' ', 2; $md += "| $($p[0]) | $(($p[1]) -replace '\|', '\|') |" }
    $md | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
exit $(if ($failed -gt 0) { 1 } else { 0 })

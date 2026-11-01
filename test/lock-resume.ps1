# Lock and unlock the console while a shadow server in the USER's session (not the service)
# shares it. Before the fix (release-20261031.12) the capture should log an error on every pass
# while locked; after it (feature-shadow-win-service 9d668218f), one "capture paused", no
# errors, then "capture resumed" and frames again after the unlock.
# usage: lock-resume.ps1 -HostDir <dir with freerdp-shadow-cli.exe> -Client <sdl3-freerdp.exe>
#        -Out <dir> -Tag <before|after> [-Port 4495]
param([Parameter(Mandatory)][string]$HostDir, [Parameter(Mandatory)][string]$Client,
      [Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][string]$Tag, [int]$Port = 4495)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$sum = "$Out\$Tag-summary.txt"
function Say($s) { $s | Tee-Object -FilePath $sum -Append }
function Locked { [bool](Get-Process LogonUI -ErrorAction SilentlyContinue) }
function Now { (Get-Date).TimeOfDay }

$env:WLOG_LEVEL = "INFO"
$env:WLOG_APPENDER = "FILE"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "$Tag-server.wlog"
$server = Start-Process -FilePath "$HostDir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
    -ArgumentList "/bind-address:127.0.0.1", "/port:$Port", "-auth", "-sec-nla", "/gfx"
Start-Sleep 3
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "$Tag-client.wlog"
$client = Start-Process -FilePath $Client -PassThru `
    -ArgumentList "/v:127.0.0.1:$Port", "/u:test", "/p:test", "/sec:tls", "/cert:ignore", "/gfx", "/size:1024x768"
Start-Sleep 8

$tLock = Now
rundll32.exe user32.dll,LockWorkStation
Start-Sleep 2
$lockedSeen = Locked
Start-Sleep 10

# unlock: as SYSTEM, tscon gives the console back to this session without a password
$sid = (Get-Process -Id $PID).SessionId
$tUnlock = Now
schtasks /create /tn FreeRDPShadowUnlock /ru SYSTEM /sc once /st 23:59 /f /tr "tscon $sid /dest:console" | Out-Null
schtasks /run /tn FreeRDPShadowUnlock | Out-Null
Start-Sleep 4
$unlocked = -not (Locked)
schtasks /delete /tn FreeRDPShadowUnlock /f | Out-Null
Start-Sleep 10
$tEnd = Now

$serverAlive = -not $server.HasExited
$clientAlive = -not $client.HasExited
Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
Start-Sleep 1

# split the server log by time: [HH:MM:SS:mmm] at the start of each line
$phase = @{ before = 0; locked = 0; after = 0 }
$errs = @{ before = 0; locked = 0; after = 0 }
foreach ($l in Get-Content "$Out\$Tag-server.wlog" -ErrorAction SilentlyContinue) {
    if ($l -notmatch '^\[(\d+):(\d+):(\d+):(\d+)\]') { continue }
    $t = New-TimeSpan -Hours $matches[1] -Minutes $matches[2] -Seconds $matches[3] -Milliseconds $matches[4]
    $p = if ($t -lt $tLock) { "before" } elseif ($t -lt $tUnlock) { "locked" } else { "after" }
    if ($l -match 'SurfaceCopy') { $phase[$p]++ }
    if ($l -match '\[ERROR\]\[com\.freerdp\.server\.shadow\.win\]') { $errs[$p]++ }
}
$log = Get-Content "$Out\$Tag-server.wlog" -Raw -ErrorAction SilentlyContinue
$paused = ([regex]::Matches("$log", 'capture paused')).Count
$resumed = ([regex]::Matches("$log", 'capture resumed')).Count

Say "== $Tag ($HostDir)"
Say "lock seen (LogonUI running): $lockedSeen; unlock by tscon worked: $unlocked"
Say "server alive at the end: $serverAlive; client session alive at the end: $clientAlive"
Say ("frames (SurfaceCopy) before lock: {0}, while locked: {1}, after unlock: {2}" -f $phase.before, $phase.locked, $phase.after)
Say ("shadow.win ERROR lines before: {0}, while locked: {1}, after: {2}" -f $errs.before, $errs.locked, $errs.after)
Say "'capture paused' lines: $paused; 'capture resumed' lines: $resumed"
$ok = $serverAlive -and $clientAlive -and ($phase.after -gt 0)
Say ("VERDICT {0}: {1}" -f $Tag, $(if (-not $lockedSeen) { "inconclusive (no lock)" } elseif (-not $unlocked) { "inconclusive (no unlock)" } elseif ($ok) { "capture back after unlock" } else { "capture NOT back after unlock" }))

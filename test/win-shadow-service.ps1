# Phase 2 of a Windows host (branch win-shadow): freerdp-shadow-service runs
# the shadow server (DXGI capture) as SYSTEM on the console session:
#
#   win-shadow-service.ps1 <unpacked ...-shadow folder, built with SHADOW=dxgi> <out dir>
#
# Installed with --allow-sas, on 127.0.0.1 only, NLA against a local Windows
# user made for the test. Checks: the service runs; the shadow server runs as
# SYSTEM on the console session (this job's, on a GitHub runner); the right
# password logs in and a wrong one does not; an AV1 session holds. Then, with
# a session open: Ctrl+Alt+Del typed into the client's window (the server
# asks the service, which calls SendSAS), and the lock screen (LockWorkStation):
# each time the server must follow the input desktop to Winlogon and the
# session must hold. Locking is last: this job's desktop stays locked.
param([string]$Dir, [string]$Out)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Dir = (Resolve-Path $Dir).Path
$Out = (Resolve-Path $Out).Path
$logs = "$Out\service"
$port = 4490
$user = "kit"
$pass = "Shadow-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$fails = 0
function Check($name, $ok, $detail = "") {
    $word = if ($ok) { "PASS" } else { "FAIL" }
    if (-not $ok) { $script:fails++ }
    "$word  $name$(if ($detail) { "  ($detail)" })" | Tee-Object -FilePath "$Out\checks.txt" -Append
}
function Shot($name) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
        $bmp.Save("$Out\$name.png")
    } catch { "screenshot ${name}: $($_.Exception.Message)" | Out-File -Append "$Out\notes.txt" }
}
# the shadow server's WLog files (one per start) as one text
function ServerLog { (Get-ChildItem "$logs\shadow-*.log" -ErrorAction SilentlyContinue | Get-Content) -join "`n" }

$console = (Get-Process -Id $PID).SessionId
"session of this job: $console" | Tee-Object "$Out\where.txt"
(qwinsta 2>&1) | Out-File -Append "$Out\where.txt"
& net user $user $pass /add | Out-Null
Check "a local Windows user for the test" ($LASTEXITCODE -eq 0) "net user: $LASTEXITCODE"

& "$Dir\freerdp-shadow-service.exe" install --log $logs --allow-sas -- `
    /bind-address:127.0.0.1 /port:$port /gfx-av1 /log-level:DEBUG 2>&1 | Tee-Object "$Out\install.txt"
Check "install" ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
$svc = Get-Service FreeRDPShadow -ErrorAction SilentlyContinue
Check "the service runs" ($svc -and $svc.Status -eq "Running") "$($svc.Status)"

$up = $false
for ($i = 0; $i -lt 30 -and -not $up; $i++) {
    Start-Sleep -Seconds 1
    $up = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}
Check "the shadow server listens on 127.0.0.1:$port" $up
$cli = Get-CimInstance Win32_Process -Filter "Name='freerdp-shadow-cli.exe'" | Select-Object -First 1
$owner = if ($cli) { $cli | Invoke-CimMethod -MethodName GetOwner } else { $null }
Check "it runs on the console session ($console)" ($cli -and $cli.SessionId -eq $console) "session $($cli.SessionId)"
Check "it runs as SYSTEM" ($owner -and $owner.User -eq "SYSTEM") "$($owner.Domain)\$($owner.User)"

$env:WLOG_LEVEL = "DEBUG"
$env:WLOG_APPENDER = "FILE"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out
function Client([string[]]$More, [string]$Log, [int]$Seconds) {
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "$Log.wlog"
    $p = Start-Process -FilePath "$Dir\sdl-freerdp.exe" -PassThru `
        -ArgumentList (@("/v:127.0.0.1:$port", "/u:$user", "/cert:ignore") + $More)
    if ($Seconds) { $p.WaitForExit($Seconds * 1000) | Out-Null }
    return $p
}
if ($up) {
    $good = Client @("/p:$pass", "/auth-only") "auth-good" 30
    Check "the right password logs in (/auth-only)" ($good.HasExited -and $good.ExitCode -eq 0) "exit $($good.ExitCode)"
    $bad = Client @("/p:wrong-$pass", "/auth-only") "auth-bad" 30
    Check "a wrong password does not" ($bad.HasExited -and $bad.ExitCode -ne 0) "exit $($bad.ExitCode)"

    $session = Client @("/p:$pass", "/gfx:AV1", "/size:1280x720") "session" 0
    Start-Sleep -Seconds 15
    Shot "desktop"
    Check "an AV1 session holds 15 s" (-not $session.HasExited) "$(if ($session.HasExited) { "exit $($session.ExitCode)" } else { 'running' })"

    # Ctrl+Alt+Del typed into the client's window: from there it is three
    # ordinary keys, which the client sends to the server
    Add-Type -Namespace Kit -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
    $session.Refresh()
    if ($session.MainWindowHandle -ne [IntPtr]::Zero) {
        [Kit.Keys]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # Alt, so the focus may move
        [Kit.Keys]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        [void][Kit.Keys]::SetForegroundWindow($session.MainWindowHandle)
        Start-Sleep -Milliseconds 500
        # Ctrl, Alt, Delete (extended) down, then up
        [Kit.Keys]::keybd_event(0x11, 0x1D, 0, [UIntPtr]::Zero)
        [Kit.Keys]::keybd_event(0x12, 0x38, 0, [UIntPtr]::Zero)
        [Kit.Keys]::keybd_event(0x2E, 0x53, 1, [UIntPtr]::Zero)
        [Kit.Keys]::keybd_event(0x2E, 0x53, 3, [UIntPtr]::Zero)
        [Kit.Keys]::keybd_event(0x12, 0x38, 2, [UIntPtr]::Zero)
        [Kit.Keys]::keybd_event(0x11, 0x1D, 2, [UIntPtr]::Zero)
        Start-Sleep -Seconds 8
        $svcLog = Get-Content "$logs\service.log" -Raw -ErrorAction SilentlyContinue
        Check "Ctrl+Alt+Del: the server asked, the service sent the sequence" ($svcLog -match "secure attention sequence sent") ""
        Check "Ctrl+Alt+Del: the server followed the input desktop to Winlogon" ((ServerLog) -match "follows the input desktop from \w+ to Winlogon")
        Check "the session holds after Ctrl+Alt+Del" (-not $session.HasExited)
        Shot "after-sas"
        # leave the Ctrl+Alt+Del screen
        [Kit.Keys]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)
        [Kit.Keys]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
        Start-Sleep -Seconds 5
    } else {
        Check "Ctrl+Alt+Del: the client has a window to type into" $false "no main window"
    }

    # the lock screen, last
    $before = ([regex]::Matches((ServerLog), "to Winlogon")).Count
    & rundll32.exe user32.dll,LockWorkStation
    Start-Sleep -Seconds 10
    $after = ([regex]::Matches((ServerLog), "to Winlogon")).Count
    Check "locked: the server followed the input desktop to Winlogon" ($after -gt $before) "$before -> $after"
    Check "the session holds on the lock screen" (-not $session.HasExited) "$(if ($session.HasExited) { "exit $($session.ExitCode)" } else { 'running' })"
    Shot "locked"
    if (-not $session.HasExited) { Stop-Process -Id $session.Id -Force }
}

& "$Dir\freerdp-shadow-service.exe" uninstall 2>&1 | Tee-Object -Append "$Out\install.txt"
& net user $user /delete | Out-Null
Copy-Item "$logs\*" $Out -ErrorAction SilentlyContinue
"== service.log"; Get-Content "$logs\service.log" -ErrorAction SilentlyContinue
"== the server: desktop, DXGI, codec lines (first 60)"
(ServerLog) -split "`n" | Select-String -Pattern "desktop|DXGI|Dxgi|AV1|codec|CapsConfirm|ERROR" |
    Where-Object { $_.Line -notmatch "SurfaceCopy" } | Select-Object -First 60 | ForEach-Object { $_.Line }
Get-Content "$Out\checks.txt"
if ($fails) { exit 1 }

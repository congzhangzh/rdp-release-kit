# The Windows host on a Windows runner (Windows Server 2025; GitHub runs the
# job on the console session): FreeRDP's shadow server from the kit's host
# package, reached by the kit's own Windows client and by the web client:
#
#   windows-host.ps1 <unpacked freerdp-host-* folder> <unpacked sdl3-freerdp-*-windows-x86_64 folder>
#                    <web client folder> <out dir>
#
# 1. The server started by hand, as the user: a SAM-file login (WinPR's NTLM,
#    WINPR_NATIVE_SSPI=0), and a Unix socket (/ipc-socket) reached through a
#    small TCP relay here, as the client cannot dial one.
# 2. freerdp-shadow-service: it runs the server as SYSTEM on the console
#    session; Windows-account logins (Windows' own SSPI); the web client logs
#    in through websockify and decodes AV1; the native client's frames are
#    AV1; Ctrl+Alt+Del typed into the client reaches the service (SendSAS) and
#    the server follows to the secure desktop; so it does when the screen is
#    locked (last: this job's desktop stays locked).
# Everything listens on 127.0.0.1 only. A local Windows user is made for the
# test (the machine is thrown away afterwards). It fails when a check fails.
param([string]$HostDir, [string]$ClientDir, [string]$WebDir, [string]$Out)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$HostDir = (Resolve-Path $HostDir).Path
$ClientDir = (Resolve-Path $ClientDir).Path
$WebDir = (Resolve-Path $WebDir).Path
$Out = (Resolve-Path $Out).Path
$KitTest = $PSScriptRoot
$user = "kit"
$pass = "Shadow-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$port = 4489
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
function Listening($p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }
function Stop($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 2
}

$console = (Get-Process -Id $PID).SessionId
"session of this job: $console" | Tee-Object "$Out\where.txt"
(qwinsta 2>&1) | Out-File -Append "$Out\where.txt"
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version | Format-Table | Out-File -Append "$Out\where.txt"
# New-LocalUser: net user asks Y/N on stdin for a password over 14 characters
try {
    New-LocalUser -Name $user -Password (ConvertTo-SecureString $pass -AsPlainText -Force) -PasswordNeverExpires | Out-Null
    Check "a local Windows user for the test" $true
} catch { Check "a local Windows user for the test" $false $_.Exception.Message }

# every FreeRDP process logs to a file of its own, at debug level
$env:WLOG_LEVEL = "DEBUG"
$env:WLOG_APPENDER = "FILE"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out
function Client([string[]]$More, [string]$Log, [int]$Seconds, [switch]$Window) {
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "$Log.wlog"
    $spec = @{ FilePath = "$ClientDir\sdl-freerdp.exe"; PassThru = $true
               ArgumentList = (@("/v:127.0.0.1:$port", "/u:$user", "/cert:ignore") + $More) }
    if (-not $Window) { $spec.NoNewWindow = $true }
    $p = Start-Process @spec
    if ($Seconds) { $p.WaitForExit($Seconds * 1000) | Out-Null }
    return $p
}
# the client's own word: PowerShell has reported 1 for a client that logged SUCCESS [0]
function Logins([string]$Way) {
    $good = Client @("/p:$pass", "/auth-only") "$Way-auth-good" 30
    $said = Select-String -Path "$Out\$Way-auth-good.wlog" -Pattern "Authentication only, exit status (\w+)" -ErrorAction SilentlyContinue | Select-Object -Last 1
    Check "${Way}: the right password logs in" ($said -and $said.Matches[0].Groups[1].Value -eq "SUCCESS") "client: $(if ($said) { $said.Matches[0].Groups[1].Value } else { 'no word' })"
    $bad = Client @("/p:wrong-$pass", "/auth-only") "$Way-auth-bad" 30
    Check "${Way}: a wrong password does not" ($bad.HasExited -and $bad.ExitCode -ne 0) "exit $($bad.ExitCode)"
}
# the frames of a session by codec, from the client's log
function Codecs([string]$Log) {
    Select-String -Path "$Out\$Log.wlog" -Pattern "Got GFX (RDPGFX_CODECID_\w+)" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }
}

# ---- 1. by hand, as the user
$sam = "$Out\SAM"
Set-Content -Path $sam -Value (& "$HostDir\winpr-hash.exe" -u $user -p $pass -f sam) -Encoding ascii
$env:WINPR_NATIVE_SSPI = "0"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "server-sam.wlog"
$server = Start-Process -FilePath "$HostDir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
    -ArgumentList "/bind-address:127.0.0.1", "/port:$port", "/sam-file:$sam", "/gfx-av1"
for ($i = 0; $i -lt 30 -and -not (Listening $port) -and -not $server.HasExited; $i++) { Start-Sleep -Seconds 1 }
Check "by hand: the server listens on 127.0.0.1:$port" (Listening $port)
Logins "sam-file"
Stop $server
Remove-Item Env:\WINPR_NATIVE_SSPI

$sock = "$env:TEMP\shadow-kit.sock"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "server-ipc.wlog"
$server = Start-Process -FilePath "$HostDir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
    -ArgumentList "/ipc-socket:$sock", "/gfx-av1"
for ($i = 0; $i -lt 20 -and -not (Test-Path $sock) -and -not $server.HasExited; $i++) { Start-Sleep -Seconds 1 }
Check "ipc: the server made its socket file" (Test-Path $sock)
if (Test-Path $sock) {
    $relay = Start-ThreadJob -ArgumentList $sock -ScriptBlock {
        param($path)
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 4491)
        $l.Start()
        for ($i = 0; $i -lt 3; $i++) {
            $tcp = $l.AcceptTcpClient()
            $u = [System.Net.Sockets.Socket]::new([System.Net.Sockets.AddressFamily]::Unix,
                [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Unspecified)
            $u.Connect([System.Net.Sockets.UnixDomainSocketEndPoint]::new($path))
            $us = [System.Net.Sockets.NetworkStream]::new($u, $true)
            $ts = $tcp.GetStream()
            [void][System.Threading.Tasks.Task]::WaitAny(@($ts.CopyToAsync($us), $us.CopyToAsync($ts)))
            $tcp.Close(); $u.Close()
        }
        $l.Stop()
    }
    Start-Sleep -Seconds 2
    $port = 4491
    Logins "ipc"
    $s = Client @("/p:$pass", "/gfx:AV1:on", "/size:1280x720") "ipc-session" 10
    Check "ipc: a session through the socket holds 10 s" (-not $s.HasExited)
    Stop $s
    $port = 4489
    Remove-Job $relay -Force -ErrorAction SilentlyContinue
}
Stop $server

# ---- AV2 (scratch builds only): the host package then carries a client built
# with it too; the server started by hand with /gfx-av2, the client asking for AV2
if (Test-Path "$HostDir\sdl-freerdp.exe") {
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "server-av2.wlog"
    $server = Start-Process -FilePath "$HostDir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
        -ArgumentList "/bind-address:127.0.0.1", "/port:4492", "/gfx-av2"
    for ($i = 0; $i -lt 30 -and -not (Listening 4492) -and -not $server.HasExited; $i++) { Start-Sleep -Seconds 1 }
    Check "av2: the server listens on 127.0.0.1:4492" (Listening 4492)
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "av2-session.wlog"
    $c = Start-Process -FilePath "$HostDir\sdl-freerdp.exe" -PassThru `
        -ArgumentList "/v:127.0.0.1:4492", "/u:$user", "/p:$pass", "/cert:ignore", "/gfx:AV2:on", "/size:1280x720"
    Start-Sleep -Seconds 20
    Shot "av2"
    Check "av2: the session holds 20 s" (-not $c.HasExited)
    $codecs = Codecs "av2-session"
    Check "av2: the frames came in AV2" (($codecs -join " ") -match "RDPGFX_CODECID_AV2") ($codecs -join ", ")
    Stop $c
    Stop $server
}

# ---- 2. the service
$port = 4490
$logs = "$Out\service"
& "$HostDir\freerdp-shadow-service.exe" install --log $logs --allow-sas -- `
    /bind-address:127.0.0.1 /port:$port /gfx-av1 /log-level:DEBUG 2>&1 | Tee-Object "$Out\install.txt"
Check "service: install" ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
$svc = Get-Service FreeRDPShadow -ErrorAction SilentlyContinue
Check "service: running" ($svc -and $svc.Status -eq "Running") "$($svc.Status)"
for ($i = 0; $i -lt 30 -and -not (Listening $port); $i++) { Start-Sleep -Seconds 1 }
Check "service: the server listens on 127.0.0.1:$port" (Listening $port)
$cli = Get-CimInstance Win32_Process -Filter "Name='freerdp-shadow-cli.exe'" | Select-Object -First 1
$owner = if ($cli) { $cli | Invoke-CimMethod -MethodName GetOwner } else { $null }
Check "service: the server runs on the console session ($console)" ($cli -and $cli.SessionId -eq $console) "session $($cli.SessionId)"
Check "service: the server runs as SYSTEM" ($owner -and $owner.User -eq "SYSTEM") "$($owner.Domain)\$($owner.User)"
function ServerLog { (Get-ChildItem "$logs\shadow-*.log" -ErrorAction SilentlyContinue | Get-Content) -join "`n" }
Logins "windows-account"

# this job's console desktop is what the server shares (and what the demo
# shows): every window down first
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep -Seconds 2

# the web client: the page from a plain static server (as GitHub Pages, no
# COOP/COEP), websockify as its gateway, headless Chrome as the user
$web = "$Out\web"
New-Item -ItemType Directory -Force -Path $web | Out-Null
$http = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$web\http.log" -RedirectStandardError "$web\http.err" `
    -ArgumentList "-m", "http.server", "8080", "--bind", "127.0.0.1", "--directory", $WebDir
& python -m pip install --quiet websockify 2>&1 | Out-File "$web\pip.log"
$gw = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$web\websockify.log" -RedirectStandardError "$web\websockify.err" `
    -ArgumentList "-m", "websockify", "127.0.0.1:3390", "127.0.0.1:$port"
for ($i = 0; $i -lt 20 -and -not ((Listening 8080) -and (Listening 3390)); $i++) { Start-Sleep -Seconds 1 }
Check "web: the page and websockify are up" ((Listening 8080) -and (Listening 3390))
$env:CHROME = (Get-Command chrome.exe -ErrorAction SilentlyContinue).Source
if (-not $env:CHROME) { $env:CHROME = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe" }
& node "$KitTest\wasm-session.mjs" "http://127.0.0.1:8080/index.html" "127.0.0.1:3390" $user $pass $web 2>&1 |
    Tee-Object "$web\driver.log"
$driver = Get-Content "$web\driver.log" -Raw -ErrorAction SilentlyContinue
$pageLog = Get-Content "$web\page.log" -Raw -ErrorAction SilentlyContinue
$av1 = if ($driver -match "av1 decoders configured: (.+)") { $Matches[1].Trim() } else { "no word" }
Check "web: the page started the client as $user" ($pageLog -match " /u:$user ")
Check "web: the page decodes AV1 (a WebCodecs decoder configured)" ($av1 -match "profile \d") $av1

# a demo video of the same: the web client on this Windows host
# (wasm-demo.mjs, SERVER=windows), finished as the site's other videos are
# (test/record-demos.sh: 720p, H.264 CRF 28, AAC 96 kbit/s, a poster from 70 %)
$demo = "$Out\demo"
New-Item -ItemType Directory -Force -Path $demo | Out-Null
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    & choco install ffmpeg -y --no-progress 2>&1 | Out-File "$demo\choco.log"
}
$env:SERVER = "windows"
& node "$KitTest\wasm-demo.mjs" "http://127.0.0.1:8080/index.html" "127.0.0.1:3390" $user $pass $demo "$demo\raw.mp4" 2>&1 |
    Tee-Object "$demo\driver.log"
Remove-Item Env:\SERVER
if (Test-Path "$demo\raw.mp4") {
    $len = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 "$demo\raw.mp4")
    & ffmpeg -v error -y -i "$demo\raw.mp4" -vf "scale=1280:720:flags=lanczos,format=yuv420p" -c:v libx264 -crf 28 `
        -preset slow -c:a aac -b:a 96k -movflags +faststart "$Out\windows-host.mp4"
    & ffmpeg -v error -y -ss ("{0:F1}" -f ($len * 0.7)) -i "$demo\raw.mp4" -frames:v 1 `
        -vf "scale=1280:720:flags=lanczos" -q:v 4 "$Out\windows-host.jpg"
}
# the demo leaves Notepad open on this same desktop: close it, and any menu,
# before the native client needs the focus
Stop-Process -Name notepad -Force -ErrorAction SilentlyContinue
Add-Type -Namespace Kit -Name Esc -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);'
[Kit.Esc]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero); [Kit.Esc]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
(New-Object -ComObject Shell.Application).MinimizeAll()
Check "demo: a video of the web client on this host" ((Test-Path "$Out\windows-host.mp4") -and (Test-Path "$Out\windows-host.jpg")) `
    "$(if (Test-Path "$Out\windows-host.mp4") { '{0:N1} MB' -f ((Get-Item "$Out\windows-host.mp4").Length / 1MB) })"
Stop $gw; Stop $http

# the native client: an AV1 session, Ctrl+Alt+Del, the lock screen
$session = Client @("/p:$pass", "/gfx:AV1:on", "/size:1280x720") "session" 0 -Window
Start-Sleep -Seconds 15
Shot "desktop"
Check "native: an AV1 session holds 15 s" (-not $session.HasExited)
$codecs = Codecs "session"
Check "native: the frames came in AV1" (($codecs -join " ") -match "RDPGFX_CODECID_AV1") ($codecs -join ", ")

# Ctrl+Alt+Del typed into the client's window: three ordinary keys there,
# which the client sends to the server
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
    [Kit.Keys]::keybd_event(0x11, 0x1D, 0, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x12, 0x38, 0, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x2E, 0x53, 1, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x2E, 0x53, 3, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x12, 0x38, 2, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x11, 0x1D, 2, [UIntPtr]::Zero)
    Start-Sleep -Seconds 8
    $svcLog = Get-Content "$logs\service.log" -Raw -ErrorAction SilentlyContinue
    Check "Ctrl+Alt+Del: the service sent the secure attention sequence" ($svcLog -match "secure attention sequence sent")
    Check "Ctrl+Alt+Del: the server followed to Winlogon" ((ServerLog) -match "follows the input desktop from \w+ to Winlogon")
    Check "Ctrl+Alt+Del: the session holds" (-not $session.HasExited)
    Shot "after-sas"
    [Kit.Keys]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)   # Esc: leave the Ctrl+Alt+Del screen
    [Kit.Keys]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
    Start-Sleep -Seconds 5
} else {
    Check "Ctrl+Alt+Del: the client has a window to type into" $false
}

$before = ([regex]::Matches((ServerLog), "to Winlogon")).Count
& rundll32.exe user32.dll,LockWorkStation
Start-Sleep -Seconds 10
Check "locked: the server followed to Winlogon" (([regex]::Matches((ServerLog), "to Winlogon")).Count -gt $before)
Check "locked: the session holds" (-not $session.HasExited)
Stop $session

& "$HostDir\freerdp-shadow-service.exe" uninstall 2>&1 | Tee-Object -Append "$Out\install.txt"
Remove-LocalUser -Name $user -ErrorAction SilentlyContinue
Get-Content "$Out\checks.txt"
if ($fails) { exit 1 }

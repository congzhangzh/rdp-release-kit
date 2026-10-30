# Phase 0 of a Windows host (branch win-shadow): FreeRDP's shadow server on
# this Windows machine, reached by the client from the same build, on
# 127.0.0.1 only:
#
#   win-shadow.ps1 <unpacked sdl3-freerdp-*-windows-x86_64-shadow folder> <out dir>
#
# NLA, two ways (WinPR on Windows uses Windows' own SSPI unless
# WINPR_NATIVE_SSPI=0): against a Windows account, a local user made here for
# the test, and against the shadow server's own SAM file, written with
# winpr-hash. Each time the right password must log in and a wrong one must
# not (/auth-only). Then a session with AV1 asked for on both sides
# (/gfx-av1 on the server, /gfx:AV1 on the client) runs for a while: a
# screenshot of the desktop, both logs at debug level, and what they say
# about the codec. It reports; it fails only when a check fails.
param([string]$Dir, [string]$Out)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Dir = (Resolve-Path $Dir).Path
$Out = (Resolve-Path $Out).Path
$port = 4489
$user = "kit"
$pass = "Shadow-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$fails = 0
function Check($name, $ok, $detail = "") {
    $word = if ($ok) { "PASS" } else { "FAIL" }
    if (-not $ok) { $script:fails++ }
    "$word  $name$(if ($detail) { "  ($detail)" })" | Tee-Object -FilePath "$Out\checks.txt" -Append
}

# where this runs: the session, its desktop, the display (the shadow server
# shows the console session's desktop)
"session of this job: $((Get-Process -Id $PID).SessionId)" | Tee-Object "$Out\where.txt"
(qwinsta 2>&1) | Out-File -Append "$Out\where.txt"
Get-CimInstance Win32_VideoController | Select-Object Name, CurrentHorizontalResolution, CurrentVerticalResolution |
    Format-Table | Out-File -Append "$Out\where.txt"
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version | Format-Table | Out-File -Append "$Out\where.txt"
Get-Content "$Out\where.txt"

# a Windows account for the test (this machine is thrown away afterwards)
# New-LocalUser: net user asks Y/N on stdin for a password over 14 characters
try {
    New-LocalUser -Name $user -Password (ConvertTo-SecureString $pass -AsPlainText -Force) -PasswordNeverExpires | Out-Null
    Check "a local Windows user for the test" $true
} catch { Check "a local Windows user for the test" $false $_.Exception.Message }
# the SAM file: user, domain (none), the NT hash
$sam = "$Out\SAM"
$line = & "$Dir\winpr-hash.exe" -u $user -p $pass -f sam
Set-Content -Path $sam -Value $line -Encoding ascii
Check "winpr-hash wrote a SAM line" ($line -match "^${user}:") $line.Split(":")[0]

# WLog writes to a file per process (a GUI client's stdout may go nowhere)
$env:WLOG_LEVEL = "DEBUG"
$env:WLOG_APPENDER = "FILE"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out

function Server([string]$Log, [string[]]$More) {
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "$Log.wlog"
    $s = Start-Process -FilePath "$Dir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
        -ArgumentList (@("/bind-address:127.0.0.1", "/port:$port", "/gfx-av1") + $More) `
        -RedirectStandardOutput "$Out\$Log.log" -RedirectStandardError "$Out\$Log.err"
    $up = $false
    for ($i = 0; $i -lt 30 -and -not $up; $i++) {
        Start-Sleep -Seconds 1
        $up = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
        if ($s.HasExited) { break }
    }
    Check "${Log}: the shadow server listens on 127.0.0.1:$port" $up "exit code $(if ($s.HasExited) { $s.ExitCode } else { 'running' })"
    return $s
}
function Stop($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 2
}
function Client([string[]]$More, [string]$Log, [int]$Seconds) {
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "$Log.wlog"
    $p = Start-Process -FilePath "$Dir\sdl-freerdp.exe" -PassThru -NoNewWindow `
        -ArgumentList (@("/v:127.0.0.1:$port", "/u:$user", "/cert:ignore") + $More) `
        -RedirectStandardOutput "$Out\$Log.log" -RedirectStandardError "$Out\$Log.err"
    $p.WaitForExit($Seconds * 1000) | Out-Null
    return $p
}
function Logins([string]$Way) {
    $good = Client @("/p:$pass", "/auth-only") "$Way-auth-good" 30
    # the client's own word: PowerShell has reported 1 for a client that logged SUCCESS [0]
    $said = Select-String -Path "$Out\$Way-auth-good.wlog" -Pattern "Authentication only, exit status (\w+)" | Select-Object -Last 1
    Check "${Way}: the right password logs in (/auth-only)" ($said -and $said.Matches[0].Groups[1].Value -eq "SUCCESS") "client: $(if ($said) { $said.Matches[0].Groups[1].Value } else { 'no word' }), exit $($good.ExitCode)"
    $bad = Client @("/p:wrong-$pass", "/auth-only") "$Way-auth-bad" 30
    Check "${Way}: a wrong password does not" ($bad.HasExited -and $bad.ExitCode -ne 0) "exit $($bad.ExitCode)"
}

# 1. Windows' own SSPI: the Windows account
$server = Server "server-windows" @()
if (-not $server.HasExited) { Logins "windows-account" }
Stop $server

# 2. WinPR's NTLM: the SAM file
$env:WINPR_NATIVE_SSPI = "0"
$server = Server "server-sam" @("/sam-file:$sam")
if (-not $server.HasExited) { Logins "sam-file" }
Stop $server
Remove-Item Env:\WINPR_NATIVE_SSPI

# 3. a session with AV1, with the Windows account: the client's window shows
# the shadowed desktop, so a screenshot of the desktop shows both
$server = Server "server" @()
if (-not $server.HasExited) {
    $session = Client @("/p:$pass", "/gfx:AV1:on", "/size:1280x720") "session" 25
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save("$Out\desktop.png")
    Check "the session is still up after 25 s" (-not $session.HasExited) "exit $(if ($session.HasExited) { $session.ExitCode } else { 'running' })"
    Stop $session
}
Stop $server

# 4. a Unix socket instead of TCP (/ipc-socket; Windows 10 1803+ AF_UNIX): the
# client cannot dial one, so a relay here takes TCP 127.0.0.1:4491 to it
$sockPath = "$env:TEMP\shadow-kit.sock"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "server-ipc.wlog"
$ipc = Start-Process -FilePath "$Dir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
    -ArgumentList "/ipc-socket:$sockPath", "/gfx-av1" `
    -RedirectStandardOutput "$Out\server-ipc.log" -RedirectStandardError "$Out\server-ipc.err"
for ($i = 0; $i -lt 20 -and -not (Test-Path $sockPath) -and -not $ipc.HasExited; $i++) { Start-Sleep -Seconds 1 }
Check "ipc: the shadow server made its socket file" (Test-Path $sockPath) "exit code $(if ($ipc.HasExited) { $ipc.ExitCode } else { 'running' })"
if (Test-Path $sockPath) {
    $relay = Start-ThreadJob -ArgumentList $sockPath -ScriptBlock {
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
    $tcpPort = $port
    $port = 4491
    Logins "ipc"
    $s2 = Client @("/p:$pass", "/gfx:AV1:on", "/size:1280x720") "ipc-session" 10
    Check "ipc: a session through the socket holds 10 s" (-not $s2.HasExited) "$(if ($s2.HasExited) { "exit $($s2.ExitCode)" } else { 'running' })"
    Stop $s2
    $port = $tcpPort
    Remove-Job $relay -Force -ErrorAction SilentlyContinue
}
Check "ipc: the server says it listens on the socket" ((Get-Content "$Out\server-ipc.wlog" -Raw -ErrorAction SilentlyContinue) -match "Listening on socket")
Stop $ipc
Remove-LocalUser -Name $user -ErrorAction SilentlyContinue

# what the logs say about the codec and the capture (a report, not a check)
$pattern = "AV1|av1|aom|codec|CapsConfirm|CapsAdvertise|WDS|DXGI|RDPSRAPI|desktop|ERROR|fail"
foreach ($f in "server.wlog", "session.wlog") {
    if (Test-Path "$Out\$f") {
        "== ${f}: $((Get-Content "$Out\$f").Count) lines; matching lines (first 60):"
        Select-String -Path "$Out\$f" -Pattern $pattern | Where-Object { $_.Line -notmatch "SurfaceCopy" } |
            Select-Object -First 60 | ForEach-Object { $_.Line }
    }
}
# the frames by codec, from the client's log: AV1 asked for, AV1 sent?
$codecs = Select-String -Path "$Out\session.wlog" -Pattern "Got GFX (RDPGFX_CODECID_\w+)" -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }
Check "the frames came in AV1" (($codecs -join " ") -match "RDPGFX_CODECID_AV1") ($codecs -join ", ")
Get-Content "$Out\checks.txt"
if ($fails) { exit 1 }

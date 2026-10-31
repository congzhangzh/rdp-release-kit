# The Windows host on a Windows runner (Windows Server 2025; GitHub runs the
# job on the console session): FreeRDP's shadow server from the kit's host
# package, reached by the kit's own Windows client and by the web client:
#
#   windows-host.ps1 <unpacked freerdp-host-* folder> <unpacked sdl3-freerdp-*-windows-x86_64 folder>
#                    <web client folder> <out dir> [<demo media folder> [<client zip>]]
#
# The demo media folder is test/demo-assets.sh's (Big Buck Bunny, the WebGL
# Aquarium): with it, the demo video also plays them, in Firefox here. With the
# client's zip too, a second video: freerdp-tk from it, to Windows' own Remote
# Desktop on this PC (test/client-demo/windows.ps1).
#
# 1. The server started by hand, as the user: a SAM-file login (WinPR's NTLM,
#    WINPR_NATIVE_SSPI=0), a Unix socket (/ipc-socket) reached through a
#    small TCP relay here, as the client cannot dial one, and an AV2 session
#    (/gfx-av2, the client's /gfx:AV2).
# 2. freerdp-shadow-service: it runs the server as SYSTEM on the console
#    session; Windows-account logins (Windows' own SSPI); the web client logs
#    in through websockify and decodes AV1; the native client's frames are
#    AV1; Ctrl+Alt+Del typed into the client reaches the service (SendSAS) and
#    the server follows to the secure desktop; so it does when the screen is
#    locked (last: this job's desktop stays locked).
# Everything listens on 127.0.0.1 only. A local Windows user is made for the
# test (the machine is thrown away afterwards). It fails when a check fails.
param([string]$HostDir, [string]$ClientDir, [string]$WebDir, [string]$Out, [string]$Media = "", [string]$ClientZip = "")
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
# memory: free and the biggest processes, at a few points (kit run 41192237422 ran out of
# memory during the demo: ffmpeg "Cannot allocate memory", the page starved)
function Memory($when) {
    $os = Get-CimInstance Win32_OperatingSystem
    "== memory $when $(Get-Date -Format HH:mm:ss): free {0:N1} of {1:N1} GB" -f ($os.FreePhysicalMemory / 1MB), ($os.TotalVisibleMemorySize / 1MB) |
        Out-File -Append "$Out\memory.txt"
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 Name, Id, @{n = "MB"; e = { [int]($_.WorkingSet64 / 1MB) } } |
        Format-Table -AutoSize | Out-File -Append "$Out\memory.txt"
}
function Listening($p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }
function Stop($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 2
}

# The screen: the runner's is 1024 x 768, half of what the demo's browser shows (the
# shadow server shares the screen as it is; it cannot take the client's size as xrdp
# does), so 1600 x 900 first, before any server reads it. And the dialog the runner
# shows at login ("Windows created a temporary paging file ..."): closed, it would sit
# in the middle of every picture.
Add-Type -Namespace Kit -Name Screen -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
}
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern System.IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] static extern bool PostMessage(System.IntPtr w, uint msg, System.IntPtr wp, System.IntPtr lp);
public static string Size(int w, int h) {
    DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) return "the current mode is unknown";
    string was = dm.dmPelsWidth + " x " + dm.dmPelsHeight;
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x80000 | 0x100000;   // DM_PELSWIDTH | DM_PELSHEIGHT
    return was + " -> " + w + " x " + h + ": " + ChangeDisplaySettings(ref dm, 0);   // 0: DISP_CHANGE_SUCCESSFUL
}
public static int Close(string title) {   // WM_CLOSE to every top-level window of that title
    int n = 0;
    for (System.IntPtr h; n < 10 && (h = FindWindow(null, title)) != System.IntPtr.Zero; n++) {
        PostMessage(h, 0x10, System.IntPtr.Zero, System.IntPtr.Zero); System.Threading.Thread.Sleep(500);
    }
    return n;
}
'@
"screen: $([Kit.Screen]::Size(1600, 900))" | Tee-Object -FilePath "$Out\where.txt"
"closed $([Kit.Screen]::Close('System Properties')) System Properties dialog(s)" | Tee-Object -FilePath "$Out\where.txt" -Append

$console = (Get-Process -Id $PID).SessionId
"session of this job: $console" | Tee-Object -FilePath "$Out\where.txt" -Append
(qwinsta 2>&1) | Out-File -Append "$Out\where.txt"
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version | Format-Table | Out-File -Append "$Out\where.txt"
# sound, for a later audio backend (a report, not a check): the audio service, the sound
# devices and the playback endpoints WASAPI loopback would capture
"== sound" | Out-File -Append "$Out\where.txt"
Get-Service Audiosrv, AudioEndpointBuilder -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType |
    Format-Table | Out-File -Append "$Out\where.txt"
Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table | Out-File -Append "$Out\where.txt"
Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | Select-Object FriendlyName, Status | Format-Table |
    Out-File -Append "$Out\where.txt"
# A runner has no sound card, and no virtual one installs here unattended: Scream
# (github.com/duncanthrax/scream) waited on Windows' driver prompt with devcon (runs
# 41164824167, 41166695002) and with pnputil (run 41169262905), however its signer was
# trusted. So the shadow server's sound is checked only where there is a playback device
# (SKIP otherwise); Windows' own Remote Desktop sessions have their own (Remote Audio).
$playback = [bool](Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue)
"playback device: $playback" | Out-File -Append "$Out\where.txt"
Set-Service Audiosrv -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service Audiosrv -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
"== sound, now" | Out-File -Append "$Out\where.txt"
Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue | Select-Object FriendlyName, Status | Format-Table |
    Out-File -Append "$Out\where.txt"
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

# AV2 (FreeRDP#13925, libavm): the server started by hand with /gfx-av2, the
# kit's client asking for it; AV1 stays what the service offers
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "server-av2.wlog"
$server = Start-Process -FilePath "$HostDir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
    -ArgumentList "/bind-address:127.0.0.1", "/port:4492", "/gfx-av1", "/gfx-av2"   # as host-README.txt says
for ($i = 0; $i -lt 30 -and -not (Listening 4492) -and -not $server.HasExited; $i++) { Start-Sleep -Seconds 1 }
Check "av2: the server listens on 127.0.0.1:4492" (Listening 4492)
$port = 4492
$s = Client @("/p:$pass", "/gfx:AV2:on", "/size:1280x720") "av2-session" 0 -Window
Start-Sleep -Seconds 20
Shot "av2"
Check "av2: a session holds 20 s" (-not $s.HasExited)
$codecs = Codecs "av2-session"
Check "av2: the frames came in AV2" (($codecs -join " ") -match "RDPGFX_CODECID_AV2") ($codecs -join ", ")
Stop $s

# the web client on the same AV2 server: the page decodes with libavm (no browser
# decodes AV2); the server's log says which GFX version it confirmed (FRDP_2 = AV2)
$webAv2 = "$Out\web-av2"
New-Item -ItemType Directory -Force -Path $webAv2 | Out-Null
$http = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$webAv2\http.log" -RedirectStandardError "$webAv2\http.err" `
    -ArgumentList "-m", "http.server", "8081", "--bind", "127.0.0.1", "--directory", $WebDir
& python -m pip install --quiet websockify 2>&1 | Out-File "$webAv2\pip.log"
$gw = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$webAv2\websockify.log" -RedirectStandardError "$webAv2\websockify.err" `
    -ArgumentList "-m", "websockify", "127.0.0.1:3391", "127.0.0.1:4492"
for ($i = 0; $i -lt 20 -and -not ((Listening 8081) -and (Listening 3391)); $i++) { Start-Sleep -Seconds 1 }
$env:CHROME = (Get-Command chrome.exe -ErrorAction SilentlyContinue).Source
if (-not $env:CHROME) { $env:CHROME = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe" }
& node "$KitTest\wasm-session.mjs" "http://127.0.0.1:8081/index.html" "127.0.0.1:3391" $user $pass $webAv2 2>&1 |
    Tee-Object "$webAv2\driver.log"
$about = Get-Content "$WebDir\MANIFEST" -Raw -ErrorAction SilentlyContinue
$serverLog = Get-Content "$Out\server-av2.wlog" -Raw -ErrorAction SilentlyContinue
if ($about -match "(?m)^\s+avm\s") {
    # the native session confirmed it once already: the page makes it twice
    Check "web-av2: the server confirmed AV2 for the page too (FRDP_2)" (([regex]::Matches($serverLog, "CAPS version=0x20000")).Count -ge 2)
    Check "web-av2: the page got a picture" ((Get-Content "$webAv2\page.log" -Raw -ErrorAction SilentlyContinue) -match "Remote framebuffer format")
} else {
    "web-av2: this web client has no AV2 (its MANIFEST names no avm); skipped" | Out-File -Append "$Out\notes.txt"
}
Stop $gw; Stop $http
Stop $server
$port = 4489

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
# the demos' page, from a server that sends COOP/COEP itself (test/coi-http.py): isolated at
# once, with no service-worker reload to wait for
$coi = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$web\coi-http.log" -RedirectStandardError "$web\coi-http.err" `
    -ArgumentList "$KitTest\coi-http.py", "8082", $WebDir
for ($i = 0; $i -lt 20 -and -not ((Listening 8080) -and (Listening 3390) -and (Listening 8082)); $i++) { Start-Sleep -Seconds 1 }
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
# its web video and WebGL, as test/demo/webdemo does on the Linux servers: the same page
# (media.html) and Firefox settings (user.js), served from this PC's 127.0.0.1:8000 and
# opened by "webdemo" typed into Win+R's Run box (a .cmd in the Windows folder, where
# Run finds it)
$site = $null
$firefox = "${env:ProgramFiles}\Mozilla Firefox\firefox.exe"
if ($Media -and (Test-Path "$Media\bunny.webm") -and (Test-Path $firefox)) {
    $wd = "$env:PUBLIC\webdemo"
    New-Item -ItemType Directory -Force -Path "$wd\site", "$wd\firefox" | Out-Null
    Copy-Item "$KitTest\demo\media.html" "$wd\site\index.html"
    Copy-Item "$Media\bunny.webm" "$wd\site\"
    Copy-Item -Recurse -Force "$Media\webgl" "$wd\site\"
    Copy-Item "$KitTest\demo\user.js" "$wd\firefox\"
    # a profile per user (the freerdp-tk demo's user runs it too, in a session of its own)
    Set-Content -Encoding ascii -Path "$env:SystemRoot\webdemo.cmd" -Value @(
        "@if not exist `"%LOCALAPPDATA%\webdemo-firefox`" mkdir `"%LOCALAPPDATA%\webdemo-firefox`" && copy `"$wd\firefox\user.js`" `"%LOCALAPPDATA%\webdemo-firefox\`" > nul",
        "@start `"`" `"$firefox`" -no-remote -profile `"%LOCALAPPDATA%\webdemo-firefox`" -width 1500 -height 820 http://127.0.0.1:8000/")
    $site = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$demo\webdemo-http.log" `
        -RedirectStandardError "$demo\webdemo-http.err" -ArgumentList "-m", "http.server", "8000", "--bind", "127.0.0.1", "--directory", "$wd\site"
    for ($i = 0; $i -lt 10 -and -not (Listening 8000); $i++) { Start-Sleep -Seconds 1 }
}
Check "demo: webdemo ready (the media page on 127.0.0.1:8000, Firefox)" ($site -and (Listening 8000)) `
    "$(if (-not $Media) { 'no media folder' } elseif (-not (Test-Path $firefox)) { 'no Firefox' })"
[Kit.Screen]::Close("System Properties") | Out-Null
(New-Object -ComObject Shell.Application).MinimizeAll()
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    & choco install ffmpeg -y --no-progress 2>&1 | Out-File "$demo\choco.log"
}
Memory "before the host demo"
$env:SERVER = "windows"
$env:DEMO_SOUND = if ($playback) { "1" } else { "" }   # the captions claim sound only with a device
& node "$KitTest\wasm-demo.mjs" "http://127.0.0.1:8082/index.html" "127.0.0.1:3390" $user $pass $demo "$demo\raw.mp4" 2>&1 |
    Tee-Object "$demo\driver.log"
Remove-Item Env:\SERVER
Memory "after the host demo"
if (Test-Path "$demo\raw.mp4") {
    $len = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 "$demo\raw.mp4")
    & ffmpeg -v error -y -i "$demo\raw.mp4" -vf "scale=1280:720:flags=lanczos,format=yuv420p" -c:v libx264 -crf 28 `
        -preset slow -c:a aac -b:a 96k -movflags +faststart "$Out\windows-host.mp4"
    & ffmpeg -v error -y -ss ("{0:F1}" -f ($len * 0.7)) -i "$demo\raw.mp4" -frames:v 1 `
        -vf "scale=1280:720:flags=lanczos" -q:v 4 "$Out\windows-host.jpg"
}
# the demo leaves Notepad and Firefox open on this same desktop: close them, and any
# menu, before the native client needs the focus
Stop-Process -Name notepad, firefox -Force -ErrorAction SilentlyContinue
Add-Type -Namespace Kit -Name Esc -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);'
[Kit.Esc]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero); [Kit.Esc]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
(New-Object -ComObject Shell.Application).MinimizeAll()
Check "demo: a video of the web client on this host" ((Test-Path "$Out\windows-host.mp4") -and (Test-Path "$Out\windows-host.jpg")) `
    "$(if (Test-Path "$Out\windows-host.mp4") { '{0:N1} MB' -f ((Get-Item "$Out\windows-host.mp4").Length / 1MB) })"
# the shadow server's sound: what this PC plays (WASAPI loopback), when it has a playback device,
# sent over rdpsnd; the video's last 30 s show the web video, so they must be heard, as
# record-demos.sh requires of the Linux demos (above -50 dB; silence is about -91)
$hostPeak = $null
if (Test-Path "$demo\raw.mp4") {
    $vd = (& ffmpeg -hide_banner -sseof -30 -i "$demo\raw.mp4" -map 0:a -af volumedetect -f null - 2>&1) -join "`n"
    if ($vd -match "max_volume: (-?[0-9.]+) dB") { $hostPeak = [double]$Matches[1] }
}
$capture = ([regex]::Matches((ServerLog), "audio: [^\r\n]*") | ForEach-Object Value | Select-Object -Unique) -join " | "
if ($playback) {
    Check "sound: the shadow server captures what this PC plays" ((ServerLog) -match "audio: capturing what the default render endpoint plays") $capture
    Check "sound: the web client hears the Windows PC (rdpsnd)" ($null -ne $hostPeak -and $hostPeak -gt -50) `
        "peak $(if ($null -ne $hostPeak) { "$hostPeak dB" } else { 'none' })"
} else {
    "SKIP  sound: no playback device on this runner to capture; the server says: $capture" |
        Tee-Object -FilePath "$Out\checks.txt" -Append
}

# Windows' own Remote Desktop on this PC, for the next two videos (FreeRDP Web, then
# freerdp-tk, each in a session of its own for the test user at 127.0.0.2): allowed for
# the user, its sound (the session's Remote Audio needs the audio service, started
# above), and the user's profile made now, so no video shows Windows' first sign-in
Set-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server" fDenyTSConnections 0
Add-LocalGroupMember -Group "Remote Desktop Users" -Member $user -ErrorAction SilentlyContinue
$cred = New-Object PSCredential $user, (ConvertTo-SecureString $pass -AsPlainText -Force)
Start-Process cmd -Credential $cred -LoadUserProfile -ArgumentList "/c", "exit" -Wait -WindowStyle Hidden
Check "rdp: Windows' own Remote Desktop listens on 3389, the user's profile is made" ((Listening 3389) -and (Test-Path "C:\Users\$user"))
# which TLS Windows' own server takes from our client (run 41166695002: "tlsv1 alert
# internal error" from Windows in the browser): a login each way, a report
foreach ($tls in @(), @("/tls:enforce:1.2"), @("/tls:enforce:1.3")) {
    $name = if ($tls) { $tls[0] -replace "[/:]", "-" } else { "default" }
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "rdp-auth$name.wlog"
    $r = Start-Process -FilePath "$ClientDir\sdl-freerdp.exe" -PassThru -NoNewWindow `
        -ArgumentList (@("/v:127.0.0.2:3389", "/u:$user", "/p:$pass", "/cert:ignore", "/auth-only") + $tls)
    $r.WaitForExit(30000) | Out-Null
    $said = Select-String -Path "$Out\rdp-auth$name.wlog" -Pattern "Authentication only, exit status (\w+)|alert [a-z ]+" -ErrorAction SilentlyContinue |
        Select-Object -Last 1 | ForEach-Object { $_.Matches[0].Value }
    "rdp: TLS $name -> $(if ($said) { $said } else { "exit $($r.ExitCode)" })" | Tee-Object -FilePath "$Out\where.txt" -Append
}
# where Windows' SChannel gave up on TLS 1.3 (freerdp-59's ask): its System log's events,
# e.g. 36888 "fatal alert 80, internal error state N" (a report)
Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Schannel" } -MaxEvents 20 -ErrorAction SilentlyContinue |
    Format-List TimeCreated, Id, Message | Out-File "$Out\schannel-events.txt"
function SignOut {   # the test user's Remote Desktop session, and what it left running
    Get-Process notepad, firefox -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like "*\$user" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    (quser 2>$null) -match "^\s*>?$user\s" | ForEach-Object {
        $id = ($_ -split "\s+" | Where-Object { $_ -match "^\d+$" })[0]; if ($id) { logoff $id } }
    Start-Sleep -Seconds 3
}

# the second video: FreeRDP Web to Windows' own Remote Desktop, through a websockify of
# its own (127.0.0.1:3391 to 127.0.0.2:3389); its sound comes through the session
if ($site) {
    $rdemo = "$Out\demo-rdp"
    New-Item -ItemType Directory -Force -Path $rdemo | Out-Null
    $rgw = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$rdemo\websockify.log" `
        -RedirectStandardError "$rdemo\websockify.err" -ArgumentList "-m", "websockify", "127.0.0.1:3391", "127.0.0.2:3389"
    for ($i = 0; $i -lt 20 -and -not (Listening 3391); $i++) { Start-Sleep -Seconds 1 }
    Memory "before the Windows Remote Desktop demo"
    $env:SERVER = "windows-rdp"
    & node "$KitTest\wasm-demo.mjs" "http://127.0.0.1:8082/index.html" "127.0.0.1:3391" $user $pass $rdemo "$rdemo\raw.mp4" 2>&1 |
        Tee-Object "$rdemo\driver.log"
    Remove-Item Env:\SERVER
    $peak = "none"
    if (Test-Path "$rdemo\raw.mp4") {
        $len = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 "$rdemo\raw.mp4")
        & ffmpeg -v error -y -i "$rdemo\raw.mp4" -vf "scale=1280:720:flags=lanczos,format=yuv420p" -c:v libx264 -crf 28 `
            -preset slow -c:a aac -b:a 96k -movflags +faststart "$Out\windows-rdp.mp4"
        & ffmpeg -v error -y -ss ("{0:F1}" -f ($len * 0.7)) -i "$rdemo\raw.mp4" -frames:v 1 `
            -vf "scale=1280:720:flags=lanczos" -q:v 4 "$Out\windows-rdp.jpg"
        # the last 30 s show the web video: its sound, as record-demos.sh measures it
        $vd = (& ffmpeg -hide_banner -sseof -30 -i "$rdemo\raw.mp4" -map 0:a -af volumedetect -f null - 2>&1) -join "`n"
        if ($vd -match "max_volume: (-?[0-9.]+) dB") { $peak = "$($Matches[1]) dB" }
    }
    Stop $rgw
    SignOut
    # a session, not only a file: the page got the desktop (as wasm-session.sh asks of the
    # Linux logins), else the video shows a failed connection (run 41176456545)
    $rx = try { (Get-Content "$rdemo\canvas.json" -Raw | ConvertFrom-Json).rx } catch { 0 }
    Check "demo: FreeRDP Web to Windows' own Remote Desktop, a session and its video" `
        ((Test-Path "$Out\windows-rdp.mp4") -and (Test-Path "$Out\windows-rdp.jpg") -and $rx -gt 300000) `
        "$(if (Test-Path "$Out\windows-rdp.mp4") { '{0:N1} MB' -f ((Get-Item "$Out\windows-rdp.mp4").Length / 1MB) }); $rx bytes in; sound peak $peak"
    (New-Object -ComObject Shell.Application).MinimizeAll()
}

# the third video: freerdp-tk from the client's zip, to Windows' own Remote Desktop here
if ($ClientZip -and $site) {
    # a failure there is its own check below, not the end of this test (run 41196854812)
    try { & "$KitTest\client-demo\windows.ps1" $ClientZip $user $pass $Out 2>&1 | Tee-Object "$Out\tk-demo.log" }
    catch { "the freerdp-tk demo stopped: $($_.Exception.Message)" | Tee-Object -FilePath "$Out\tk-demo.log" -Append }
    $sound = (Get-Content "$Out\tk-demo\winrec.log" -Raw -ErrorAction SilentlyContinue) -replace "\s+", " "
    # both visits done (connect, Notepad, webdemo, disconnect; the saved connection again)
    $tkDone = (Get-Content "$Out\tk-demo\run.log" -Raw -ErrorAction SilentlyContinue) -match "done: True"
    $tkLog = Get-Content "$Out\tk-demo\run.log" -Raw -ErrorAction SilentlyContinue
    if (-not $tkDone -and $tkLog -match "not in front" -and $tkLog -match "unpacked: -1 files") {
        # nothing typed reached PowerShell: the test could not focus its window (a toast kept
        # the front), so freerdp-tk was never started; the harness, not the product
        "SKIP  demo: freerdp-tk to Windows' own Remote Desktop: the test could not bring PowerShell to the front" |
            Tee-Object -FilePath "$Out\checks.txt" -Append
    } else {
        Check "demo: freerdp-tk to Windows' own Remote Desktop, both visits and a video" `
            ($tkDone -and (Test-Path "$Out\freerdp-tk-windows.mp4") -and (Test-Path "$Out\freerdp-tk-windows.jpg")) `
            "$(if (Test-Path "$Out\freerdp-tk-windows.mp4") { '{0:N1} MB' -f ((Get-Item "$Out\freerdp-tk-windows.mp4").Length / 1MB) }); $sound"
    }
    # the web demos before it pressed Win+R and Win+D on this console through the shadow
    # server, and their clients then left: none of their keys may still be held here
    # (FreeRDP#13958 lets go of a leaving client's keys; wininput.py release logs them)
    $held = [regex]::Match((Get-Content "$Out\tk-demo\run.log" -Raw -ErrorAction SilentlyContinue), "held: ([^\r\n]*)").Groups[1].Value
    Check "keys: none still held after the web clients left (FreeRDP#13958)" ($held -eq "none") "held: $held"
    SignOut
    (New-Object -ComObject Shell.Application).MinimizeAll()
}
Stop $site
Stop $gw; Stop $http

# the native client: an AV1 session, Ctrl+Alt+Del, the lock screen
$session = Client @("/p:$pass", "/gfx:AV1:on", "/size:1280x720", "/sound") "session" 0 -Window
Start-Sleep -Seconds 15
Shot "desktop"
Check "native: an AV1 session holds 15 s" (-not $session.HasExited)
$codecs = Codecs "session"
Check "native: the frames came in AV1" (($codecs -join " ") -match "RDPGFX_CODECID_AV1") ($codecs -join ", ")
# its sound channel (a report: the desktop plays nothing now, so no samples need come)
"native rdpsnd: " + ((Select-String -Path "$Out\session.wlog" -Pattern "rdpsnd" -ErrorAction SilentlyContinue |
    Select-Object -First 12 | ForEach-Object { $_.Line }) -join " | ") | Out-File -Append "$Out\notes.txt"

# Ctrl+Alt+Del typed into the client's window: three ordinary keys there,
# which the client sends to the server
Add-Type -Namespace Kit -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, System.IntPtr pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
# the client's window to the front, for sure: Windows' foreground lock refused it once and the
# keys went elsewhere (run 41208207833, second attempt: no key press in the server's log).
# An Alt press, then this thread joined to the front window's input queue, up to five times.
function Focus($hwnd) {
    for ($i = 0; $i -lt 5; $i++) {
        [Kit.Keys]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Kit.Keys]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        $mine = [Kit.Keys]::GetCurrentThreadId()
        $theirs = [Kit.Keys]::GetWindowThreadProcessId([Kit.Keys]::GetForegroundWindow(), [IntPtr]::Zero)
        $joined = $theirs -and $theirs -ne $mine -and [Kit.Keys]::AttachThreadInput($mine, $theirs, $true)
        [void][Kit.Keys]::BringWindowToTop($hwnd); [void][Kit.Keys]::SetForegroundWindow($hwnd)
        if ($joined) { [void][Kit.Keys]::AttachThreadInput($mine, $theirs, $false) }
        Start-Sleep -Milliseconds 500
        if ([Kit.Keys]::GetForegroundWindow() -eq $hwnd) { return $true }
    }
    return $false
}
# Delete presses the server took (its input log at DEBUG: Delete is an extended key, a key down
# with flags=0x0100; Ctrl and Alt are 0x0000, but so are the key events the focus change sends,
# so only Delete tells that the typed keys arrived)
function DeleteDowns { ([regex]::Matches((ServerLog), "shadow_input_keyboard_event\]: \[use\] flags=0x0100")).Count }
$session.Refresh()
if ($session.MainWindowHandle -eq [IntPtr]::Zero) {
    Check "Ctrl+Alt+Del: the client has a window to type into" $false
} elseif (-not (Focus $session.MainWindowHandle)) {
    # the harness, not the product: say so, as for the sound
    "SKIP  Ctrl+Alt+Del: the test could not bring the client's window to the front" | Tee-Object -FilePath "$Out\checks.txt" -Append
} else {
    $deletes = DeleteDowns
    [Kit.Keys]::keybd_event(0x11, 0x1D, 0, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x12, 0x38, 0, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x2E, 0x53, 1, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x2E, 0x53, 3, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x12, 0x38, 2, [UIntPtr]::Zero)
    [Kit.Keys]::keybd_event(0x11, 0x1D, 2, [UIntPtr]::Zero)
    Start-Sleep -Seconds 8
    $svcLog = Get-Content "$logs\service.log" -Raw -ErrorAction SilentlyContinue
    # three steps, so a failure says where: the keys reached the server, the server asked the
    # service, the service sent it (SendSAS returns nothing: "sent" is as far as it can tell)
    Check "Ctrl+Alt+Del: the keys reached the server" ((DeleteDowns) -gt $deletes) "$((DeleteDowns) - $deletes) Delete presses"
    Check "Ctrl+Alt+Del: the server asked the service" ((ServerLog) -match "asked freerdp-shadow-service for the secure attention sequence")
    Check "Ctrl+Alt+Del: the service sent the secure attention sequence" ($svcLog -match "secure attention sequence sent")
    Check "Ctrl+Alt+Del: the server followed to Winlogon" ((ServerLog) -match "follows the input desktop from \w+ to Winlogon")
    Check "Ctrl+Alt+Del: the session holds" (-not $session.HasExited)
    Shot "after-sas"
    [Kit.Keys]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)   # Esc: leave the Ctrl+Alt+Del screen
    [Kit.Keys]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
    Start-Sleep -Seconds 5
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

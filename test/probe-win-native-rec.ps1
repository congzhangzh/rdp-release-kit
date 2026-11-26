# A record, not a kit test (demo 1.1's probe): the kit's native Windows client (sdl-freerdp) to
# the kit's Windows shadow server on this PC, in AV1 4:2:0 (/gfx:AV2:off,AV1:i420), while the
# demo's media page (test/demo/media.html, the video alone) plays in Firefox on the shared
# desktop. It records the client's window (ffmpeg gdigrab) and says the session's rate from the
# server's own AV1 encoder lines ("AV1 WxH I420: N frames in T s (F fps)", every 5 s), against
# the demo bar of 15/s, and which AV1 decoder the client used.
#
#   probe-win-native-rec.ps1 <host folder> <client folder> <demo media folder> <out dir>
param([string]$HostDir, [string]$ClientDir, [string]$Media, [string]$Out)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$HostDir = (Resolve-Path $HostDir).Path
$ClientDir = (Resolve-Path $ClientDir).Path
$Media = (Resolve-Path $Media).Path
$Out = (Resolve-Path $Out).Path
$KitTest = $PSScriptRoot
$user = "kit"
$pass = "Shadow-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$port = 4495
$seconds = 40
function Listening($p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }
function Stop($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 2
}
function Note($line) { $line | Tee-Object -FilePath "$Out\verdicts.txt" -Append }

$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1)
"CPU: $($cpu.Name.Trim()), $($cpu.NumberOfLogicalProcessors) logical" | Tee-Object -FilePath "$Out\where.txt"
"GPU: $((Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join '; ')" | Tee-Object -FilePath "$Out\where.txt" -Append

# the screen at 1600 x 900 (the runner's is 1024 x 768), as windows-host.ps1 sets it; window moves
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
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern System.IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] static extern bool PostMessage(System.IntPtr w, uint msg, System.IntPtr wp, System.IntPtr lp);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr w, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr w, out RECT r);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr w);
public static string Size(int w, int h) {
    DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) return "the current mode is unknown";
    string was = dm.dmPelsWidth + " x " + dm.dmPelsHeight;
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x80000 | 0x100000;
    return was + " -> " + w + " x " + h + ": " + ChangeDisplaySettings(ref dm, 0);
}
public static int Close(string title) {
    int n = 0;
    for (System.IntPtr h; n < 10 && (h = FindWindow(null, title)) != System.IntPtr.Zero; n++) {
        PostMessage(h, 0x10, System.IntPtr.Zero, System.IntPtr.Zero); System.Threading.Thread.Sleep(500);
    }
    return n;
}
'@
"screen: $([Kit.Screen]::Size(1600, 900))" | Tee-Object -FilePath "$Out\where.txt" -Append
"closed $([Kit.Screen]::Close('System Properties')) System Properties dialog(s)" | Tee-Object -FilePath "$Out\where.txt" -Append
if ($env:GITHUB_ACTIONS -eq "true") {   # as windows-host.ps1: StorSvc burned the CPU in slow rounds
    try { Set-Service StorSvc -StartupType Disabled; Stop-Service StorSvc -Force -ErrorAction Stop } catch { }
}
New-LocalUser -Name $user -Password (ConvertTo-SecureString $pass -AsPlainText -Force) -PasswordNeverExpires | Out-Null

# the recorder: BtbN's static FFmpeg 8.1, checked against its checksums.sha256 (windows-host.ps1)
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    $ffName = "ffmpeg-n8.1-latest-win64-gpl-8.1.zip"
    $ffBase = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"
    $ffDir = "$env:RUNNER_TEMP\ci-ffmpeg"
    New-Item -ItemType Directory -Force $ffDir | Out-Null
    Invoke-WebRequest "$ffBase/$ffName" -OutFile "$ffDir\$ffName" -MaximumRetryCount 5 -RetryIntervalSec 10
    Invoke-WebRequest "$ffBase/checksums.sha256" -OutFile "$ffDir\checksums.sha256" -MaximumRetryCount 5 -RetryIntervalSec 10
    $want = ([regex]::Match((Get-Content "$ffDir\checksums.sha256" -Raw), "(?m)^([0-9a-f]{64})\s+$([regex]::Escape($ffName))\s*$")).Groups[1].Value
    if (-not $want -or $want -ne (Get-FileHash "$ffDir\$ffName" -Algorithm SHA256).Hash.ToLower()) { throw "$ffName does not match its checksum" }
    Expand-Archive "$ffDir\$ffName" $ffDir -Force
    $env:PATH = "$((Get-ChildItem $ffDir -Recurse -Filter ffmpeg.exe | Select-Object -First 1).DirectoryName);$env:PATH"
}
"ffmpeg: $(& ffmpeg -hide_banner -version | Select-Object -First 1)" | Tee-Object -FilePath "$Out\where.txt" -Append

# the media page (the video alone) in Firefox, as windows-host.ps1's webdemo opens it, but on
# this desktop directly: the shadow server shares this desktop, so the page plays in the session
$firefox = "${env:ProgramFiles}\Mozilla Firefox\firefox.exe"
$wd = "$env:RUNNER_TEMP\webdemo"
New-Item -ItemType Directory -Force -Path "$wd\site", "$wd\profile" | Out-Null
Copy-Item "$KitTest\demo\media.html" "$wd\site\index.html"
Copy-Item "$Media\bunny.webm" "$wd\site\"
Copy-Item "$KitTest\demo\user.js" "$wd\profile\"
$dist = Join-Path (Split-Path $firefox) "distribution"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
Set-Content -Encoding utf8 -Path "$dist\policies.json" -Value (@{ policies = @{
    UserMessaging = @{ SkipOnboarding = $true; MoreFromMozilla = $false; FeatureRecommendations = $false
        ExtensionRecommendations = $false; UrlbarInterventions = $false; FirefoxLabs = $false; Locked = $true }
    DontCheckDefaultBrowser = $true; DisableDefaultBrowserAgent = $true
    OverrideFirstRunPage = ""; OverridePostUpdatePage = "" } } | ConvertTo-Json -Depth 4)
$site = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$Out\http.log" `
    -RedirectStandardError "$Out\http.err" -ArgumentList "-m", "http.server", "8000", "--bind", "127.0.0.1", "--directory", "$wd\site"
for ($i = 0; $i -lt 10 -and -not (Listening 8000); $i++) { Start-Sleep -Seconds 1 }
$ff = Start-Process -FilePath $firefox -PassThru -ArgumentList "-no-remote", "-profile", "$wd\profile",
    "-width", "1500", "-height", "820", "http://127.0.0.1:8000/?video-only"
Start-Sleep -Seconds 12

# the shadow server, by hand, AV1 on and AV2 off (as windows-host.ps1's av1-i420 step)
$env:WLOG_LEVEL = "DEBUG"
$env:WLOG_APPENDER = "FILE"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "server.wlog"
$server = Start-Process -FilePath "$HostDir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
    -ArgumentList "/bind-address:127.0.0.1", "/port:$port", "/gfx-av1", "/gfx-av2:off"
for ($i = 0; $i -lt 30 -and -not (Listening $port) -and -not $server.HasExited; $i++) { Start-Sleep -Seconds 1 }
Note "INFO  server listens on 127.0.0.1:${port}: $(Listening $port)"

# the native client, 800 x 450 (as the Mac probe), in the screen's lower right, over the
# page's lower right corner: it shows the whole desktop, the page's video in it
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "native.wlog"
$client = Start-Process -FilePath "$ClientDir\sdl-freerdp.exe" -PassThru -ArgumentList "/v:127.0.0.1:$port",
    "/u:$user", "/p:$pass", "/cert:ignore", "/gfx:AV2:off,AV1:i420", "/size:800x450"
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 30 -and $h -eq [IntPtr]::Zero -and -not $client.HasExited; $i++) {
    Start-Sleep -Seconds 1; $client.Refresh(); $h = $client.MainWindowHandle }
Start-Sleep -Seconds 5
$rect = $null
if ($h -ne [IntPtr]::Zero) {
    # SWP_NOSIZE | SWP_SHOWWINDOW; HWND_TOPMOST (-1) so Firefox never covers it
    [Kit.Screen]::SetWindowPos($h, [IntPtr]-1, 1600 - 820, 900 - 520, 0, 0, 0x0041) | Out-Null
    Start-Sleep -Seconds 2
    $r = New-Object Kit.Screen+RECT
    if ([Kit.Screen]::GetWindowRect($h, [ref]$r)) { $rect = $r }
}
Note "INFO  native: window $(if ($rect) { "$($rect.Left),$($rect.Top) to $($rect.Right),$($rect.Bottom)" } else { 'unknown' }); title '$($client.MainWindowTitle)'"
$off = (Get-Item "$Out\server.wlog").Length

# the recording: the client's window (gdigrab, 30/s asked), or the whole screen without its rect
$grab = @("-f", "gdigrab", "-framerate", "30", "-draw_mouse", "0")
if ($rect) {
    $w = 2 * [int][math]::Floor(($rect.Right - $rect.Left) / 2); $hh = 2 * [int][math]::Floor(($rect.Bottom - $rect.Top) / 2)
    $grab += @("-offset_x", "$($rect.Left)", "-offset_y", "$($rect.Top)", "-video_size", "${w}x${hh}")
}
$raw = "$env:RUNNER_TEMP\native-raw.mkv"
& ffmpeg -hide_banner -loglevel warning -y @grab -t $seconds -i desktop -c:v libx264 -preset ultrafast -crf 18 $raw 2>&1 |
    Out-File "$Out\record.log"
$client.Refresh()
Note "INFO  native: the client held the $seconds s: $(-not $client.HasExited)"
Stop $client
Stop $server
Stop $ff
Stop $site

$V = "$Out\native-av1-i420.mp4"
if (Test-Path $raw) {
    & ffmpeg -v error -y -i $raw -vf "scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p" `
        -c:v libx264 -crf 28 -preset slow -an -movflags +faststart $V
    $n = & ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $raw
    $len = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $raw)
    Note ("INFO  native: the recording: $n frames in {0:N1} s ({1:N1} fps written)" -f $len, $(if ($len) { $n / $len } else { 0 }))
    foreach ($s in @(@("", 0.7), @("-mid", 0.5), @("-late", 0.95))) {
        & ffmpeg -v error -y -ss ("{0:F2}" -f ($len * $s[1])) -i $V -frames:v 1 -q:v 4 "$Out\native-av1-i420$($s[0]).jpg"
    }
} else { Note "MISSING  native: no recording ($((Get-Content "$Out\record.log" -Tail 1) -join ''))" }

# the session's rate: the server's AV1 encoder lines while the recording ran, the page playing
$fs = [System.IO.File]::Open("$Out\server.wlog", "Open", "Read", "ReadWrite")
$fs.Seek($off, "Begin") | Out-Null
$tail = (New-Object System.IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
Set-Content -Encoding utf8 -Path "$Out\native-server.wlog" -Value $tail
$lines = @([regex]::Matches($tail, "AV1 [0-9]+x[0-9]+ I4[24][04]: [0-9]+ frames in [0-9.]+ s \(([0-9.]+) fps\)[^\r\n]*") |
    ForEach-Object { $_.Value })
$lines | ForEach-Object { Note "INFO  native: server $_" }
$fps = @($lines | ForEach-Object { [double]([regex]::Match($_, "\(([0-9.]+) fps\)").Groups[1].Value) })
if ($fps.Count) {
    $mean = ($fps | Measure-Object -Average).Average
    Note ("NATIVE-VERDICT  {0}/s (the server encoded a mean {1:N1} fps over {2} lines)" -f $(if ($mean -ge 15) { ">= 15" } else { "< 15" }), $mean, $fps.Count)
} else { Note "NATIVE-VERDICT  unknown (no AV1 encoder line in this session)" }
# the frames' codec and caps, and which AV1 decoder the client used
$caps = Select-String -Path "$Out\native.wlog" -Pattern "RecvCapsConfirmPdu: version: \S+.*" -ErrorAction SilentlyContinue | Select-Object -Last 1
Note "INFO  native: caps $(if ($caps) { $caps.Matches[0].Value } else { 'none' })"
Note "INFO  native: decoder lines:"
Select-String -Path "$Out\native.wlog" -Pattern "dav1d|AV1 decoder|decoder:|MediaFoundation|hardware|D3D11|DXVA" -ErrorAction SilentlyContinue |
    Select-Object -First 12 | ForEach-Object { Note "    $($_.Line)" }
Remove-LocalUser -Name $user -ErrorAction SilentlyContinue
Get-Content "$Out\verdicts.txt"
if (-not (Test-Path $V)) { exit 1 }

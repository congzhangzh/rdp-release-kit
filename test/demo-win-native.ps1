# Demo 1.1 of the product plan (Boss Cong's go, 2026-11-27): the kit's native Windows client
# (sdl-freerdp) to the kit's Windows shadow server on this PC, in AV1 4:2:0
# (/gfx:AV2:off,AV1:i420), while the demo's media page (test/demo/media.html, the video alone)
# plays. From probe-win-native-rec (runs 45778612035, 45929390271: the product owner's frame
# check). It writes windows-native.mp4 and .jpg only when the session passes the demo's bar (see
# the end); otherwise the demo is left out and the round goes on.
#
# The product owner's conditions: two monitors, so nothing mirrors itself. An
# IddCx virtual display driver adds a second one (as windows-host-allmon.ps1, the same pinned
# package); the page plays full screen on the first (1600 x 900), the shadow server shares only
# that one (/monitors:<its index>), and the client's window sits on the second (1920 x 1080), which
# the recorder grabs. The page runs in Edge (app mode, its first-run screens off by policy), not
# Firefox, whose "pin Firefox to your taskbar?" dialog sat over v1's video; Windows' toasts are off.
# The label quotes what the session logged: "AV1 4:2:0 · <the client's decoder> · <the server's
# mean rate>/s". The rate comes from the server's own AV1 encoder lines ("AV1 WxH I420: N frames
# in T s (F fps)", every 5 s), against the demo bar of 15/s; the recorder's written rate is
# reported beside it (it must not be below the session's).
#
#   demo-win-native.ps1 <host folder> <client folder> <demo media folder> <out dir>
#                            <driver zip> <its sha256> <devnode.exe>
param([string]$HostDir, [string]$ClientDir, [string]$Media, [string]$Out,
      [string]$VddZip, [string]$VddSha256, [string]$DevNode)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$HostDir = (Resolve-Path $HostDir).Path
$ClientDir = (Resolve-Path $ClientDir).Path
$Media = (Resolve-Path $Media).Path
$Out = (Resolve-Path $Out).Path
$KitTest = $PSScriptRoot
$user = "kit"
$pass = "Shadow-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$port = 3388   # the product's port everywhere (the window title shows it)
$seconds = 40
function Listening($p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }
function Stop($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 2
}
function Note($line) { $line | Tee-Object -FilePath "$Out\verdicts.txt" -Append }
function Until([int]$s, [scriptblock]$cond) {
    for ($i = 0; $i -lt $s; $i++) { if (& $cond) { return $true }; Start-Sleep -Seconds 1 }
    return [bool](& $cond)
}

$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1)
"CPU: $($cpu.Name.Trim()), $($cpu.NumberOfLogicalProcessors) logical" | Tee-Object -FilePath "$Out\where.txt"
"GPU: $((Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join '; ')" | Tee-Object -FilePath "$Out\where.txt" -Append

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
[DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, System.IntPtr hwnd, int flags, System.IntPtr param);
[DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")] static extern int ChangeDisplaySettingsExApply(System.IntPtr dev, System.IntPtr dm, System.IntPtr hwnd, int flags, System.IntPtr param);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern System.IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] static extern bool PostMessage(System.IntPtr w, uint msg, System.IntPtr wp, System.IntPtr lp);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr w, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr w, out RECT r);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
public static string Size(int w, int h) {
    DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) return "the current mode is unknown";
    string was = dm.dmPelsWidth + " x " + dm.dmPelsHeight;
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x80000 | 0x100000;
    // CDS_UPDATEREGISTRY: kept when a later apply re-reads the registry (run 45928963487: the second
    // monitor's apply put the first back at 1024 x 768, and the client stretched it to 1600 x 900)
    return was + " -> " + w + " x " + h + ": " + ChangeDisplaySettings(ref dm, 0x01);
}
// a display's mode and place: CDS_UPDATEREGISTRY | CDS_NORESET for the device, then one apply;
// 60 Hz asked first (DM_DISPLAYFREQUENCY), without it when the driver refuses; 0 = success
public static string Mode(string dev, int w, int h, int x, int y) {
    DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(dev, -1, ref dm)) return "the mode of " + dev + " is unknown";
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmPositionX = x; dm.dmPositionY = y;
    dm.dmDisplayFrequency = 60; dm.dmFields = 0x80000 | 0x100000 | 0x20 | 0x400000;
    int set = ChangeDisplaySettingsEx(dev, ref dm, System.IntPtr.Zero, 0x01 | 0x10000000, System.IntPtr.Zero);
    string hz = "60 Hz";
    if (set != 0) {
        dm.dmFields = 0x80000 | 0x100000 | 0x20; hz = "its own rate";
        set = ChangeDisplaySettingsEx(dev, ref dm, System.IntPtr.Zero, 0x01 | 0x10000000, System.IntPtr.Zero);
    }
    int apply = ChangeDisplaySettingsExApply(System.IntPtr.Zero, System.IntPtr.Zero, System.IntPtr.Zero, 0, System.IntPtr.Zero);
    return dev + " " + w + "x" + h + "+" + x + "+" + y + " at " + hz + ": set " + set + ", apply " + apply;
}
public static int Close(string title) {
    int n = 0;
    for (System.IntPtr h; n < 10 && (h = FindWindow(null, title)) != System.IntPtr.Zero; n++) {
        PostMessage(h, 0x10, System.IntPtr.Zero, System.IntPtr.Zero); System.Threading.Thread.Sleep(500);
    }
    return n;
}
'@
# the monitors, from a new process each time (Screen.AllScreens caches its list in a process)
function Screens {
    $json = pwsh -NoProfile -Command 'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { [pscustomobject]@{ Device = $_.DeviceName; Primary = $_.Primary; X = $_.Bounds.X; Y = $_.Bounds.Y; W = $_.Bounds.Width; H = $_.Bounds.Height } } | ConvertTo-Json -Compress'
    @($json | ConvertFrom-Json)
}
function ScreensText($s) { ($s | ForEach-Object { "$($_.Device) $($_.W)x$($_.H)+$($_.X)+$($_.Y)$(if ($_.Primary) { ' primary' })" }) -join "; " }

"screen: $([Kit.Screen]::Size(1600, 900))" | Tee-Object -FilePath "$Out\where.txt" -Append
"closed $([Kit.Screen]::Close('System Properties')) System Properties dialog(s)" | Tee-Object -FilePath "$Out\where.txt" -Append
if ($env:GITHUB_ACTIONS -eq "true") {
    # on a CI runner only: StorSvc off (it burned the CPU in slow rounds, windows-host.ps1), and
    # Windows' toasts and notification center off, so no prompt sits over the recording
    try { Set-Service StorSvc -StartupType Disabled; Stop-Service StorSvc -Force -ErrorAction Stop } catch { }
    # (New-Item -Force on a key that exists replaces it, which Windows refuses: run 45928748986)
    function RegSet([string]$key, [string]$name, [int]$value) {
        try {
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            Set-ItemProperty -Path $key -Name $name -Value $value -Type DWord
            "reg: $key $name = $value"
        } catch { "reg: $key $name not set: $($_.Exception.Message)" }
    }
    $(
        RegSet "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" ToastEnabled 0
        RegSet "HKCU:\Software\Policies\Microsoft\Windows\Explorer" DisableNotificationCenter 1
        # Edge's own first-run screens, sign-in and sync prompts, and its "recommendations"
        foreach ($kv in @(@("HideFirstRunExperience", 1), @("BrowserSignin", 0), @("SyncDisabled", 1),
                          @("ShowRecommendationsEnabled", 0), @("DefaultBrowserSettingEnabled", 0),
                          @("PromotionalTabsEnabled", 0), @("AutoplayAllowed", 1), @("TranslateEnabled", 0),
                          @("StartupBoostEnabled", 0), @("HubsSidebarEnabled", 0))) {
            RegSet "HKLM:\SOFTWARE\Policies\Microsoft\Edge" $kv[0] $kv[1]
        }
    ) | Tee-Object -FilePath "$Out\where.txt" -Append
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

# ---- the second monitor (windows-host-allmon.ps1's steps): the pinned driver, its signer trusted
# first (pnputil waits on Windows' driver prompt otherwise), the device node
$actual = (Get-FileHash -Algorithm SHA256 -Path $VddZip).Hash.ToLowerInvariant()
if ($actual -ne $VddSha256.ToLowerInvariant()) { throw "the driver zip is $actual, not the pinned one" }
$pkg = "$env:RUNNER_TEMP\vdd"
Expand-Archive -Path $VddZip -DestinationPath $pkg -Force
$inf = Get-ChildItem -Path $pkg -Recurse -Filter 'MttVDD.inf' | Select-Object -First 1
New-Item -ItemType Directory -Force -Path 'C:\VirtualDisplayDriver' | Out-Null
Copy-Item -Path (Join-Path $inf.DirectoryName 'vdd_settings.xml') -Destination 'C:\VirtualDisplayDriver\vdd_settings.xml' -Force
$cert = (Get-AuthenticodeSignature -FilePath (Join-Path $inf.DirectoryName 'mttvdd.cat')).SignerCertificate
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
$store.Open('ReadWrite'); $store.Add($cert); $store.Close()
function Bounded([string]$name, [string]$exe, [string[]]$arguments, [int]$s) {
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput "$Out\$name.txt" -RedirectStandardError "$Out\$name.err.txt"
    if ($p.WaitForExit($s * 1000)) { return $p.ExitCode }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    return "timeout ${s}s"
}
"pnputil: $(Bounded 'pnputil' 'pnputil.exe' @('/add-driver', $inf.FullName, '/install') 120)" | Tee-Object -FilePath "$Out\where.txt" -Append
"devnode: $(Bounded 'devnode' $DevNode @($inf.FullName, 'Root\MttVDD', 'Display') 120)" | Tee-Object -FilePath "$Out\where.txt" -Append
[void](Until 30 { [Kit.Screen]::GetSystemMetrics(80) -ge 2 })   # SM_CMONITORS
$screens = Screens
$second = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
if (-not $second) { Note "MISSING  no second monitor ($(ScreensText $screens))"; exit 1 }
# the second one at 1920 x 1080, right of the first
"monitor 2: $([Kit.Screen]::Mode($second.Device, 1920, 1080, 1600, 0))" | Tee-Object -FilePath "$Out\where.txt" -Append
Start-Sleep -Seconds 3
"screen again: $([Kit.Screen]::Size(1600, 900))" | Tee-Object -FilePath "$Out\where.txt" -Append
Start-Sleep -Seconds 3
$screens = Screens
$first = $screens | Where-Object { $_.Primary } | Select-Object -First 1
$second = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
Note "INFO  monitors: $(ScreensText $screens)"
if ($first.W -ne 1600 -or $first.H -ne 900) { Note "MISSING  the shared monitor is $($first.W)x$($first.H), not 1600x900"; exit 1 }

# ---- the media page, full screen on the first monitor, in Edge's app mode (no browser UI)
$wd = "$env:RUNNER_TEMP\webdemo"
New-Item -ItemType Directory -Force -Path "$wd\site", "$wd\edge" | Out-Null
Copy-Item "$KitTest\demo\media.html" "$wd\site\index.html"
Copy-Item "$Media\bunny.webm" "$wd\site\"
$site = Start-Process -FilePath python -PassThru -NoNewWindow -RedirectStandardOutput "$Out\http.log" `
    -RedirectStandardError "$Out\http.err" -ArgumentList "-m", "http.server", "8000", "--bind", "127.0.0.1", "--directory", "$wd\site"
[void](Until 10 { Listening 8000 })
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
"edge: $edge" | Tee-Object -FilePath "$Out\where.txt" -Append
$browser = Start-Process -FilePath $edge -PassThru -ArgumentList "--user-data-dir=$wd\edge", "--no-first-run",
    "--no-default-browser-check", "--disable-sync", "--autoplay-policy=no-user-gesture-required",
    "--window-position=$($first.X),$($first.Y)", "--window-size=$($first.W),$($first.H)", "--start-fullscreen",
    "--app=http://127.0.0.1:8000/?video-only"
Start-Sleep -Seconds 12

# ---- the shadow server, by hand, AV1 on and AV2 off, sharing only the first monitor: its index
# in the server's own list ("/monitors" lists them: "* [N] WxH +X+Y", * on the primary)
$env:WLOG_LEVEL = "DEBUG"
$env:WLOG_APPENDER = "FILE"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "server-monitors.wlog"
[void](Bounded 'server-monitors' "$HostDir\freerdp-shadow-cli.exe" @('/monitors') 30)
$list = Get-Content "$Out\server-monitors.wlog", "$Out\server-monitors.txt" -ErrorAction SilentlyContinue |
    Select-String -Pattern "\[(\d+)\] (\d+)x(\d+)\s+\+(-?\d+)\+(-?\d+)"
$list | ForEach-Object { Note "INFO  server's monitor list: $($_.Line.Trim())" }
$index = $list | Where-Object { [int]$_.Matches[0].Groups[4].Value -eq $first.X -and [int]$_.Matches[0].Groups[5].Value -eq $first.Y } |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
if ($null -eq $index) { Note "MISSING  the first monitor is not in the server's list"; exit 1 }
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "server.wlog"
$server = Start-Process -FilePath "$HostDir\freerdp-shadow-cli.exe" -PassThru -NoNewWindow `
    -ArgumentList "/bind-address:127.0.0.1", "/port:$port", "/gfx-av1", "/gfx-av2:off", "/monitors:$index"
[void](Until 30 { (Listening $port) -or $server.HasExited })
Note "INFO  server shares monitor $index only; listens on 127.0.0.1:${port}: $(Listening $port)"

# ---- the native client, 1600 x 900 (the shared monitor at 1:1), centred on the second monitor
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "native.wlog"
$client = Start-Process -FilePath "$ClientDir\sdl-freerdp.exe" -PassThru -ArgumentList "/v:127.0.0.1:$port",
    "/u:$user", "/p:$pass", "/cert:ignore", "/gfx:AV2:off,AV1:i420", "/size:1600x900"
$h = [IntPtr]::Zero
[void](Until 30 { $client.Refresh(); $script:h = $client.MainWindowHandle; ($script:h -ne [IntPtr]::Zero) -or $client.HasExited })
Start-Sleep -Seconds 5
$rect = $null
if ($h -ne [IntPtr]::Zero) {
    $r = New-Object Kit.Screen+RECT
    [void][Kit.Screen]::GetWindowRect($h, [ref]$r)
    $x = $second.X + [math]::Max(0, [int](($second.W - ($r.Right - $r.Left)) / 2))
    $y = $second.Y + [math]::Max(0, [int](($second.H - ($r.Bottom - $r.Top)) / 2))
    [Kit.Screen]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, 0, 0, 0x0041) | Out-Null   # SWP_NOSIZE | SWP_SHOWWINDOW
    Start-Sleep -Seconds 2
    if ([Kit.Screen]::GetWindowRect($h, [ref]$r)) { $rect = $r }
}
Note "INFO  native: window $(if ($rect) { "$($rect.Left),$($rect.Top) to $($rect.Right),$($rect.Bottom)" } else { 'unknown' }); title '$($client.MainWindowTitle)'"
$off = (Get-Item "$Out\server.wlog").Length

# ---- the recording: the client's window on the second monitor (gdigrab, 30/s asked)
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
Stop $browser
Stop $site

# ---- the session's rate: the server's AV1 encoder lines while the recording ran
$fs = [System.IO.File]::Open("$Out\server.wlog", "Open", "Read", "ReadWrite")
$fs.Seek($off, "Begin") | Out-Null
$tail = (New-Object System.IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
Set-Content -Encoding utf8 -Path "$Out\native-server.wlog" -Value $tail
$lines = @([regex]::Matches($tail, "AV1 [0-9]+x[0-9]+ I4[24][04]: [0-9]+ frames in [0-9.]+ s \(([0-9.]+) fps\)[^\r\n]*") |
    ForEach-Object { $_.Value })
$lines | ForEach-Object { Note "INFO  native: server $_" }
$fps = @($lines | ForEach-Object { [double]([regex]::Match($_, "\(([0-9.]+) fps\)").Groups[1].Value) })
$mean = if ($fps.Count) { ($fps | Measure-Object -Average).Average } else { 0 }
if ($fps.Count) {
    Note ("NATIVE-VERDICT  {0}/s (the server encoded a mean {1:N1} fps over {2} lines)" -f $(if ($mean -ge 15) { ">= 15" } else { "< 15" }), $mean, $fps.Count)
} else { Note "NATIVE-VERDICT  unknown (no AV1 encoder line in this session)" }
$caps = Select-String -Path "$Out\native.wlog" -Pattern "RecvCapsConfirmPdu: version: \S+.*" -ErrorAction SilentlyContinue | Select-Object -Last 1
Note "INFO  native: caps $(if ($caps) { $caps.Matches[0].Value } else { 'none' })"
$dec = Select-String -Path "$Out\native.wlog" -Pattern "AV1 decoder: (\S+) \(([^,)]+)" -ErrorAction SilentlyContinue | Select-Object -Last 1
Note "INFO  native: decoder $(if ($dec) { $dec.Line.Trim() } else { 'not logged' })"
# (the AV1 context's "AV1 encoder requires libaom" is the client making no encoder: not a failure)
$failed = @(Select-String -Path "$Out\native.wlog" -Pattern "\[ERROR\].*(decode|av1|gfx)" -ErrorAction SilentlyContinue |
    Where-Object { $_.Line -notmatch "AV1 encoder requires libaom" }).Count
Note "INFO  native: client errors about decode/AV1/GFX: $failed"

# ---- the video: 1280 x 720, the label from the session's own words, a poster and two stills
$V = "$Out\native-av1-i420.mp4"
if (Test-Path $raw) {
    $n = & ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 $raw
    $len = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $raw)
    $written = if ($len) { $n / $len } else { 0 }
    Note ("INFO  native: the recording: $n frames in {0:N1} s ({1:N1} fps written; the session {2:N1})" -f $len, $written, $mean)
    Note ("WRITTEN-VERDICT  {0}" -f $(if ($written -ge $mean) { "written >= session" } else { "written < session" }))
    $decoder = if ($dec) { "$($dec.Matches[0].Groups[1].Value) ($($dec.Matches[0].Groups[2].Value))" } else { "decoder unknown" }
    $label = "AV1 4:2:0 · $decoder · $([math]::Round($mean))/s"
    Note "INFO  label: $label"
    Set-Content -Encoding utf8NoBOM -Path "$env:RUNNER_TEMP\label.txt" -Value $label -NoNewline
    Copy-Item "$env:SystemRoot\Fonts\segoeui.ttf" "$env:RUNNER_TEMP\font.ttf"
    Push-Location $env:RUNNER_TEMP   # relative paths: no drive colon inside the filter
    & ffmpeg -v error -y -i $raw -vf ("scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos," +
        "pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p," +
        "drawtext=fontfile=font.ttf:textfile=label.txt:expansion=none:fontsize=22:fontcolor=white:" +
        "box=1:boxcolor=black@0.6:boxborderw=10:x=w-tw-28:y=h-th-72") `
        -c:v libx264 -crf 28 -preset slow -an -movflags +faststart $V
    Pop-Location
    foreach ($s in @(@("", 0.7), @("-mid", 0.5), @("-late", 0.95))) {
        & ffmpeg -v error -y -ss ("{0:F2}" -f ($len * $s[1])) -i $V -frames:v 1 -q:v 4 "$Out\native-av1-i420$($s[0]).jpg"
    }
} else { Note "MISSING  native: no recording ($((Get-Content "$Out\record.log" -Tail 1) -join ''))" }
Remove-LocalUser -Name $user -ErrorAction SilentlyContinue
# the demo's bar (the product owner's): the server's mean at least 15/s, the recorder at least
# the session's rate, no decode/AV1/GFX failure, the shared monitor 1600 x 900 (checked above)
$demoOk = (Test-Path $V) -and $fps.Count -and ($mean -ge 15) -and ($written -ge $mean) -and ($failed -eq 0)
if ($demoOk) {
    Copy-Item $V "$Out\windows-native.mp4"
    Copy-Item "$Out\native-av1-i420.jpg" "$Out\windows-native.jpg"
    Note "DEMO  windows-native: in (mean $([math]::Round($mean, 1))/s, written $([math]::Round($written, 1))/s)"
} else {
    Note "DEMO  windows-native: left out (mean $([math]::Round($mean, 1))/s, written $([math]::Round($written, 1))/s, failures $failed)"
}
Get-Content "$Out\verdicts.txt"

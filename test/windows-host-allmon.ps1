# The Windows host with two monitors (freerdp-comp-shadow-g6, 2026-11-25): FreeRDP's shadow
# server shares every monitor on Windows (FreeRDP feature-shadow-allmon: a DXGI duplication per
# output, on that output's own adapter; a GFX surface per monitor; the pointer over the virtual
# desktop; a new layout of the same size resets the clients). The runner has one monitor; an
# IddCx virtual display driver adds the second while a session runs (VirtualDrivers/
# Virtual-Display-Driver, MIT, release 25.7.23, pinned by SHA256: probe-iddcx run 45666679353
# proved the install and DXGI capture of both outputs on windows-2025 x64).
#
# Every line below is a check (PASS/FAIL into checks.txt), and the job fails on any FAIL:
#   1. the driver: its signer trusted before pnputil (else the driver prompt hangs the job),
#      the device node made, a second monitor (SM_CMONITORS 2)
#   2. the monitor added during a session: the server sees 2 monitors, duplicates both
#      outputs, the client gets a Reset Graphics with 2 monitors and holds
#   3. a picture on each monitor: a coloured window on each, seen in the client's window
#   4. the pointer on each monitor: A, the server gets the point the client meant, exactly;
#      B, the pointer then sits on the server's last point (GetCursorPos, 0 px), at least once on
#      each monitor; a click reaches the server and the window under the pointer. The release
#      client keeps its window at the primary's size and scales the desktop into it, and SDL
#      follows a posted move with motions at the real pointer (runs 45692504667, 45696683442:
#      the server got x=1423, then the echoes x=1822), so B is measured against what the server
#      got last, not against the posted point. The echo is where the real pointer was when SDL
#      took the posted move (run 45714503610: 1822,487 after every post), seen through the
#      client's scaled window. So the real pointer is first put on a preset point of the monitor
#      whose echo lands elsewhere on that monitor, and B also needs the pointer to have moved
#      from where it was just before the post: the server must have put it there
#   5. the second monitor moved to the other side, the same total size: a new Reset Graphics
#      with the new place, and the pointer still lands right
#  5b. (freerdp-comp-sdl-g3, phase 2 of all monitors) a /multimon client: with its own layout the
#      server's list is the layout it sent ("no follow (same as sent)"); asking for half-size
#      monitors (/sdl-hidpi:scale:50) it follows the server's list: a window per server monitor on
#      that monitor, its picture, 0 failed frames, the server gets each point (where the pointer
#      settles after the post is recorded as data first, see 5b)
#   6. Ctrl+Alt+Del and the lock screen with both monitors: the server follows to Winlogon,
#      duplicates both outputs again, the session holds
# Everything listens on 127.0.0.1 only. The machine is thrown away afterwards.
#
#   windows-host-allmon.ps1 <host dir> <client dir> <out> <driver zip> <its sha256> <devnode.exe>
param([string]$HostDir, [string]$ClientDir, [string]$Out, [string]$VddZip, [string]$VddSha256, [string]$DevNode)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$HostDir = (Resolve-Path $HostDir).Path
$ClientDir = (Resolve-Path $ClientDir).Path
$Out = (Resolve-Path $Out).Path
$DevNode = (Resolve-Path $DevNode).Path
$user = "kit"
$pass = "Shadow-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$port = 4497
$fails = 0
function Check($name, $ok, $detail = "") {
    $word = if ($ok) { "PASS" } else { "FAIL" }
    if (-not $ok) { $script:fails++ }
    "$word  $name$(if ($detail) { "  ($detail)" })" | Tee-Object -FilePath "$Out\checks.txt" -Append
}
function Note($line) { $line | Tee-Object -FilePath "$Out\notes.txt" -Append }
function Shot($name) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
        $bmp.Save("$Out\$name.png")
    } catch { Note "screenshot ${name}: $($_.Exception.Message)" }
}
function Listening($p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }
function Stop($p) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 2
}
function Until([int]$seconds, [scriptblock]$cond) {
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 500 }
    return [bool](& $cond)
}

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Kit -Name Win -MemberDefinition @'
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
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, System.IntPtr hwnd, int flags, System.IntPtr param);
[DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")] static extern int ChangeDisplaySettingsExApply(System.IntPtr dev, System.IntPtr dm, System.IntPtr hwnd, int flags, System.IntPtr param);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr dc, uint flags);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
public static string Size(int w, int h) {
    DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) return "the current mode is unknown";
    string was = dm.dmPelsWidth + " x " + dm.dmPelsHeight;
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x80000 | 0x100000;   // DM_PELSWIDTH | DM_PELSHEIGHT
    return was + " -> " + w + " x " + h + ": " + ChangeDisplaySettings(ref dm, 0);
}
// a display's place on the virtual desktop: CDS_UPDATEREGISTRY | CDS_NORESET for the device, then
// one apply for all; 0 = DISP_CHANGE_SUCCESSFUL
public static string Move(string dev, int x, int y) {
    DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(dev, -1, ref dm)) return "the mode of " + dev + " is unknown";
    dm.dmPositionX = x; dm.dmPositionY = y; dm.dmFields = 0x20;   // DM_POSITION
    int set = ChangeDisplaySettingsEx(dev, ref dm, System.IntPtr.Zero, 0x01 | 0x10000000, System.IntPtr.Zero);
    int apply = ChangeDisplaySettingsExApply(System.IntPtr.Zero, System.IntPtr.Zero, System.IntPtr.Zero, 0, System.IntPtr.Zero);
    return "set " + set + ", apply " + apply;
}
'@
# the client area of a window as it draws it (PW_CLIENTONLY | PW_RENDERFULLCONTENT): what the
# client shows, whatever window is in front of it
function ClientPicture($h) {
    $r = New-Object Kit.Win+RECT
    if (-not [Kit.Win]::GetClientRect($h, [ref]$r) -or $r.Right -le 0 -or $r.Bottom -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap $r.Right, $r.Bottom
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc()
    $ok = [Kit.Win]::PrintWindow($h, $dc, 0x3)
    $g.ReleaseHdc($dc); $g.Dispose()
    if (-not $ok) { $bmp.Dispose(); return $null }
    $bmp
}
function Cursor { $p = New-Object Kit.Win+POINT; [void][Kit.Win]::GetCursorPos([ref]$p); $p }
function MonitorCount { [Kit.Win]::GetSystemMetrics(80) }   # SM_CMONITORS
# the monitors, from a new process each time (Screen.AllScreens caches its list in a process)
function Screens {
    $json = pwsh -NoProfile -Command 'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { [pscustomobject]@{ Device = $_.DeviceName; Primary = $_.Primary; X = $_.Bounds.X; Y = $_.Bounds.Y; W = $_.Bounds.Width; H = $_.Bounds.Height } } | ConvertTo-Json -Compress'
    @($json | ConvertFrom-Json)
}
function Box($screens) {
    $l = ($screens | Measure-Object X -Minimum).Minimum; $t = ($screens | Measure-Object Y -Minimum).Minimum
    $r = ($screens | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
    $b = ($screens | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum
    [pscustomobject]@{ X = $l; Y = $t; W = $r - $l; H = $b - $t }
}

"screen: $([Kit.Win]::Size(1600, 900))" | Tee-Object -FilePath "$Out\where.txt"
$console = (Get-Process -Id $PID).SessionId
"session of this job: $console; os $([Environment]::OSVersion.VersionString)" | Tee-Object -FilePath "$Out\where.txt" -Append
try {
    New-LocalUser -Name $user -Password (ConvertTo-SecureString $pass -AsPlainText -Force) -PasswordNeverExpires | Out-Null
    Check "a local Windows user for the test" $true
} catch { Check "a local Windows user for the test" $false $_.Exception.Message }

$env:WLOG_LEVEL = "DEBUG"
$env:WLOG_APPENDER = "FILE"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out
function ClientLog { Get-Content "$Out\session.wlog" -ErrorAction SilentlyContinue }
# the Reset Graphics PDUs the client took: width, height, count and the monitor lines after each
function Resets {
    $resets = @(); $cur = $null
    foreach ($l in (ClientLog)) {
        if ($l -match "RecvResetGraphicsPdu: width: (\d+) height: (\d+) count: (\d+)") {
            $cur = [pscustomobject]@{ W = [int]$Matches[1]; H = [int]$Matches[2]; Count = [int]$Matches[3]; Monitors = New-Object System.Collections.ArrayList }
            $resets += $cur
        } elseif ($cur -and ($l -match "RecvResetGraphicsPdu: monitor left:(-?\d+) top:(-?\d+) right:(-?\d+) bottom:(-?\d+) flags:0x(\w+)")) {
            [void]$cur.Monitors.Add("$($Matches[1]),$($Matches[2]),$($Matches[3]),$($Matches[4]),$($Matches[5])")
        }
    }
    $resets
}
# surface commands per surface since a line number of the client's log
function SurfaceCommands([int]$from = 0) {
    $lines = @(ClientLog)
    $lines[$from..($lines.Count - 1)] | Where-Object { $_ -match "RecvWireToSurface1Pdu: surfaceId: (\d+) " } |
        ForEach-Object { [void]($_ -match "surfaceId: (\d+) "); $Matches[1] } | Group-Object | ForEach-Object { [pscustomobject]@{ Surface = $_.Name; Count = $_.Count } }
}

# ---- 1. the service, on one monitor (the runner's own)
$logs = "$Out\service"
& "$HostDir\freerdp-shadow-service.exe" install --log $logs --allow-sas -- `
    /bind-address:127.0.0.1 /port:$port /gfx-av1 /gfx-av2:off /log-level:DEBUG 2>&1 | Tee-Object "$Out\install.txt"
Check "service: install" ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
[void](Until 30 { Listening $port })
Check "service: the server listens on 127.0.0.1:$port" (Listening $port)
function ServerLog { (Get-ChildItem "$logs\shadow-*.log" -ErrorAction SilentlyContinue | Get-Content) -join "`n" }
function Count($pattern) { ([regex]::Matches((ServerLog), $pattern)).Count }
# the outputs duplicated since the last line matching $marker: their distinct places
# ("duplicating output <n> (<w>x<h> at <x>,<y>, ...)"); a refresh duplicates them again, so
# lines are not counted, places are
function DuplicatedSince($marker) {
    $log = ServerLog
    $m = [regex]::Matches($log, $marker)
    $from = if ($m.Count) { $m[$m.Count - 1].Index } else { 0 }
    @([regex]::Matches($log.Substring($from), "duplicating output \d+ \((\d+x\d+ at -?\d+,-?\d+)") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}
Check "one monitor at the start" ((MonitorCount) -eq 1) "SM_CMONITORS $(MonitorCount)"
(New-Object -ComObject Shell.Application).MinimizeAll()

# the client: unscaled (it takes the server's size on each Reset Graphics), later placed with its
# client area over the virtual desktop; the surface commands and Reset Graphics monitors at TRACE
# (a function: 5b ends this session and starts another for 6)
function StartSession {
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "session.wlog"
    $env:WLOG_FILTER = "com.freerdp.channels.rdpgfx.client:TRACE"
    $p = Start-Process -FilePath "$ClientDir\sdl-freerdp.exe" -PassThru -ArgumentList `
        "/v:127.0.0.1:$port", "/u:$user", "/p:$pass", "/cert:ignore", "/gfx:AV1:on"
    Remove-Item Env:\WLOG_FILTER
    $p
}
$session = StartSession
[void](Until 30 { @(Resets).Count -ge 1 })
Start-Sleep -Seconds 5
$first = @(Resets) | Select-Object -First 1
Check "one monitor: the client got a Reset Graphics with 1 monitor" ($first -and $first.Count -eq 1) "$(if ($first) { "$($first.W)x$($first.H) count $($first.Count)" } else { 'none' })"
Check "one monitor: the session holds" (-not $session.HasExited)

# ---- 2. the second monitor, during the session
$actual = (Get-FileHash -Algorithm SHA256 -Path $VddZip).Hash.ToLowerInvariant()
Check "driver: the pinned package" ($actual -eq $VddSha256.ToLowerInvariant()) $actual
$pkg = "$Out\driver"
Expand-Archive -Path $VddZip -DestinationPath $pkg -Force
$inf = Get-ChildItem -Path $pkg -Recurse -Filter 'MttVDD.inf' | Select-Object -First 1
New-Item -ItemType Directory -Force -Path 'C:\VirtualDisplayDriver' | Out-Null
Copy-Item -Path (Join-Path $inf.DirectoryName 'vdd_settings.xml') -Destination 'C:\VirtualDisplayDriver\vdd_settings.xml' -Force
# the signer trusted first: pnputil waits on Windows' driver prompt otherwise (probe-iddcx run 45653105707)
$cert = (Get-AuthenticodeSignature -FilePath (Join-Path $inf.DirectoryName 'mttvdd.cat')).SignerCertificate
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
$store.Open('ReadWrite'); $store.Add($cert); $store.Close()
Note "driver signer $($cert.Subject) $($cert.Thumbprint)"
function Bounded([string]$name, [string]$exe, [string[]]$arguments, [int]$seconds) {
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput "$Out\$name.txt" -RedirectStandardError "$Out\$name.err.txt"
    if ($p.WaitForExit($seconds * 1000)) { return $p.ExitCode }
    Shot "hang-$name"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    return "timeout ${seconds}s"
}
$rc = Bounded 'pnputil' 'pnputil.exe' @('/add-driver', $inf.FullName, '/install') 120
Check "driver: pnputil installs it" ($rc -eq 0) "rc $rc"
$rc = Bounded 'devnode' $DevNode @($inf.FullName, 'Root\MttVDD', 'Display') 120
Check "driver: the device node" ($rc -eq 0) "rc $rc"
[void](Until 30 { (MonitorCount) -ge 2 })
$screens = Screens
$screens | Format-Table | Out-File -Append "$Out\where.txt"
Check "driver: a second monitor" ((MonitorCount) -eq 2) "SM_CMONITORS $(MonitorCount); $(($screens | ForEach-Object { "$($_.Device) $($_.W)x$($_.H)+$($_.X)+$($_.Y)$(if ($_.Primary) { ' primary' })" }) -join '; ')"
$second = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
$box = Box $screens
function Finish {
    Stop $session
    if ($script:m2win) { Stop $script:m2win }
    if ($script:pwin) { Stop $script:pwin }
    & "$HostDir\freerdp-shadow-service.exe" uninstall 2>&1 | Tee-Object -Append "$Out\install.txt"
    Remove-LocalUser -Name $user -ErrorAction SilentlyContinue
    (ServerLog) -split "`n" | Select-String -Pattern "desktop changed|  monitor \d+:|output \d+:|duplicating output|layout changed|refused|no longer|capture (paused|resumed)|AV1 \d+x\d+" |
        ForEach-Object { $_.Line } | Out-File "$Out\server-monitors.txt"
    Get-Content "$Out\checks.txt"
    exit $(if ($script:fails) { 1 } else { 0 })
}
# without a second monitor nothing below can run: the checks so far say why
if (-not $second) { Finish }

[void](Until 30 { (ServerLog) -match "desktop changed: 2 monitor\(s\)" })
Check "added: the server sees 2 monitors" ((ServerLog) -match "desktop changed: 2 monitor\(s\), sharing $($box.W)x$($box.H)") "box $($box.W)x$($box.H)"
[void](Until 20 { @(DuplicatedSince "desktop changed: 2 monitor").Count -ge 2 })
$places = DuplicatedSince "desktop changed: 2 monitor"
Check "added: the server duplicates both outputs" ($places.Count -ge 2) "$($places -join '; ')"
[void](Until 30 { @(Resets | Where-Object { $_.Count -eq 2 }).Count -ge 1 })
$two = @(Resets | Where-Object { $_.Count -eq 2 }) | Select-Object -Last 1
Check "added: the client got a Reset Graphics with 2 monitors" ($two -and $two.W -eq $box.W -and $two.H -eq $box.H) "$(if ($two) { "$($two.W)x$($two.H): $($two.Monitors -join ' | ')" } else { 'none' })"
Start-Sleep -Seconds 3
Check "added: the session holds" (-not $session.HasExited)
Shot "two-monitors"

# ---- 3. a picture on each monitor: a coloured window on each, as the client shows them
$session.Refresh()
$hwnd = $session.MainWindowHandle
# the client's client area at the top left of the virtual desktop, 1:1 (it covers both monitors;
# the coloured windows below stay in front of it)
function Place($b) {
    Start-Sleep -Seconds 2
    $wr = New-Object Kit.Win+RECT; [void][Kit.Win]::GetWindowRect($hwnd, [ref]$wr)
    $o = New-Object Kit.Win+POINT; [void][Kit.Win]::ClientToScreen($hwnd, [ref]$o)
    [void][Kit.Win]::SetWindowPos($hwnd, [IntPtr]::Zero, $b.X - ($o.X - $wr.Left), $b.Y - ($o.Y - $wr.Top), 0, 0, 0x0001 -bor 0x0004 -bor 0x0010)   # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
    Start-Sleep -Milliseconds 500
    $o = New-Object Kit.Win+POINT; [void][Kit.Win]::ClientToScreen($hwnd, [ref]$o)
    $c = New-Object Kit.Win+RECT; [void][Kit.Win]::GetClientRect($hwnd, [ref]$c)
    [pscustomobject]@{ X = $o.X; Y = $o.Y; W = $c.Right; H = $c.Bottom }
}
$at = Place $box
$cr = New-Object Kit.Win+RECT; [void][Kit.Win]::GetClientRect($hwnd, [ref]$cr)
Note "client area $($at.W)x$($at.H) at $($at.X),$($at.Y), desktop $($box.W)x$($box.H) at $($box.X),$($box.Y)"
$prim = $screens | Where-Object { $_.Primary } | Select-Object -First 1
# a window that logs each click (screen point) and closes after $life seconds
function ColourWindow([string]$name, [int]$x, [int]$y, [int]$w, [int]$h, [string]$colour, [int]$life) {
    $script = @"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
`$f = New-Object System.Windows.Forms.Form
`$f.FormBorderStyle = 'None'; `$f.StartPosition = 'Manual'; `$f.TopMost = `$true; `$f.ShowInTaskbar = `$false
`$f.Bounds = New-Object System.Drawing.Rectangle $x, $y, $w, $h
`$f.BackColor = [System.Drawing.Color]::$colour
`$f.Add_MouseDown({ Add-Content -Path '$Out\click-$name.txt' -Value ("{0},{1}" -f [System.Windows.Forms.Cursor]::Position.X, [System.Windows.Forms.Cursor]::Position.Y) })
`$t = New-Object System.Windows.Forms.Timer; `$t.Interval = $($life * 1000); `$t.Add_Tick({ `$f.Close() }); `$t.Start()
[System.Windows.Forms.Application]::Run(`$f)
"@
    # -EncodedCommand: Start-Process joins its arguments without quoting them (run 45692504667's
    # "{0},{1}" arrived as two script blocks)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile", "-EncodedCommand", $encoded
}
$before = @(ClientLog).Count
$m2win = ColourWindow "second" $second.X $second.Y $second.W $second.H "Magenta" 240
# the primary's at its left edge, in the middle: where its pointer check is aimed (see 4)
$pwin = ColourWindow "primary" $prim.X ($prim.Y + [int]($prim.H / 2) - 100) 200 200 "Cyan" 240
Start-Sleep -Seconds 6
# a point of the desktop in the client's window (the box scaled into the client area: 1:1 here)
function InClient($vx, $vy) {
    [pscustomobject]@{ X = [int][math]::Floor(($vx - $box.X) * $cr.Right / $box.W); Y = [int][math]::Floor(($vy - $box.Y) * $cr.Bottom / $box.H) }
}
function Colour($bmp, $p) {
    $sum = @(0, 0, 0); $n = 0
    for ($dx = -4; $dx -le 4; $dx++) { for ($dy = -4; $dy -le 4; $dy++) {
        $c = $bmp.GetPixel([math]::Min($bmp.Width - 1, [math]::Max(0, $p.X + $dx)), [math]::Min($bmp.Height - 1, [math]::Max(0, $p.Y + $dy)))
        $sum[0] += $c.R; $sum[1] += $c.G; $sum[2] += $c.B; $n++ } }
    "{0},{1},{2}" -f [int]($sum[0] / $n), [int]($sum[1] / $n), [int]($sum[2] / $n)
}
function Near($rgb, [int[]]$want) { $c = $rgb -split ','; (0..2 | Where-Object { [math]::Abs([int]$c[$_] - $want[$_]) -gt 48 }).Count -eq 0 }
$m2c = InClient ($second.X + [int]($second.W / 2)) ($second.Y + [int]($second.H / 2))
$pc = InClient ($prim.X + 100) ($prim.Y + [int]($prim.H / 2))
$seen = $false
for ($i = 0; $i -lt 20 -and -not $seen; $i++) {
    Start-Sleep -Seconds 1
    $bmp = ClientPicture $hwnd
    if ($bmp) {
        $m2rgb = Colour $bmp $m2c; $prgb = Colour $bmp $pc
        $seen = (Near $m2rgb @(255, 0, 255)) -and (Near $prgb @(0, 255, 255))
        if ($seen -or $i -eq 19) { $bmp.Save("$Out\client-window.png") }
        $bmp.Dispose()
    }
}
Check "picture: the second monitor's window in the client" (Near $m2rgb @(255, 0, 255)) "rgb $m2rgb at client $($m2c.X),$($m2c.Y), want magenta"
Check "picture: the primary's window in the client" (Near $prgb @(0, 255, 255)) "rgb $prgb at client $($pc.X),$($pc.Y), want cyan"
$cmds = @(SurfaceCommands $before)
Check "picture: frames on both monitors' surfaces" ($cmds.Count -ge 2) "$(($cmds | ForEach-Object { "surface $($_.Surface) x$($_.Count)" }) -join ', ')"
# (the client's "AV1 encoder requires libaom" at start is about an encoder it never uses)
$bad = @(ClientLog | Where-Object { ($_ -match "\[ERROR\]\[com\.freerdp\.(channels\.rdpgfx|gdi|codec)") -and ($_ -notmatch "encoder requires") })
Check "picture: no decoder error in the client" ($bad.Count -eq 0) "$($bad.Count) lines$(if ($bad) { ': ' + $bad[0] })"
Shot "pictures"

# ---- 4. a click on each monitor: posted to the client's window (as the keys are in windows-host.ps1),
# the client sends the point, the server moves the pointer there (MOUSEEVENTF_VIRTUALDESK)
function PostMouse([int]$msg, [int]$wparam, $p) {
    [long]$l = ([long]$p.Y -shl 16) -bor ([long]$p.X -band 0xFFFF)
    [void][Kit.Win]::PostMessage($hwnd, [uint32]$msg, [IntPtr]$wparam, [IntPtr]$l)
}
# the desktop point a client point stands for: the box scaled back (the client's own mapping)
function OnDesktop($p) {
    [pscustomobject]@{ X = $box.X + [int][math]::Floor($p.X * $box.W / $cr.Right); Y = $box.Y + [int][math]::Floor($p.Y * $box.H / $cr.Bottom) }
}
# the server's mouse events, in order: flags and the point in the shared surface (the box)
function MouseEvents {
    [regex]::Matches((ServerLog), "shadow_input_mouse_event\]: \[use\] flags=0x([0-9A-Fa-f]+), x=(\d+), y=(\d+)") |
        ForEach-Object { [pscustomobject]@{ Flags = $_.Groups[1].Value.ToLowerInvariant(); X = [int]$_.Groups[2].Value; Y = [int]$_.Groups[3].Value } }
}
# until the server took no mouse event for a second (the client's echoes settle), at most 10 s
function Quiet {
    $n = @(MouseEvents).Count
    for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Seconds 1; $m = @(MouseEvents).Count; if ($m -eq $n) { return }; $n = $m }
}
function MonitorAt($p, $list) {
    $hit = $list | Where-Object { ($p.X -ge $_.X) -and ($p.X -lt $_.X + $_.W) -and ($p.Y -ge $_.Y) -and ($p.Y -lt $_.Y + $_.H) } | Select-Object -First 1
    if (-not $hit) { "none" } elseif ($hit.Primary) { "primary" } else { "second" }
}
$script:onMonitor = @()
# where the client's echo of a real pointer at $p is expected (🔎 runs 1-3): its place in the
# client area, scaled back to the desktop as the client maps it, kept inside the desktop
function EchoOf($p) {
    $l = [pscustomobject]@{ X = $p.X - $at.X; Y = $p.Y - $at.Y }
    $d = OnDesktop $l
    [pscustomobject]@{ X = [math]::Min($box.X + $box.W - 2, [math]::Max($box.X, $d.X)); Y = [math]::Min($box.Y + $box.H - 1, [math]::Max($box.Y, $d.Y)) }
}
function Point([string]$name, $q, $list, $preset, [switch]$Click) {
    $want = OnDesktop $q
    $tx = $want.X - $box.X; $ty = $want.Y - $box.Y
    # the real pointer on the preset point first, then quiet: the pointer before the post
    [void][Kit.Win]::SetCursorPos($preset.X, $preset.Y)
    Quiet
    $pre = Cursor
    $echo = EchoOf $pre
    $from = @(MouseEvents).Count
    PostMouse 0x0200 0 $q   # WM_MOUSEMOVE
    [void](Until 5 { @(MouseEvents | Select-Object -Skip $from | Where-Object { $_.X -eq $tx -and $_.Y -eq $ty }).Count -ge 1 })
    $after = @(MouseEvents | Select-Object -Skip $from)
    Check "pointer A: $name, the server got the point" (@($after | Where-Object { $_.X -eq $tx -and $_.Y -eq $ty }).Count -ge 1) "want $tx,$ty; the server got $(($after | Select-Object -First 6 | ForEach-Object { "$($_.X),$($_.Y)" }) -join ' ')" | Out-Host
    Quiet
    $last = @(MouseEvents) | Select-Object -Last 1
    $got = Cursor
    $ex = $box.X + $last.X; $ey = $box.Y + $last.Y
    $mon = MonitorAt $got $list
    # on the server's last point, and moved there from where it was: the server put it there
    $ok = ($got.X -eq $ex) -and ($got.Y -eq $ey) -and (($got.X -ne $pre.X) -or ($got.Y -ne $pre.Y))
    if ($ok) { $script:onMonitor += $mon }
    Check "pointer B: $name, the server moved the pointer to its last point" $ok "before $($pre.X),$($pre.Y); server $($last.X),$($last.Y) + box $($box.X),$($box.Y) = $ex,$ey; pointer $($got.X),$($got.Y) on the $mon monitor (echo expected at $($echo.X),$($echo.Y))" | Out-Host
    if ($Click) {
        $from = @(MouseEvents).Count
        PostMouse 0x0201 1 $q   # WM_LBUTTONDOWN, MK_LBUTTON
        Start-Sleep -Milliseconds 200
        PostMouse 0x0202 0 $q   # WM_LBUTTONUP
        # PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1 = 0x9000, PTR_FLAGS_BUTTON1 = 0x1000
        [void](Until 5 { $f = @(MouseEvents | Select-Object -Skip $from | ForEach-Object { $_.Flags }); ($f -contains "9000") -and ($f -contains "1000") })
        $f = @(MouseEvents | Select-Object -Skip $from | ForEach-Object { $_.Flags })
        Check "click: $name, the server got the button down and up" (($f -contains "9000") -and ($f -contains "1000")) "flags $($f -join ' ')" | Out-Host
        Quiet
        $at = Cursor
        $file = if ((MonitorAt $at $list) -eq "primary") { "$Out\click-primary.txt" } else { "$Out\click-second.txt" }
        [void](Until 5 { (Test-Path $file) -and ((Get-Content $file) -contains "$($at.X),$($at.Y)") })
        $logged = if (Test-Path $file) { (Get-Content $file) -join ' ' } else { "" }
        Check "click: $name, the window under the pointer got it there" ((Test-Path $file) -and ((Get-Content $file) -contains "$($at.X),$($at.Y)")) "pointer $($at.X),$($at.Y) on the $(MonitorAt $at $list) monitor; $(Split-Path $file -Leaf): $logged" | Out-Host
    }
}
# presets: a point of each monitor whose echo lands elsewhere on that monitor
$p2 = [pscustomobject]@{ X = $second.X + 76; Y = $second.Y + [int]($second.H / 2) }
$pp = [pscustomobject]@{ X = $prim.X + 100; Y = $prim.Y + [int]($prim.H / 2) }
Point "on the second monitor" $m2c $screens $p2 -Click
Point "on the primary monitor" $pc $screens $pp -Click

# ---- 5. the second monitor to the other side of the primary: the same box, another layout
$resetsBefore = @(Resets).Count
$layoutBefore = Count "the monitor layout changed, the size did not"
$newX = $prim.X - $second.W
Note "move $($second.Device) to $newX,$($second.Y): $([Kit.Win]::Move($second.Device, $newX, $second.Y))"
[void](Until 30 { @(Resets).Count -gt $resetsBefore })
$screens2 = Screens
$screens2 | Format-Table | Out-File -Append "$Out\where.txt"
$box2 = Box $screens2
$second2 = $screens2 | Where-Object { -not $_.Primary } | Select-Object -First 1
Check "moved: the same total size" (($box2.W -eq $box.W) -and ($box2.H -eq $box.H)) "box $($box.W)x$($box.H)+$($box.X)+$($box.Y) -> $($box2.W)x$($box2.H)+$($box2.X)+$($box2.Y)"
Check "moved: the server reset the client for the new layout" ((Count "the monitor layout changed, the size did not") -gt $layoutBefore)
$last = @(Resets) | Select-Object -Last 1
$wantLeft = $second2.X - $prim.X
Check "moved: a new Reset Graphics with the new place" ((@(Resets).Count -gt $resetsBefore) -and $last.Count -eq 2 -and (($last.Monitors -join ' ') -match "(^| )$wantLeft,")) "$(if ($last) { "$($last.W)x$($last.H): $($last.Monitors -join ' | ')" }), want a monitor at left $wantLeft"
$box = $box2
$at = Place $box
Note "client area after the move: $($at.W)x$($at.H) at $($at.X),$($at.Y)"
$m2c2 = InClient ($second2.X + [int]($second2.W / 2)) ($second2.Y + [int]($second2.H / 2))
Point "on the moved second monitor" $m2c2 $screens2 ([pscustomobject]@{ X = $second2.X + 100; Y = $second2.Y + [int]($second2.H / 2) })
Check "pointer B: on each monitor at least once" (($script:onMonitor -contains "primary") -and ($script:onMonitor -contains "second")) "where B held: $(if ($script:onMonitor) { $script:onMonitor -join ', ' } else { 'nowhere' })"
Check "moved: the session holds" (-not $session.HasExited)
Shot "moved"

# ---- 5b. /multimon follows the server's monitors (freerdp-comp-sdl-g3, phase 2 of all monitors)
# The client runs on the server's own machine, so its two screens are the server's two monitors:
#   a. plain /multimon sends the layout the server has: "server layout: no follow (same as sent)"
#   b. /multimon /sdl-hidpi:scale:50 asks for half-size monitors, which the shadow does not take:
#      the client follows the server's list, one window per server monitor on that monitor (1:1)
# A full-monitor colour window on each monitor (made after the client's windows, kept topmost) is
# what the server captures there. The pointer's place after a posted move is recorded as data
# (notes), not checked: SDL echoes posted moves, and on a 1:1 window the echo lands on the point it
# came from (g6, runs 45692504667, 45714503610), so this round measures before a gate is designed.
Stop $session
Add-Type -Namespace Kit -Name Mm -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct R { public int Left, Top, Right, Bottom; }
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(P p);
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out R r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
public static System.IntPtr[] Of(uint pid) {
    var list = new System.Collections.Generic.List<System.IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) list.Add(h); return true; }, System.IntPtr.Zero);
    return list.ToArray();
}
public static uint Pid(System.IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
'@
function MmLog($name) { @(Get-Content "$Out\$name.wlog" -ErrorAction SilentlyContinue) }
function MmStart($name, [string[]]$extra) {
    $env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "$name.wlog"
    $env:WLOG_LEVEL = "INFO"
    $p = Start-Process -FilePath "$ClientDir\sdl-freerdp.exe" -PassThru -ArgumentList (@(
        "/v:127.0.0.1:$port", "/u:$user", "/p:$pass", "/cert:ignore", "/gfx:AV1:on", "/multimon",
        "/sdl-stats-ipc:$name") + $extra)
    $env:WLOG_LEVEL = "DEBUG"
    $p
}
# one reading of /sdl-stats-ipc (a named pipe): the next line the client publishes, as JSON
function MmStats($name) {
    $c = New-Object System.IO.Pipes.NamedPipeClientStream(".", $name, [System.IO.Pipes.PipeDirection]::In)
    try {
        $c.Connect(5000)
        $t = (New-Object System.IO.StreamReader($c)).ReadLineAsync()
        if ($t.Wait(5000)) { $t.Result | ConvertFrom-Json } else { $null }
    } catch { $null } finally { $c.Dispose() }
}
# the sum of the counters whose name ends in $suffix; none when no counter has that name (a check
# on it must not pass for want of the counter)
function Counters($stats, $suffix) {
    if (-not $stats) { return $null }
    $sum = 0; $n = 0
    foreach ($p in $stats.counters.PSObject.Properties) { if ($p.Name.EndsWith($suffix)) { $sum += [long]$p.Value; $n++ } }
    if ($n -eq 0) { return $null }
    $sum
}
# the client's visible top-level windows and the monitor each one covers (by rect)
function MmWindows($proc, $list) {
    foreach ($h in [Kit.Mm]::Of([uint32]$proc.Id)) {
        $r = New-Object Kit.Mm+R; [void][Kit.Mm]::GetWindowRect($h, [ref]$r)
        $on = $list | Where-Object { $_.X -eq $r.Left -and $_.Y -eq $r.Top -and $_.W -eq ($r.Right - $r.Left) -and $_.H -eq ($r.Bottom - $r.Top) } | Select-Object -First 1
        [pscustomobject]@{ H = $h; X = $r.Left; Y = $r.Top; W = $r.Right - $r.Left; H2 = $r.Bottom - $r.Top; Monitor = $on }
    }
}
$screens3 = Screens
$box3 = Box $screens3
Note "5b: monitors $(($screens3 | ForEach-Object { "$($_.Device) $($_.W)x$($_.H)+$($_.X)+$($_.Y)$(if ($_.Primary) { ' primary' })" }) -join '; '), box $($box3.W)x$($box3.H)+$($box3.X)+$($box3.Y)"

# a. the client's own layout is the server's
$mmA = MmStart "multimon-same" @()
[void](Until 40 { (MmLog "multimon-same") -match "server layout: (follow|no follow)" })
Start-Sleep -Seconds 3
$dec = @((MmLog "multimon-same") | Where-Object { $_ -match "server layout: (follow|no follow) \(" }) | Select-Object -Last 1
Check "5b a: the server's list is the client's layout" ($dec -match "server layout: no follow \(same as sent\)") "$dec"
$wins = @(MmWindows $mmA $screens3)
Check "5b a: a window on each monitor" (($wins.Count -eq $screens3.Count) -and (@($wins | Where-Object { $_.Monitor }).Count -eq $screens3.Count)) "$(($wins | ForEach-Object { "$($_.W)x$($_.H2)+$($_.X)+$($_.Y)" }) -join '; ')"
$st = MmStats "multimon-same"
Check "5b a: frames, none failed" ($st -and (Counters $st "_PICTURES") -gt 0 -and ($null -ne (Counters $st "_FAILED")) -and (Counters $st "_FAILED") -eq 0) "pictures $(Counters $st '_PICTURES'), failed $(Counters $st '_FAILED')"
Check "5b a: the session holds" (-not $mmA.HasExited)
Stop $mmA

# b. half-size monitors asked, the server's own followed
$mmB = MmStart "multimon-follow" @("/sdl-hidpi:scale:50")
[void](Until 40 { (MmLog "multimon-follow") -match "server layout: (follow|no follow)" })
Start-Sleep -Seconds 3
$lines = MmLog "multimon-follow"
$dec = @($lines | Where-Object { $_ -match "server layout: (follow|no follow) \(" }) | Select-Object -Last 1
Check "5b b: the client follows the server's monitors" ($dec -match "server layout: follow \(") "$dec"
# the last plan: one line per window (window, monitor, source, display, target, scale)
$plan = @{}
foreach ($l in $lines) {
    if ($l -match "server layout: window (\d+) <- monitor (\d+) (-?\d+),(-?\d+) (\d+)x(\d+) on display (\d+) at (-?\d+),(-?\d+) (\d+)x(\d+) scale ([0-9.]+)") {
        $plan[$Matches[2]] = [pscustomobject]@{ Monitor = [int]$Matches[2]; SX = [int]$Matches[3]; SY = [int]$Matches[4]; SW = [int]$Matches[5]; SH = [int]$Matches[6]
            TX = [int]$Matches[8]; TY = [int]$Matches[9]; TW = [int]$Matches[10]; TH = [int]$Matches[11]; Scale = [double]$Matches[12] }
    }
}
Note "5b b: plan $(($plan.Values | Sort-Object Monitor | ForEach-Object { "monitor $($_.Monitor) $($_.SX),$($_.SY) $($_.SW)x$($_.SH) at $($_.TX),$($_.TY) $($_.TW)x$($_.TH) scale $($_.Scale)" }) -join '; ')"
Check "5b b: a window line per server monitor" ($plan.Count -eq $screens3.Count) "$($plan.Count) of $($screens3.Count)"
$wins = @(MmWindows $mmB $screens3)
Check "5b b: a window on each monitor" (($wins.Count -eq $screens3.Count) -and (@($wins | Where-Object { $_.Monitor }).Count -eq $screens3.Count)) "$(($wins | ForEach-Object { "$($_.W)x$($_.H2)+$($_.X)+$($_.Y)" }) -join '; ')"
# each window shows the server monitor it covers: the session's place of a monitor is its place
# on the virtual desktop less the box's top left
$colours = @{ $true = @("Yellow", @(255, 255, 0)); $false = @("Lime", @(0, 255, 0)) }
$cw = @()
foreach ($s in $screens3) { $cw += ColourWindow "5b-$($s.Primary)" $s.X $s.Y $s.W $s.H $colours[[bool]$s.Primary][0] 300 }
Start-Sleep -Seconds 4
foreach ($s in $screens3) {
    $centre = New-Object Kit.Mm+P; $centre.X = $s.X + [int]($s.W / 2); $centre.Y = $s.Y + [int]($s.H / 2)
    $top = [Kit.Mm]::GetAncestor([Kit.Mm]::WindowFromPoint($centre), 2)
    $topPid = [Kit.Mm]::Pid($top)
    $ours = @($cw | Where-Object { $_.Id -eq $topPid }).Count -gt 0
    if (-not $ours) {
        # keep the colour window in front: HWND_TOPMOST again
        foreach ($p in $cw) { foreach ($h in [Kit.Mm]::Of([uint32]$p.Id)) { [void][Kit.Mm]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010) } }
        Start-Sleep -Seconds 2
        $topPid = [Kit.Mm]::Pid([Kit.Mm]::GetAncestor([Kit.Mm]::WindowFromPoint($centre), 2))
        $ours = @($cw | Where-Object { $_.Id -eq $topPid }).Count -gt 0
    }
    Check "5b b: the colour window in front on $($s.Device)" $ours "window at the centre belongs to pid $topPid"
}
foreach ($w in $wins) {
    $s = $w.Monitor
    if (-not $s) { continue }
    $want = $colours[[bool]$s.Primary]
    $sx = $s.X - $box3.X; $sy = $s.Y - $box3.Y
    $pl = $plan.Values | Where-Object { $_.SX -eq $sx -and $_.SY -eq $sy } | Select-Object -First 1
    Check "5b b: the window on $($s.Device) shows the server monitor at $sx,$sy" ([bool]$pl) "$(if ($pl) { "monitor $($pl.Monitor) $($pl.SW)x$($pl.SH) at $($pl.TX),$($pl.TY) $($pl.TW)x$($pl.TH) scale $($pl.Scale)" } else { 'no plan line for it' })"
    $rgb = $null
    for ($i = 0; $i -lt 15; $i++) {
        $bmp = ClientPicture $w.H
        if ($bmp) {
            $rgb = Colour $bmp ([pscustomobject]@{ X = [int]($bmp.Width / 2); Y = [int]($bmp.Height / 2) })
            $dark = Colour $bmp ([pscustomobject]@{ X = 5; Y = 5 })
            if ((Near $rgb $want[1]) -or $i -eq 14) { $bmp.Save("$Out\5b-window-$($s.Device -replace '[\\.]', '').png") }
            $bmp.Dispose()
            if (Near $rgb $want[1]) { break }
        }
        Start-Sleep -Seconds 1
    }
    Check "5b b: the window on $($s.Device) shows its monitor's picture" (Near $rgb $want[1]) "rgb $rgb at the centre, want $($want[0])"
}
$st = MmStats "multimon-follow"
Check "5b b: frames, none failed" ($st -and (Counters $st "_PICTURES") -gt 0 -and ($null -ne (Counters $st "_FAILED")) -and (Counters $st "_FAILED") -eq 0) "pictures $(Counters $st '_PICTURES'), failed $(Counters $st '_FAILED')"

# the pointer: a move posted to each window, the point the server got (a check), the pointer's
# place after it settles (data)
function MmPost($h, [int]$msg, [int]$wparam, $p) {
    [long]$l = ([long]$p.Y -shl 16) -bor ([long]$p.X -band 0xFFFF)
    [void][Kit.Win]::PostMessage($h, [uint32]$msg, [IntPtr]$wparam, [IntPtr]$l)
}
foreach ($w in $wins) {
    $s = $w.Monitor
    if (-not $s) { continue }
    $pl = $plan.Values | Where-Object { $_.SX -eq ($s.X - $box3.X) -and $_.SY -eq ($s.Y - $box3.Y) } | Select-Object -First 1
    if (-not $pl) { continue }
    $q = [pscustomobject]@{ X = [int]($w.W / 2) + 37; Y = [int]($w.H2 / 2) + 29 }
    $tx = $pl.SX + [int][math]::Floor(($q.X - $pl.TX) / $pl.Scale); $ty = $pl.SY + [int][math]::Floor(($q.Y - $pl.TY) / $pl.Scale)
    [void][Kit.Win]::SetCursorPos($s.X + [int]($s.W / 4), $s.Y + [int]($s.H / 4))
    Quiet
    $pre = Cursor
    $from = @(MouseEvents).Count
    MmPost $w.H 0x0200 0 $q
    [void](Until 5 { @(MouseEvents | Select-Object -Skip $from | Where-Object { $_.X -eq $tx -and $_.Y -eq $ty }).Count -ge 1 })
    $after = @(MouseEvents | Select-Object -Skip $from)
    Check "5b b: pointer on $($s.Device), the server got the point" (@($after | Where-Object { $_.X -eq $tx -and $_.Y -eq $ty }).Count -ge 1) "window point $($q.X),$($q.Y), want $tx,$ty; the server got $(($after | Select-Object -First 6 | ForEach-Object { "$($_.X),$($_.Y)" }) -join ' ')"
    Quiet
    $last = @(MouseEvents) | Select-Object -Last 1
    $got = Cursor
    Note "5b b: pointer data on $($s.Device): before $($pre.X),$($pre.Y); posted window point $($q.X),$($q.Y) (session $tx,$ty); server events $(($after | ForEach-Object { "$($_.Flags):$($_.X),$($_.Y)" }) -join ' '); last $($last.X),$($last.Y) + box $($box3.X),$($box3.Y) = $($box3.X + $last.X),$($box3.Y + $last.Y); pointer now $($got.X),$($got.Y)"
}
Check "5b b: the session holds" (-not $mmB.HasExited)
Shot "5b-follow"
Stop $mmB
foreach ($p in $cw) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }

# a single-window session again for 6 (it posts its keys to that window): up once its Reset
# Graphics is in session.wlog (the file appender appends), not only its window (g6's review)
$r0 = @(Resets).Count
$session = StartSession
[void](Until 30 { @(Resets).Count -gt $r0 })
[void](Until 10 { $session.Refresh(); $session.MainWindowHandle -ne [IntPtr]::Zero })
Start-Sleep -Seconds 5
$session.Refresh()
$hwnd = $session.MainWindowHandle
Check "5b: a single-window session again for 6" ((-not $session.HasExited) -and ($hwnd -ne [IntPtr]::Zero) -and (@(Resets).Count -gt $r0)) "Reset Graphics $(@(Resets).Count - $r0) new"

# ---- 6. Ctrl+Alt+Del and the lock screen with both monitors (as windows-host.ps1 does it)
function PostKey([int]$vk, [int]$scan, [bool]$extended, [bool]$up) {
    [long]$l = 1 -bor ([long]$scan -shl 16)
    if ($extended) { $l = $l -bor 0x01000000 }
    if ($up) { $l = $l -bor 0xC0000000L }
    $msg = if ($up) { 0x0101 } else { 0x0100 }
    [Kit.Win]::PostMessage($hwnd, [uint32]$msg, [IntPtr]$vk, [IntPtr]$l)
}
$sas = "asked freerdp-shadow-service for the secure attention sequence"
for ($try = 1; $try -le 2 -and -not ((ServerLog) -match $sas); $try++) {
    Start-Sleep -Seconds 1
    [void]((PostKey 0x11 0x1D $false $false) -and (PostKey 0x12 0x38 $false $false) -and (PostKey 0x2E 0x53 $true $false) -and
        (PostKey 0x2E 0x53 $true $true) -and (PostKey 0x12 0x38 $false $true) -and (PostKey 0x11 0x1D $false $true))
    [void](Until 30 { (ServerLog) -match $sas })
}
[void](Until 30 { (ServerLog) -match "follows the input desktop from \w+ to Winlogon" })
Check "Ctrl+Alt+Del: the server asked the service" ((ServerLog) -match $sas)
Check "Ctrl+Alt+Del: the server followed to Winlogon" ((ServerLog) -match "follows the input desktop from \w+ to Winlogon")
[void](Until 20 { @(DuplicatedSince "to Winlogon").Count -ge 2 })
$places = DuplicatedSince "to Winlogon"
Check "Ctrl+Alt+Del: both outputs duplicated on the secure desktop" ($places.Count -ge 2) "$($places -join '; ')"
Check "Ctrl+Alt+Del: the session holds" (-not $session.HasExited)
Shot "after-sas"
[Kit.Win]::keybd_event(0x1B, 0x01, 0, [UIntPtr]::Zero)   # Esc: leave the Ctrl+Alt+Del screen
[Kit.Win]::keybd_event(0x1B, 0x01, 2, [UIntPtr]::Zero)
Start-Sleep -Seconds 5

$winlogon = Count "to Winlogon"
& rundll32.exe user32.dll,LockWorkStation
[void](Until 20 { (Count "to Winlogon") -gt $winlogon })
Check "locked: the server followed to Winlogon" ((Count "to Winlogon") -gt $winlogon)
[void](Until 20 { @(DuplicatedSince "to Winlogon").Count -ge 2 })
$places = DuplicatedSince "to Winlogon"
Check "locked: both outputs duplicated on the lock screen" (((Count "to Winlogon") -gt $winlogon) -and ($places.Count -ge 2)) "$($places -join '; ')"
Start-Sleep -Seconds 5
Check "locked: the session holds" (-not $session.HasExited)

# ---- the end
Finish

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
#   4. a click on each monitor: the pointer lands on the pixel the client meant
#      (GetCursorPos), and the window there gets the click
#   5. the second monitor moved to the other side, the same total size: a new Reset Graphics
#      with the new place, and the pointer still lands right
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

# the client: smart-sizing into a fixed 1200 x 450 window (half of 2400 x 900, the size two
# monitors of 1600 x 900 and 800 x 600 side by side make), so its points map back to the
# desktop at a known scale; the surface commands and Reset Graphics monitors at TRACE
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "session.wlog"
$env:WLOG_FILTER = "com.freerdp.channels.rdpgfx.client:TRACE"
$session = Start-Process -FilePath "$ClientDir\sdl-freerdp.exe" -PassThru -ArgumentList `
    "/v:127.0.0.1:$port", "/u:$user", "/p:$pass", "/cert:ignore", "/gfx:AV1:on", "/smart-sizing:1200x450"
Remove-Item Env:\WLOG_FILTER
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
$cr = New-Object Kit.Win+RECT; [void][Kit.Win]::GetClientRect($hwnd, [ref]$cr)
Note "client window $hwnd, client area $($cr.Right)x$($cr.Bottom)"
# the client's window away from the windows below (they must not be under it: what it shows
# of the desktop would then be itself); its client area keeps its size
[void][Kit.Win]::SetWindowPos($hwnd, [IntPtr]::Zero, 340, 380, 0, 0, 0x0001 -bor 0x0004)   # SWP_NOSIZE | SWP_NOZORDER
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
    Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile", "-Command", $script
}
$m2win = ColourWindow "second" $second.X $second.Y $second.W $second.H "Magenta" 240
$pwin = ColourWindow "primary" ($prim.X + 40) ($prim.Y + 40) 200 200 "Cyan" 240
Start-Sleep -Seconds 6
$before = @(ClientLog).Count
# a point of the desktop in the client's window: smart-sizing scales the box into the client area
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
$pc = InClient ($prim.X + 140) ($prim.Y + 140)
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
$bad = @(ClientLog | Where-Object { $_ -match "\[ERROR\].*(rdpgfx|gdi|codec|av1)" })
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
function Point([string]$name, $q, [switch]$Click) {
    $want = OnDesktop $q
    PostMouse 0x0200 0 $q   # WM_MOUSEMOVE
    $got = $null
    [void](Until 5 { $c = Cursor; $script:got = $c; ([math]::Abs($c.X - $want.X) -le 1) -and ([math]::Abs($c.Y - $want.Y) -le 1) })
    $got = Cursor
    Check "pointer: $name" (([math]::Abs($got.X - $want.X) -le 1) -and ([math]::Abs($got.Y - $want.Y) -le 1)) "client $($q.X),$($q.Y) -> want $($want.X),$($want.Y), got $($got.X),$($got.Y)"
    if ($Click) {
        PostMouse 0x0201 1 $q   # WM_LBUTTONDOWN, MK_LBUTTON
        Start-Sleep -Milliseconds 200
        PostMouse 0x0202 0 $q   # WM_LBUTTONUP
    }
    $want
}
$w2 = Point "on the second monitor" $m2c -Click
$wp = Point "on the primary monitor" $pc -Click
[void](Until 10 { (Test-Path "$Out\click-second.txt") -and (Test-Path "$Out\click-primary.txt") })
$c2 = if (Test-Path "$Out\click-second.txt") { (Get-Content "$Out\click-second.txt" | Select-Object -Last 1) } else { "" }
$cp = if (Test-Path "$Out\click-primary.txt") { (Get-Content "$Out\click-primary.txt" | Select-Object -Last 1) } else { "" }
Check "click: the window on the second monitor got it" ([bool]$c2) "at $c2, want $($w2.X),$($w2.Y)"
Check "click: the window on the primary monitor got it" ([bool]$cp) "at $cp, want $($wp.X),$($wp.Y)"

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
$m2c2 = InClient ($second2.X + [int]($second2.W / 2)) ($second2.Y + [int]($second2.H / 2))
[void](Point "on the moved second monitor" $m2c2)
Check "moved: the session holds" (-not $session.HasExited)
Shot "moved"

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

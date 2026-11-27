# probe-camera-win (a probe: publishes nothing; every change it makes stays on the runner, which is
# thrown away). Camera redirection of the kit's Windows client, end to end, on a hosted runner:
# Windows' own Remote Desktop on this PC is the server (the RDPECAM side, the camera a session
# sees); the kit's sdl-freerdp is the client, its camera the rdpecam mf backend playing a file
# (/dvc:rdpecam,sys:mf,file:<test.mp4>,name:Kit Test Camera); mf-camera-reader.exe, started inside
# the RDP session by a scheduled task, opens the redirected camera and logs its frames and type.
# Also, apart from the session: Windows' MJPEG decoder MFT decodes one JPEG to NV12.
#
#   probe-camera-win.ps1 -ClientDir <folder with sdl-freerdp.exe> -Assets <folder with
#                        mf-camera-reader-{x86_64,aarch64}.exe, test.mp4, test.jpg> -Out <out dir>
#
# The client is the x64 build everywhere (on Windows 11 on Arm it runs emulated); the reader is
# this machine's own architecture, so Media Foundation in the session runs natively.
#
# 1. What the host needs, recorded first: the edition, the camera redirection settings
#    (fDisableCameraRedir, machine and policy keys), the Windows features (Server-Media-Foundation,
#    Desktop-Experience; Server-Media-Foundation installed when missing, its RestartNeeded kept),
#    the Media Foundation DLLs, the Frame Server services, the camera devices. A restart needed is
#    this runner's result: the session part is then not tried (a hosted runner cannot restart).
#    Then what the host may need, applied and logged before the session: the policy "Do not allow
#    video capture redirection" not in force (fDisableCameraRedir=0 under its documented key), the
#    Frame Server service started. Nothing more is documented (see probe-camera-win.yml).
# 2. The MJPEG decoder MFT (no session).
# 3. The session, the reader inside it, the client.
# 4. The verdicts: PASS/FAIL lines in <out>\checks.txt, facts in <out>\host.txt, one line for the
#    job summary in <out>\result.txt. It fails when a check fails. The client logs every dynamic
#    channel the host opens (drdynvc at DEBUG, <out>\dvc-channels.txt): the first question is
#    whether the host opens RDCamera_Device_Enumerator at all.
param([string]$ClientDir, [string]$Assets, [string]$Out)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$ClientDir = (Resolve-Path $ClientDir).Path
$Assets = (Resolve-Path $Assets).Path
$Out = (Resolve-Path $Out).Path
$user = "kitcam"
$pass = "Camera-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$frames = 60
$cameraName = "Kit Test Camera"
$arch = if (($env:PROCESSOR_ARCHITECTURE -eq "ARM64") -or ($env:PROCESSOR_ARCHITEW6432 -eq "ARM64")) { "aarch64" } else { "x86_64" }
$reader = "$Assets\mf-camera-reader-$arch.exe"
$fails = 0
function Check($name, $ok, $detail = "") {
    $word = if ($ok) { "PASS" } else { "FAIL" }
    if (-not $ok) { $script:fails++ }
    "$word  $name$(if ($detail) { "  ($detail)" })" | Tee-Object -FilePath "$Out\checks.txt" -Append
}
function Fact($line) { $line | Tee-Object -FilePath "$Out\host.txt" -Append }
function Result($line) { $line | Tee-Object -FilePath "$Out\result.txt" -Append }
function Listening($p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }
function Until([int]$s, [scriptblock]$cond) {
    for ($i = 0; $i -lt $s; $i++) { if (& $cond) { return $true }; Start-Sleep -Seconds 1 }
    return [bool](& $cond)
}
function RegValue($key, $name) {
    $v = (Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $v) { "(not set)" } else { "$v" }
}
function Cameras($file) {
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.Class -in "Camera", "Image" -or $_.FriendlyName -like "*Camera*" } |
        Format-Table -AutoSize Status, Class, FriendlyName, InstanceId | Out-String -Width 300 | Out-File "$Out\$file"
}

# --- 1. what the host needs
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$runner = "$env:ImageOS $($os.Caption) $($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)"
Fact "os: $runner, InstallationType $($cv.InstallationType), ProductType $($os.ProductType)"
$ts = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
$pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
Fact "camera redirection, machine: fDenyTSConnections=$(RegValue $ts fDenyTSConnections), RDP-Tcp fDisableCameraRedir=$(RegValue "$ts\WinStations\RDP-Tcp" fDisableCameraRedir), Terminal Server fDisableCameraRedir=$(RegValue $ts fDisableCameraRedir)"
Fact "camera redirection, policy: fDisableCameraRedir=$(RegValue $pol fDisableCameraRedir)"
$sys32 = "$env:WINDIR\System32"
function Dlls { ("mfplat.dll", "mf.dll", "mfreadwrite.dll", "mfsrcsnk.dll", "msmpeg2vdec.dll", "mfmjpegdec.dll",
                 "frameserver.dll", "frameserverclient.dll", "rdpcamera.dll") |
    ForEach-Object { "$_=$(Test-Path "$sys32\$_")" } }
Fact "dlls: $((Dlls) -join ' ')"
Fact "this machine: $arch; the reader: $(Split-Path $reader -Leaf)"
foreach ($s in "FrameServer", "FrameServerMonitor", "TermService", "UmRdpService", "Audiosrv") {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    Fact "service $s`: $(if ($svc) { "$($svc.Status), $($svc.StartType)" } else { 'none' })"
}
$restartNeeded = $false
if ($cv.InstallationType -like "Server*") {
    # RDS-RD-Server (the Session Host role) only recorded: no Microsoft document says camera
    # redirection needs it, and the role usually asks for a restart (not tried here)
    foreach ($f in "Server-Media-Foundation", "Desktop-Experience", "Server-Gui-Shell", "RDS-RD-Server") {
        $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        Fact "feature $f`: $(if ($feat) { $feat.InstallState } else { 'not a feature of this edition' })"
    }
    $mf = Get-WindowsFeature -Name Server-Media-Foundation -ErrorAction SilentlyContinue
    if ($mf -and $mf.InstallState -ne "Installed") {
        $r = Install-WindowsFeature -Name Server-Media-Foundation
        Fact "Install-WindowsFeature Server-Media-Foundation: Success=$($r.Success) RestartNeeded=$($r.RestartNeeded) ExitCode=$($r.ExitCode)"
        Fact "dlls after the install: $((Dlls) -join ' ')"
        $restartNeeded = "$($r.RestartNeeded)" -eq "Yes"
    }
}
Cameras "cameras-before.txt"
if ($restartNeeded) {
    Result "$runner`: Server-Media-Foundation needs a restart; the session was not tried"
    "INFO  Server-Media-Foundation needs a restart on this runner: that is its result" | Tee-Object -FilePath "$Out\checks.txt" -Append
    exit 0
}
Check "Media Foundation is there (mfplat, mf, mfreadwrite)" ((Test-Path "$sys32\mfplat.dll") -and (Test-Path "$sys32\mf.dll") -and (Test-Path "$sys32\mfreadwrite.dll"))

# what the host may need, before the session: the documented policy, read back; the Frame Server
# (the service through which applications share cameras; Manual, started on demand)
if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
Set-ItemProperty -Path $pol -Name fDisableCameraRedir -Value 0 -Type DWord
Fact "set before the session: policy fDisableCameraRedir=$(RegValue $pol fDisableCameraRedir) (0: video capture redirection allowed)"
foreach ($s in "FrameServer", "FrameServerMonitor") {
    try { Start-Service -Name $s -ErrorAction Stop; Fact "started $s`: $((Get-Service $s).Status)" }
    catch { Fact "start $s failed: $($_.Exception.Message)" }
}

# --- 2. the MJPEG decoder MFT: MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, MJPG in), its name, CLSID
#        and output types logged, one JPEG decoded to NV12
& $reader mjpeg "$Assets\test.jpg" 640 360 --timeout 60 2>&1 | Tee-Object "$Out\mjpeg-decode.log"
$mjRc = $LASTEXITCODE
$mj = Select-String -Path "$Out\mjpeg-decode.log" -Pattern "^\S+ RESULT (.*)$" | Select-Object -Last 1 | ForEach-Object { $_.Matches[0].Groups[1].Value }
Check "MJPEG decoder MFT: one MJPG frame decoded to NV12" ($mjRc -eq 0) "$mj"

# --- 3. the session: Windows' own Remote Desktop for a test user (as test/windows-host.ps1),
#        camera redirection not refused by policy
Set-ItemProperty $ts fDenyTSConnections 0
Fact "set: fDenyTSConnections=$(RegValue $ts fDenyTSConnections)"
New-LocalUser -Name $user -Password (ConvertTo-SecureString $pass -AsPlainText -Force) -PasswordNeverExpires | Out-Null
Add-LocalGroupMember -Group "Remote Desktop Users" -Member $user
$cred = New-Object PSCredential $user, (ConvertTo-SecureString $pass -AsPlainText -Force)
# the user's profile made now, so the session's first sign-in is quick
Start-Process cmd -Credential $cred -LoadUserProfile -ArgumentList "/c", "exit" -Wait -WindowStyle Hidden
Check "rdp: Windows' own Remote Desktop listens on 3389" (Until 30 { Listening 3389 })

# the reader, in the user's session: a scheduled task run when the user signs in (the RDP
# session), interactive, so it sees the session's cameras. --match "": the first camera there;
# it logs them all, so the record says what Windows names a redirected camera
$dir = "C:\kitcam"
New-Item -ItemType Directory -Force -Path "$dir\out" | Out-Null
Copy-Item $reader "$dir\mf-camera-reader.exe"
icacls "$dir\out" /grant "${user}:(OI)(CI)M" | Out-Null
# the reader itself, writing its own log (v1 ran it through cmd /c, whose quote stripping broke
# the command line: LastTaskResult 1, no log)
$action = New-ScheduledTaskAction -Execute "$dir\mf-camera-reader.exe" `
    -Argument "camera --match `"`" --frames $frames --wait 120 --timeout 180 --log `"$dir\out\reader.log`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$user"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$user" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "kit-camera-reader" -Action $action -Trigger $trigger -Principal $principal `
    -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)) | Out-Null
function TaskState($when) {
    $i = Get-ScheduledTaskInfo -TaskName "kit-camera-reader" -ErrorAction SilentlyContinue
    $t = Get-ScheduledTask -TaskName "kit-camera-reader" -ErrorAction SilentlyContinue
    "task $when`: State=$($t.State) LastRunTime=$($i.LastRunTime) LastTaskResult=$($i.LastTaskResult) log=$(Test-Path "$dir\out\reader.log")" |
        Tee-Object -FilePath "$Out\task.txt" -Append
}
TaskState "registered"

# the client, its camera the file, to 127.0.0.2 (as windows-host.ps1: this PC's own server
# refuses 127.0.0.1); its log in <out>\client.wlog, the camera channel's tags at DEBUG
$env:WLOG_LEVEL = "INFO"
# a filter names whole tags ("*" only stands for a whole part of one): the channel's four
# and every dynamic channel the host opens: drdynvc (process_create_request ... ChannelName=), and
# the core's channel layer
$env:WLOG_FILTER = (("channels.rdpecam-enum.client", "channels.rdpecam-device.client", "channels.rdpecam-video.client",
                     "channels.rdpecam-mf.client", "channels.drdynvc.client", "core.channels") |
    ForEach-Object { "com.freerdp.$_`:DEBUG" }) -join ","
$env:WLOG_APPENDER = "FILE"
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_PATH = $Out
$env:WLOG_FILEAPPENDER_OUTPUT_FILE_NAME = "client.wlog"
$camArgs = "/dvc:rdpecam,sys:mf,file:$Assets\test.mp4,name:$cameraName"
$client = Start-Process -FilePath "$ClientDir\sdl-freerdp.exe" -PassThru -NoNewWindow `
    -ArgumentList "/v:127.0.0.2:3389", "/u:$user", "/p:$pass", "/cert:ignore", "/size:1280x720", "`"$camArgs`""
$session = Until 60 { (quser 2>$null) -match "^\s*>?$user\s" }
Check "rdp: the client's session signed in" $session ((quser 2>$null) -join " | ")
# AtLogOn should have started the reader (its log starts with its first line); by hand when not
$byLogon = Until 20 { Test-Path "$dir\out\reader.log" }
TaskState "after the sign-in"
Fact "the reader started by the AtLogOn trigger: $(if ($byLogon) { 'yes' } else { 'no, started by hand' })"
if (-not $byLogon) {
    Start-ScheduledTask -TaskName "kit-camera-reader"
    $byHand = Until 20 { Test-Path "$dir\out\reader.log" }
    TaskState "started by hand"
    Check "the reader runs in the session (started by hand)" $byHand
}
Start-Sleep -Seconds 5
Cameras "cameras-during.txt"

$done = Until 180 { (Test-Path "$dir\out\reader.log") -and (Select-String -Path "$dir\out\reader.log" -Pattern " RESULT " -Quiet) }
Copy-Item "$dir\out\reader.log" "$Out\reader.log" -ErrorAction SilentlyContinue
TaskState "at the end"
$result = if (Test-Path "$Out\reader.log") {
    Select-String -Path "$Out\reader.log" -Pattern "^\S+ RESULT (.*)$" | Select-Object -Last 1 | ForEach-Object { $_.Matches[0].Groups[1].Value }
}

# --- 4. the verdicts
$got = if ("$result" -match "frames=([0-9]+)") { [int]$Matches[1] } else { 0 }
$distinct = if ("$result" -match "distinct=([0-9]+)") { [int]$Matches[1] } else { 0 }
$type = if ("$result" -match "type=(\S+)") { $Matches[1] } else { "" }
Check "camera: the session's app read $frames frames of the redirected camera" ($done -and $got -ge $frames) "$result"
Check "camera: the frames change (more than 10 distinct)" ($distinct -gt 10) "distinct=$distinct"
Check "camera: the media type is named" ($type -match "^[A-Z0-9]{4}$") "type=$type"

# the client's log: written as it goes, closed when the client ends
if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force }
Start-Sleep -Seconds 2
$log = if (Test-Path "$Out\client.wlog") { Get-Content "$Out\client.wlog" -Raw } else { "" }
$cameraLine = ([regex]::Matches($log, "Camera $cameraName`: [^\r\n]*") | Select-Object -First 1).Value
$errors = @([regex]::Matches($log, "\[ERROR\]\[com\.freerdp\.channels\.rdpecam[^\]]*\][^\r\n]*") | ForEach-Object Value)
# every dynamic channel the host opened, in order
$dvcs = @([regex]::Matches($log, "process_create_request: ChannelId=([0-9]+) ChannelName=([^\s]+)") |
    ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
$dvcs | Out-File "$Out\dvc-channels.txt"
$enumerator = [bool]($dvcs -match " RDCamera_Device_Enumerator$")
Fact "dynamic channels the host opened: $(if ($dvcs) { ($dvcs | ForEach-Object { ($_ -split ' ')[1] }) -join ', ' } else { 'none logged' })"
Fact "host opened RDCamera_Device_Enumerator: $(if ($enumerator) { 'yes' } else { 'no' })"
Check "host opened RDCamera_Device_Enumerator" $enumerator "$($dvcs.Count) dynamic channel(s) opened"
Check "client: the mf backend loaded" ($log -match "Loaded mf HAL for ecam")
Check "client: the file played as the camera" ([bool]$cameraLine) $cameraLine
Check "client: no error from the camera channel" ($errors.Count -eq 0) "$($errors.Count) error(s)$(if ($errors) { ': ' + $errors[0] })"

# the end: the session signed out, the task removed
(quser 2>$null) -match "^\s*>?$user\s" | ForEach-Object {
    $id = ($_ -split "\s+" | Where-Object { $_ -match "^\d+$" })[0]; if ($id) { logoff $id } }
Unregister-ScheduledTask -TaskName "kit-camera-reader" -Confirm:$false -ErrorAction SilentlyContinue

Get-Content "$Out\checks.txt"
Result "$runner`: $(if ($fails) { "$fails check(s) failed" } else { 'camera redirection works' }); host opened RDCamera_Device_Enumerator: $(if ($enumerator) { 'yes' } else { 'no' }); reader: $result; mjpeg: $mj"
if ($fails -gt 0) { throw "$fails check(s) failed" }

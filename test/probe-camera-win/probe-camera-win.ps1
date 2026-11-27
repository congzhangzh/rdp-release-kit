# probe-camera-win (a probe: publishes nothing; every change it makes stays on the runner, which is
# thrown away). Camera redirection of the kit's Windows client, end to end, on a hosted runner:
# Windows' own Remote Desktop on this PC is the server (the RDPECAM side, the camera a session
# sees); the kit's sdl-freerdp is the client, its camera the rdpecam mf backend playing a file
# (/dvc:rdpecam,sys:mf,file:<test.mp4>,name:Kit Test Camera); mf-camera-reader.exe, started inside
# the RDP session by an HKLM Run entry (a scheduled task as the fallback), opens the redirected
# camera, keeps it open 5 s or more and logs its frames and type.
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
# 3. The session, the reader inside it, the client. The session stays connected until the
#    reader's RESULT; everything added for it is removed at the end, whatever happened.
#    -TakeOverConsole (the windows-11-arm job only; the RM's one try of option A): Windows 11
#    has one active session, and another user's sign-in waits on the "another user is signed
#    in" dialog (runs 2 and 3, LOGON_MSG_BUMP_OPTIONS; tsdiscon left the console Active). So no
#    test user: runneradmin gets a random password for this run (masked first, never logged,
#    given to the client on its command line only), and the client signs in as runneradmin,
#    which takes the console session over: this script's own session becomes the RDP session,
#    and the script starts the reader in it. That session is never signed out (the runner
#    lives in it). If it does not become the RDP session, that is the result: "A failed: ...";
#    nothing further is tried.
# 4. The verdicts: PASS/FAIL lines in <out>\checks.txt, facts in <out>\host.txt, one line for the
#    job summary in <out>\result.txt. It fails when a check fails. The client logs every dynamic
#    channel the host opens (drdynvc at DEBUG, <out>\dvc-channels.txt): the first question is
#    whether the host opens RDCamera_Device_Enumerator at all. A Windows Server that does not
#    (runs 1 and 2) has its camera checks as INFO lines: a recorded fact, not a failure. The
#    MS-RDPECAM messages (Start Streams Request 0x0F, Sample Request 0x11, Sample Response 0x12,
#    Sample Error Response 0x13) are counted in the client's log.
param([string]$ClientDir, [string]$Assets, [string]$Out, [switch]$TakeOverConsole)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$ClientDir = (Resolve-Path $ClientDir).Path
$Assets = (Resolve-Path $Assets).Path
$Out = (Resolve-Path $Out).Path
$user = if ($TakeOverConsole) { "runneradmin" } else { "kitcam" }
$pass = "Camera-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
# the password is a secret of this run: masked in the job's log before anything can print it
Write-Host "::add-mask::$pass"
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
$isServer = $cv.InstallationType -like "Server*"
Set-ItemProperty $ts fDenyTSConnections 0
Fact "set: fDenyTSConnections=$(RegValue $ts fDenyTSConnections)"
if ($TakeOverConsole) {
    Fact "option A: the job runs as $env:USERNAME; sessions: $((quser 2>$null) -join ' | ')"
    if ($env:USERNAME -ne "runneradmin") {
        Result "$runner`: A failed: the job does not run as runneradmin but as $env:USERNAME; nothing changed"
        throw "A failed: the job does not run as runneradmin"
    }
    # its output is a status line only; the password is on the command line, not logged
    net user runneradmin $pass | Out-Null
    $changed = ($LASTEXITCODE -eq 0)
    Fact "runner change: runneradmin password changed for this run: $(if ($changed) { 'yes' } else { "no (net user exit $LASTEXITCODE)" })"
    if (-not $changed) {
        Result "$runner`: A failed: the runneradmin password could not be set (net user exit $LASTEXITCODE)"
        throw "A failed: net user"
    }
} else {
    New-LocalUser -Name $user -Password (ConvertTo-SecureString $pass -AsPlainText -Force) -PasswordNeverExpires | Out-Null
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member $user
    $cred = New-Object PSCredential $user, (ConvertTo-SecureString $pass -AsPlainText -Force)
    # the user's profile made now, so the session's first sign-in is quick
    Start-Process cmd -Credential $cred -LoadUserProfile -ArgumentList "/c", "exit" -Wait -WindowStyle Hidden
}
Check "rdp: Windows' own Remote Desktop listens on 3389" (Until 30 { Listening 3389 })

# the reader, in the user's session: (b) an HKLM Run entry, which explorer runs at every
# interactive sign-in, the RDP session's included (--only-user: the others leave at once, before
# its log is touched); the fallback, when it has not started a minute after the sign-in, a
# scheduled task started by hand (interactive, the session must be there; its own log).
# (a), the all-users Startup folder, is run by explorer too, later; (c), /shell:, is not used:
# no Microsoft document says a client edition honours it. --match "": the first camera there;
# it logs them all, so the record says what Windows names a redirected camera.
# -TakeOverConsole: the RDP sign-in reconnects to a session that runs already, so no Run entry
# fires there; the script starts the reader itself, in its own session, once that is the RDP
# session (the Run entry stays, --only-user runneradmin).
$dir = "C:\kitcam"
New-Item -ItemType Directory -Force -Path "$dir\out" | Out-Null
Copy-Item $reader "$dir\mf-camera-reader.exe"
icacls "$dir\out" /grant "${user}:(OI)(CI)M" | Out-Null
$readerArgs = "camera --match `"`" --frames $frames --min-seconds 5 --wait 120 --timeout 200 --only-user $user"
$runKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $runKey -Name "KitCameraReader" -Value "`"$dir\mf-camera-reader.exe`" $readerArgs --log `"$dir\out\reader.log`""
Fact "added: $runKey KitCameraReader = $((Get-ItemProperty $runKey).KitCameraReader)"
$action = New-ScheduledTaskAction -Execute "$dir\mf-camera-reader.exe" -Argument "$readerArgs --log `"$dir\out\reader-task.log`""
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$user" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "kit-camera-reader" -Action $action -Principal $principal `
    -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)) | Out-Null
function TaskState($when) {
    $i = Get-ScheduledTaskInfo -TaskName "kit-camera-reader" -ErrorAction SilentlyContinue
    $t = Get-ScheduledTask -TaskName "kit-camera-reader" -ErrorAction SilentlyContinue
    "task $when`: State=$($t.State) LastRunTime=$($i.LastRunTime) LastTaskResult=$($i.LastTaskResult)" |
        Tee-Object -FilePath "$Out\task.txt" -Append
}
function ClientLog { if (Test-Path "$Out\client.wlog") { Get-Content "$Out\client.wlog" -Raw -ErrorAction SilentlyContinue } else { "" } }
# the user's session Active; with -TakeOverConsole it must be on rdp-tcp (the console taken over)
function UserSession {
    $name = if ($TakeOverConsole) { "rdp-tcp#[0-9]+" } else { "\S+" }
    [bool]((quser 2>$null) -match "^\s*>?$user\s+$name\s+[0-9]+\s+Active")
}

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
$client = $null
$result = $null
$readerLog = $null
try {
    $client = Start-Process -FilePath "$ClientDir\sdl-freerdp.exe" -PassThru -NoNewWindow `
        -ArgumentList "/v:127.0.0.2:3389", "/u:$user", "/p:$pass", "/cert:ignore", "/size:1280x720", "`"$camArgs`""

    # signed in: the user's session Active, while the client is still connected
    $session = Until 90 { (UserSession) -or ($client.HasExited) }
    $session = $session -and -not $client.HasExited -and (UserSession)
    $sessionName = if ($TakeOverConsole) { "the runneradmin session on rdp-tcp, Active while connected" } else { "the client's session signed in (Active while connected)" }
    Check "rdp: $sessionName" $session ((quser 2>$null) -join " | ")
    if ((ClientLog) -match "LOGON_MSG_BUMP_OPTIONS") { Fact "the host showed the 'another user is signed in' dialog (LOGON_MSG_BUMP_OPTIONS)" }

    # the reader: the Run entry first, the task by hand when it did not start; with
    # -TakeOverConsole the script itself, in its session, once that is the RDP session
    $readerLog = "$dir\out\reader.log"
    $how = "the HKLM Run entry"
    if ($TakeOverConsole) {
        if ($session) {
            Start-Process -FilePath "$dir\mf-camera-reader.exe" -WindowStyle Hidden `
                -ArgumentList "$readerArgs --log `"$readerLog`""
            $how = "this script, in its own session (the console session the RDP sign-in took over)"
        } else {
            $how = "nothing: the session did not become the RDP session"
        }
        $null = Until 30 { Test-Path $readerLog }
    } elseif (-not (Until 60 { Test-Path $readerLog })) {
        TaskState "before the start by hand"
        Start-ScheduledTask -TaskName "kit-camera-reader"
        $readerLog = "$dir\out\reader-task.log"
        $how = "the scheduled task, started by hand"
        if (-not (Until 30 { Test-Path $readerLog })) { $how = "nothing: it did not start" }
        TaskState "after the start by hand"
    }
    Fact "the reader was started by: $how"
    Check "the reader runs in the session" (Test-Path $readerLog) $how

    # a Server that never opens the enumerator gives the reader no camera: not waited for
    $enumeratorLive = Until 30 { (ClientLog) -match "ChannelName=RDCamera_Device_Enumerator" }
    if ($enumeratorLive -or -not $isServer) {
        # the session stays connected until the reader has its RESULT
        $done = Until 120 { (Test-Path $readerLog) -and (Select-String -Path $readerLog -Pattern " RESULT " -Quiet) }
        Fact "the reader's RESULT came: $done"
    }
    Cameras "cameras-during.txt"
    if (Test-Path $readerLog) {
        Copy-Item $readerLog "$Out\$(Split-Path $readerLog -Leaf)" -ErrorAction SilentlyContinue
        $result = Select-String -Path $readerLog -Pattern "^\S+ RESULT (.*)$" | Select-Object -Last 1 | ForEach-Object { $_.Matches[0].Groups[1].Value }
    }
}
finally {
    # the end, whatever happened: the client closed (its log then complete), the session signed
    # out, the Run entry and the task removed (the workflow's cleanup step does it again)
    # (-TakeOverConsole: never signed out, the runner lives in that session; closing the client
    # only disconnects it)
    if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force }
    if (-not $TakeOverConsole) {
        (quser 2>$null) -match "^\s*>?$user\s" | ForEach-Object {
            $id = ($_ -split "\s+" | Where-Object { $_ -match "^\d+$" })[0]; if ($id) { logoff $id } }
    }
    Fact "sessions at the end: $((quser 2>$null) -join ' | ')"
    Remove-ItemProperty -Path $runKey -Name "KitCameraReader" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "kit-camera-reader" -Confirm:$false -ErrorAction SilentlyContinue
    Fact "removed: the Run entry ($(-not (Get-ItemProperty $runKey -Name KitCameraReader -ErrorAction SilentlyContinue))), the task ($(-not (Get-ScheduledTask -TaskName kit-camera-reader -ErrorAction SilentlyContinue)))"
}
Start-Sleep -Seconds 2

# --- 4. the verdicts
$log = ClientLog
# every dynamic channel the host opened, in order
$dvcs = @([regex]::Matches($log, "process_create_request: ChannelId=([0-9]+) ChannelName=([^\s]+)") |
    ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
$dvcs | Out-File "$Out\dvc-channels.txt"
$enumerator = [bool]($dvcs -match " RDCamera_Device_Enumerator$")
Fact "dynamic channels the host opened: $(if ($dvcs) { ($dvcs | ForEach-Object { ($_ -split ' ')[1] }) -join ', ' } else { 'none logged' })"
Fact "host opened RDCamera_Device_Enumerator: $(if ($enumerator) { 'yes' } else { 'no' })"

# a Windows Server host on these runners does not redirect cameras (runs 1 and 2: it opens its
# other dynamic channels, never RDCamera_Device_Enumerator): a recorded fact there, not a failure
$noCamera = $isServer -and -not $enumerator
$noCameraWhy = "Windows Server's RDP host on this hosted runner does not redirect cameras: it never opened RDCamera_Device_Enumerator"
function CamCheck($name, $ok, $detail = "") {
    if ($noCamera) {
        "INFO  $name  ($noCameraWhy$(if ($detail) { "; $detail" }))" | Tee-Object -FilePath "$Out\checks.txt" -Append
    } else { Check $name $ok $detail }
}

# the MS-RDPECAM messages on the device channels (2.2.1): received 0x0F Start Streams Request,
# 0x11 Sample Request; sent 0x12 Sample Response, 0x13 Sample Error Response
function Received($id) { [regex]::Matches($log, "\[ecam_dev_on_data_received\]: ChannelId=[0-9]+, MessageId=$id,").Count }
function Sent($id) { [regex]::Matches($log, "\[ecam_channel_write\]: ChannelId=[0-9]+, MessageId=$id,").Count }
$startStreams = Received "0x0f"
$sampleRequests = Received "0x11"
$sampleResponses = Sent "0x12"
$sampleErrors = Sent "0x13"
Fact "MS-RDPECAM on the device channels: Start Streams Request x$startStreams, Sample Request x$sampleRequests, Sample Response x$sampleResponses, Sample Error Response x$sampleErrors"

$got = if ("$result" -match "frames=([0-9]+)") { [int]$Matches[1] } else { 0 }
$distinct = if ("$result" -match "distinct=([0-9]+)") { [int]$Matches[1] } else { 0 }
$open = if ("$result" -match "open=([0-9.]+) s") { [double]$Matches[1] } else { 0 }
$type = if ("$result" -match "type=(\S+)") { $Matches[1] } else { "" }
$cameraLine = ([regex]::Matches($log, "Camera $cameraName`: [^\r\n]*") | Select-Object -First 1).Value
$errors = @([regex]::Matches($log, "\[ERROR\]\[com\.freerdp\.channels\.rdpecam[^\]]*\][^\r\n]*") | ForEach-Object Value)

CamCheck "host opened RDCamera_Device_Enumerator" $enumerator "$($dvcs.Count) dynamic channel(s) opened"
CamCheck "camera: the session's app read $frames frames, the camera open 5 s or more" ($got -ge $frames -and $open -ge 5) "$result"
CamCheck "camera: the frames change (more than 10 distinct)" ($distinct -gt 10) "distinct=$distinct"
CamCheck "camera: the media type is named" ($type -match "^[A-Z0-9]{4}$") "type=$type"
CamCheck "client: the host started the stream (Start Streams Request)" ($startStreams -ge 1) "x$startStreams"
CamCheck "client: samples requested and sent ($frames or more each)" ($sampleRequests -ge $frames -and $sampleResponses -ge $frames) "requests x$sampleRequests, responses x$sampleResponses"
CamCheck "client: the file played as the camera" ([bool]$cameraLine) $cameraLine
Check "client: the mf backend loaded" ($log -match "Loaded mf HAL for ecam")
Check "client: no error from the camera channel, no Sample Error Response" (($errors.Count -eq 0) -and ($sampleErrors -eq 0)) "$($errors.Count) error(s)$(if ($errors) { ': ' + $errors[0] }), x$sampleErrors"

Get-Content "$Out\checks.txt"
$verdict = if ($TakeOverConsole -and -not $session) { "A failed: the runneradmin session did not become the RDP session ($(if ((ClientLog) -match 'LOGON_MSG_BUMP_OPTIONS') { 'the host showed the bump dialog' } else { 'see host.txt' }))" } elseif ($fails) { "$fails check(s) failed" } elseif ($noCamera) { "no camera redirection on this host (recorded); the rest passed" } else { "camera redirection works" }
Result "$runner`: $verdict; host opened RDCamera_Device_Enumerator: $(if ($enumerator) { 'yes' } else { 'no' }); reader: $result; mjpeg: $mj"
if ($fails -gt 0) { throw "$fails check(s) failed" }

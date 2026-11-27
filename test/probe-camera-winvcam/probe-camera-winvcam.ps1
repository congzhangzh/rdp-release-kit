# probe-camera-winvcam: can a GitHub-hosted Windows runner register a Media Foundation
# virtual camera (MFCreateVirtualCamera, documented for Windows 11 build 22000+ with no
# minimum server version), and can an app read frames from it through Frame Server?
# A record for the shadow server's virtual camera (freerdp-comp-camera-g1, 2026-11-27, W0
# of the shadow camera design). Run by .github/workflows/probe-camera-winvcam.yml;
# publishes nothing.
#
#   probe-camera-winvcam.ps1 -Stage <info|start|build|probe|cleanup|summary>
#                            -Arch <x64|arm64> -Out <dir> [-Runner <label>]
#   probe-camera-winvcam.ps1 -Stage snapshot -Arch <...> -Out <dir> -Tag <name>
#       (run by the probe while a camera whose Start failed still exists: PnP + events)
#
# v3 diagnostics (Start failed with MF_E_SHUTDOWN everywhere in run 46031460019): the DLL
# logs every call it gets to C:\ProgramData\probe-camera-winvcam\dll-<pid>.log (copied to
# $Out\dll-logs); the camera, Media Foundation, PnP and Application/System event channels
# are listed, enabled where they are off, and read (events-<tag>\); WER reports of the run
# are copied (wer\); PnP camera and SWD devices are listed while the failed camera exists.
#
# Each stage appends "PROBE <step> <PASS|FAIL|SKIP|INFO> <detail>" lines to $Out\probe.log;
# summary turns them into a table in the job summary. A missing API, service or camera is
# a result. Only a failure of our own code (the build, regsvr32 of our DLL, the in-process
# read of our media source) fails the job.
param(
    [Parameter(Mandatory)] [ValidateSet('info', 'start', 'build', 'probe', 'snapshot', 'cleanup', 'summary')] [string] $Stage,
    [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string] $Arch,
    [Parameter(Mandatory)] [string] $Out,
    [string] $Runner = '',
    [string] $Tag = 'snapshot'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$log = Join-Path $Out 'probe.log'
$src = $PSScriptRoot
$bin = Join-Path $Out 'bin'
# Frame Server loads the DLL as Local Service: a folder outside any user profile
$installDir = 'C:\ProgramData\probe-camera-winvcam'
$dll = Join-Path $installDir 'probe-camera-source.dll'
$exe = Join-Path $bin 'probe-camera-winvcam.exe'
$services = @('FrameServer', 'FrameServerMonitor')

function Say([string] $step, [string] $verdict, [string] $detail) {
    $line = "PROBE $step $verdict $detail"
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding utf8
}
function Save([string] $name, $value) {
    $value | Out-File -FilePath (Join-Path $Out $name) -Encoding utf8 -Width 400
}

# the event channels worth reading: cameras, Media Foundation, Frame Server, device setup
$channelPattern = 'MediaFoundation|Microsoft-Windows-MF|FrameServer|Camera|Kernel-PnP/Configuration|DeviceSetupManager|DriverFrameworks-UserMode|Sensor'
$enabledList = Join-Path $Out 'enabled-channels.txt'

function Get-CameraChannels {
    Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.LogName -match $channelPattern }
}

# Reads the camera channels and Application/System since $minutes ago into events-$tag\.
# Analytic and debug channels are read only at the end ($final): they must be disabled first.
function Collect-Events([string] $tag, [int] $minutes, [bool] $final) {
    $since = (Get-Date).AddMinutes(-$minutes)
    $dir = Join-Path $Out "events-$tag"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $channels = @(Get-CameraChannels)
    ($channels | Format-Table -AutoSize LogName, IsEnabled, LogType, RecordCount | Out-String -Width 400) |
        Out-File -FilePath (Join-Path $dir 'channels.txt') -Encoding utf8 -Width 400
    (wevtutil el | Select-String -Pattern 'FrameServer|Camera' | ForEach-Object { "$_" }) |
        Out-File -FilePath (Join-Path $dir 'wevtutil-el-frameserver-camera.txt') -Encoding utf8
    Say "events-$tag" 'INFO' "$($channels.Count) camera/MF/PnP channel(s): $(($channels | ForEach-Object { $_.LogName }) -join ', ')"
    $enabledByUs = @()
    if (Test-Path $enabledList) { $enabledByUs = @(Get-Content $enabledList -Encoding utf8) }
    foreach ($c in $channels) {
        $direct = $c.LogType -in @('Analytical', 'Debug')
        if ($direct -and -not $final) { continue }
        if ($direct) {
            if (-not ($enabledByUs -contains $c.LogName)) { continue }
            wevtutil sl $c.LogName /e:false /q:true 2>&1 | Out-Null
            $events = Get-WinEvent -LogName $c.LogName -Oldest -MaxEvents 3000 -ErrorAction SilentlyContinue
        } else {
            $events = Get-WinEvent -FilterHashtable @{ LogName = $c.LogName; StartTime = $since } -ErrorAction SilentlyContinue
        }
        $n = @($events).Count
        if ($n -eq 0) { continue }
        $file = ($c.LogName -replace '[\\/:*?"<>| ]', '_') + '.txt'
        $events | Format-List TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Out-File -FilePath (Join-Path $dir $file) -Encoding utf8 -Width 400
        $errors = @($events | Where-Object { $_.Level -in 1, 2, 3 }).Count
        Say "events-$tag" 'INFO' "$($c.LogName): $n event(s), $errors error/warning"
    }
    foreach ($name in @('Application', 'System')) {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $name; StartTime = $since; Level = 1, 2, 3 } -ErrorAction SilentlyContinue)
        $events += @(Get-WinEvent -FilterHashtable @{ LogName = $name; StartTime = $since;
            ProviderName = 'Application Error', 'Windows Error Reporting', 'Application Hang', 'Service Control Manager' } -ErrorAction SilentlyContinue)
        $events = @($events | Where-Object { $_ } | Sort-Object RecordId -Unique | Sort-Object TimeCreated)
        $events | Format-List TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Out-File -FilePath (Join-Path $dir "$name.txt") -Encoding utf8 -Width 400
        $hits = @($events | Where-Object { "$($_.Message)" -match 'FrameServer|Frame Server|svchost|probe-camera|mfsensorgroup|Camera' })
        Say "events-$tag" 'INFO' "$($name): $($events.Count) error/warning/WER/SCM event(s) in $minutes min, $($hits.Count) about the camera stack"
        foreach ($h in ($hits | Select-Object -First 6)) {
            $text = ("$($h.Message)" -replace '\s+', ' ')
            if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
            Say "events-$tag" 'INFO' "$name $($h.ProviderName) $($h.Id): $text"
        }
    }
}

# PnP camera, image and software (SWD) devices with their problem codes
function Snapshot-Pnp([string] $tag) {
    $devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
            ($_.Class -in @('Camera', 'Image')) -or ("$($_.FriendlyName)" -match 'probe-camera|Virtual Camera') -or
            (($_.InstanceId -like 'SWD\*') -and ("$($_.InstanceId)" -match 'VCAM|CAMERA|FrameServer|probe'))
        })
    $lines = foreach ($d in $devices) {
        $problem = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
        $status = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemStatus' -ErrorAction SilentlyContinue).Data
        "$($d.Status) class=$($d.Class) name=""$($d.FriendlyName)"" problem=$problem problemStatus=$status id=$($d.InstanceId)"
    }
    Save "pnp-$tag.txt" $lines
    Save "pnp-$tag-swd.txt" (Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'SWD\*' } |
        Format-Table -AutoSize Status, Class, FriendlyName, InstanceId | Out-String -Width 400)
    Say "pnp-$tag" 'INFO' "$($devices.Count) camera/image/virtual-camera device(s)"
    foreach ($l in ($lines | Select-Object -First 8)) { Say "pnp-$tag" 'INFO' $l }
}

# the DLL's own logs, one per process that loaded it
function Copy-DllLogs {
    $dest = Join-Path $Out 'dll-logs'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    # beside the DLL, else (not writable there) each process's temp folder
    $logs = @(Get-ChildItem -Path $installDir -Filter 'dll-*.log' -ErrorAction SilentlyContinue)
    $temps = @('C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp', 'C:\Windows\SystemTemp', 'C:\Windows\Temp', $env:TEMP)
    $logs += @(Get-ChildItem -Path $temps -Filter 'probe-camera-winvcam-dll-*.log' -ErrorAction SilentlyContinue)
    foreach ($f in $logs) {
        Copy-Item -Path $f.FullName -Destination $dest -Force
        $first = (Get-Content $f.FullName -TotalCount 1 -Encoding utf8)
        $failed = @(Select-String -Path $f.FullName -Pattern 'failed|E_NOINTERFACE|after Shutdown' -ErrorAction SilentlyContinue).Count
        Say 'dll-log' 'INFO' "$($f.Name): $failed failure/no-interface line(s); $first"
    }
    if ($logs.Count -eq 0) { Say 'dll-log' 'INFO' "no dll-*.log in $installDir nor in the temp folders" }
}

# WER reports written during the run
function Copy-Wer {
    $dest = Join-Path $Out 'wer'
    $since = (Get-Date).AddMinutes(-40)
    $reports = @(Get-ChildItem -Path 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive', 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue' -Recurse -Filter 'Report.wer' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $since })
    foreach ($r in $reports) {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Path $r.FullName -Destination (Join-Path $dest ("$($r.Directory.Name).wer")) -Force
        $app = (Select-String -Path $r.FullName -Pattern '^(AppName|AppPath|Sig\[\d\]\.Value)=' -ErrorAction SilentlyContinue | Select-Object -First 6 | ForEach-Object { $_.Line }) -join '; '
        Say 'wer' 'INFO' "$($r.Directory.Name): $app"
    }
    if ($reports.Count -eq 0) { Say 'wer' 'INFO' 'no WER report in the last 40 min' }
}

switch ($Stage) {
    # 1. what Windows this is, the camera services, mfsensorgroup.dll and its export
    'info' {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Say 'os' 'INFO' ("$($os.Caption) | build $($os.BuildNumber).$($cv.UBR) | EditionID $($cv.EditionID) | " +
            "InstallationType $($cv.InstallationType) | $($cv.DisplayVersion) | ProductType $($os.ProductType) | " +
            "$env:PROCESSOR_ARCHITECTURE | runner $Runner | user $env:USERNAME session $((Get-Process -Id $PID).SessionId)")
        foreach ($name in $services) {
            $s = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($s) { Say "service-$name" 'PASS' "installed: status $($s.Status), start type $($s.StartType)" }
            else { Say "service-$name" 'FAIL' 'not installed' }
        }
        Save 'services-camera.txt' (Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Frame|Camera|Sensor' } | Format-Table -AutoSize Name, Status, StartType, DisplayName | Out-String -Width 400)
        $file = Join-Path $env:windir 'System32\mfsensorgroup.dll'
        if (Test-Path $file) { Say 'mfsensorgroup' 'PASS' "present, file version $((Get-Item $file).VersionInfo.FileVersion)" }
        else { Say 'mfsensorgroup' 'FAIL' 'not in System32' }
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ProbeExport {
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryExW(string name, IntPtr file, uint flags);
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
}
'@
        $module = [ProbeExport]::LoadLibraryExW('mfsensorgroup.dll', [IntPtr]::Zero, 0x800) # LOAD_LIBRARY_SEARCH_SYSTEM32
        if ($module -eq [IntPtr]::Zero) {
            Say 'export' 'FAIL' "mfsensorgroup.dll does not load: error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        } elseif ([ProbeExport]::GetProcAddress($module, 'MFCreateVirtualCamera') -ne [IntPtr]::Zero) {
            Say 'export' 'PASS' 'mfsensorgroup.dll exports MFCreateVirtualCamera'
        } else {
            Say 'export' 'FAIL' 'mfsensorgroup.dll has no MFCreateVirtualCamera'
        }
        $consent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
        foreach ($key in @("HKLM:\$consent", "HKCU:\$consent", "HKCU:\$consent\NonPackaged")) {
            $value = (Get-ItemProperty -Path $key -Name Value -ErrorAction SilentlyContinue).Value
            Say 'camera-privacy' 'INFO' "$key Value=$(if ($value) { $value } else { '(none)' })"
        }
    }

    # 2. start the camera services if they are stopped; let desktop apps use the camera
    'start' {
        foreach ($name in $services) {
            $s = Get-Service -Name $name -ErrorAction SilentlyContinue
            if (-not $s) { Say "start-$name" 'SKIP' 'not installed'; continue }
            if ($s.Status -eq 'Running') { Say "start-$name" 'INFO' 'already running'; continue }
            if ($s.StartType -eq 'Disabled') {
                Set-Service -Name $name -StartupType Manual -ErrorAction SilentlyContinue
                Say "start-$name" 'INFO' "start type was Disabled, set to Manual for the run"
            }
            try {
                Start-Service -Name $name -ErrorAction Stop
                Say "start-$name" 'PASS' "started: status $((Get-Service -Name $name).Status)"
            } catch {
                Say "start-$name" 'FAIL' "Start-Service: $($_.Exception.Message)"
            }
        }
        # the camera/MF/PnP event channels that are off: on for the run (read at the end)
        $enabled = @()
        foreach ($c in @(Get-CameraChannels)) {
            if ($c.IsEnabled) { continue }
            wevtutil sl $c.LogName /e:true /q:true 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $enabled += $c.LogName }
        }
        $enabled | Out-File -FilePath $enabledList -Encoding utf8
        Say 'event-channels' 'INFO' "enabled for the run: $($enabled.Count) channel(s): $($enabled -join ', ')"
        # MFCreateVirtualCamera fails with E_ACCESSDENIED when camera privacy denies it.
        # A throwaway runner: allow, and say so.
        $consent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
        foreach ($key in @("HKLM:\$consent", "HKCU:\$consent", "HKCU:\$consent\NonPackaged")) {
            New-Item -Path $key -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $key -Name Value -Value 'Allow' -ErrorAction SilentlyContinue
            Say 'camera-privacy' 'INFO' "$key Value set to Allow for the run"
        }
    }

    # 3. the media source DLL and the probe, with the image's MSVC; register the DLL
    'build' {
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        $vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
        $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
        $flags = '/nologo /std:c++17 /EHsc /O2 /W4 /permissive- /utf-8 /DUNICODE /D_UNICODE ' +
            '/DWINVER=0x0A00 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A00000C'
        # the workspace paths have no spaces: only vcvarsall's path is quoted, as in the
        # kit's other cmd /c calls (with exactly one quoted path, cmd keeps its quotes)
        if ("$src$bin" -match ' ') { Say 'build' 'FAIL' "a space in $src or $bin"; exit 1 }
        # /MT: the static CRT, so Frame Server's svchost needs no vcruntime/msvcp DLL (v3;
        # Microsoft's VirtualCamera sample builds its source with MultiThreaded too)
        $dllCmd = "cl $flags /MT /LD /Fe:probe-camera-source.dll $src\dllmain.cpp $src\media_source.cpp " +
            "$src\dll_log.cpp $src\pattern.cpp /link /DEF:$src\probe-camera-source.def mfplat.lib mfuuid.lib " +
            'ole32.lib advapi32.lib'
        $exeCmd = "cl $flags /MT /Fe:probe-camera-winvcam.exe $src\probe.cpp $src\pattern.cpp " +
            '/link mfplat.lib mf.lib mfreadwrite.lib mfuuid.lib ole32.lib'
        $depsCmd = 'dumpbin /nologo /dependents probe-camera-source.dll'
        # native tools first; on the Arm image fall back to the x64-hosted cross tools
        $hosts = if ($Arch -eq 'arm64') { @('arm64', 'x64_arm64') } else { @('x64') }
        $built = $false
        foreach ($h in $hosts) {
            $output = cmd /c "`"$vcvars`" $h >nul && cd /d $bin && $dllCmd && $exeCmd && $depsCmd" 2>&1
            Save "build-$h.txt" $output
            if ($LASTEXITCODE -eq 0) {
                $built = $true
                Say 'build' 'PASS' "MSVC vcvarsall $h, static CRT (/MT)"
                $deps = @($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[\w.-]+\.dll$' -and $_ -notmatch '^probe-camera' })
                Say 'build-deps' 'INFO' "probe-camera-source.dll imports: $($deps -join ', ')"
                break
            }
            Say 'build' 'INFO' "vcvarsall $h failed (exit $LASTEXITCODE), see build-$h.txt"
        }
        if (-not $built) {
            Say 'build' 'FAIL' 'no MSVC build (our code or the image), see build-*.txt'
            Get-Content (Join-Path $Out "build-$($hosts[-1]).txt") | Select-Object -Last 40
            exit 1
        }

        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Copy-Item -Path (Join-Path $bin 'probe-camera-source.dll') -Destination $dll -Force
        # LOCAL SERVICE (Frame Server): read and write (the DLL writes its logs here);
        # LOCAL SYSTEM (Frame Server Monitor) and ALL APPLICATION PACKAGES: read
        $acl = icacls $installDir /grant '*S-1-5-19:(OI)(CI)M' '*S-1-5-18:(OI)(CI)RX' '*S-1-15-2-1:(OI)(CI)RX' 2>&1
        Save 'icacls.txt' ($acl + (icacls $installDir 2>&1))
        Say 'install' 'INFO' "copied to $dll; Local Service may read and write (dll-<pid>.log), Local System and all app packages read"
        $reg = Start-Process -FilePath "$env:windir\System32\regsvr32.exe" -ArgumentList '/s', "`"$dll`"" -Wait -PassThru
        $server = (Get-ItemProperty 'HKLM:\SOFTWARE\Classes\CLSID\{126FE889-6B3B-4B75-875E-B7B866BE7DB5}\InprocServer32' -ErrorAction SilentlyContinue)
        if (($reg.ExitCode -eq 0) -and $server) {
            Say 'register' 'PASS' "regsvr32 exit 0, InprocServer32=$($server.'(default)') ThreadingModel=$($server.ThreadingModel)"
        } else {
            Say 'register' 'FAIL' "regsvr32 exit $($reg.ExitCode), HKLM key present: $([bool]$server)"
            exit 1
        }
    }

    # 4. the probe itself (probe.cpp): in-process read, then the virtual camera
    'probe' {
        if (-not (Test-Path $exe)) { Say 'probe' 'FAIL' 'no probe executable (build stage)'; exit 1 }
        $self = Join-Path $PSScriptRoot 'probe-camera-winvcam.ps1'
        $env:PROBECAM_ON_START_FAIL = "pwsh -NoProfile -File `"$self`" -Stage snapshot -Arch $Arch -Out `"$Out`" -Runner $Runner -Tag {step}"
        $output = & $exe run $dll 2>&1
        $code = $LASTEXITCODE
        Save 'probe-exe.txt' $output
        foreach ($l in $output) {
            if ("$l" -match '^PROBE ') { Add-Content -Path $log -Value "$l" -Encoding utf8 }
            Write-Host "$l"
        }
        Say 'probe-exit' 'INFO' "probe-camera-winvcam.exe exit code $code"
        Snapshot-Pnp 'after-probe'
        Copy-DllLogs
        Copy-Wer
        Collect-Events 'after-probe' 30 $true
        if ($code -eq 1 -or $code -eq 2) {
            Say 'probe' 'FAIL' 'our media source failed in process (or the probe itself failed): see probe-exe.txt'
            exit 1
        }
    }

    # while a camera whose Start failed still exists (run by probe-camera-winvcam.exe)
    'snapshot' {
        Snapshot-Pnp $Tag
        Collect-Events $Tag 5 $false
        Copy-DllLogs
    }

    # 5. remove any camera left behind and the registration
    'cleanup' {
        if (Test-Path $exe) {
            $output = & $exe remove 2>&1
            Save 'remove-exe.txt' $output
            foreach ($l in $output) { if ("$l" -match '^PROBE ') { Add-Content -Path $log -Value "$l" -Encoding utf8 } }
        }
        if (Test-Path $dll) {
            $reg = Start-Process -FilePath "$env:windir\System32\regsvr32.exe" -ArgumentList '/s', '/u', "`"$dll`"" -Wait -PassThru
            Say 'unregister' 'INFO' "regsvr32 /u exit $($reg.ExitCode)"
        }
        Copy-DllLogs
    }

    # the job summary: one table for this runner
    'summary' {
        $rows = @()
        if (Test-Path $log) { $rows = Get-Content $log -Encoding utf8 | Where-Object { $_ -match '^PROBE ' } }
        $md = @("### probe-camera-winvcam on $Runner ($Arch)", '', '| Step | Result | Detail |', '|---|---|---|')
        foreach ($r in $rows) {
            $parts = $r -split ' ', 4
            $detail = if ($parts.Count -ge 4) { $parts[3] -replace '\|', '\|' } else { '' }
            $md += "| $($parts[1]) | $($parts[2]) | $detail |"
        }
        $md += ''
        if ($env:GITHUB_STEP_SUMMARY) { $md | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
        $md | Out-File -FilePath (Join-Path $Out 'summary.md') -Encoding utf8 -Width 400
        $md | ForEach-Object { Write-Host $_ }
    }
}
exit 0

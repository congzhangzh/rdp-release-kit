# probe-camera-winvcam: can a GitHub-hosted Windows runner register a Media Foundation
# virtual camera (MFCreateVirtualCamera, documented for Windows 11 build 22000+ with no
# minimum server version), and can an app read frames from it through Frame Server?
# A record for the shadow server's virtual camera (freerdp-comp-camera-g1, 2026-11-27, W0
# of the shadow camera design). Run by .github/workflows/probe-camera-winvcam.yml;
# publishes nothing.
#
#   probe-camera-winvcam.ps1 -Stage <info|start|build|probe|cleanup|summary>
#                            -Arch <x64|arm64> -Out <dir> [-Runner <label>]
#
# Each stage appends "PROBE <step> <PASS|FAIL|SKIP|INFO> <detail>" lines to $Out\probe.log;
# summary turns them into a table in the job summary. A missing API, service or camera is
# a result. Only a failure of our own code (the build, regsvr32 of our DLL, the in-process
# read of our media source) fails the job.
param(
    [Parameter(Mandatory)] [ValidateSet('info', 'start', 'build', 'probe', 'cleanup', 'summary')] [string] $Stage,
    [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string] $Arch,
    [Parameter(Mandatory)] [string] $Out,
    [string] $Runner = ''
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
        $dllCmd = "cl $flags /LD /Fe:probe-camera-source.dll $src\dllmain.cpp $src\media_source.cpp " +
            "$src\pattern.cpp /link /DEF:$src\probe-camera-source.def mfplat.lib mfuuid.lib ole32.lib advapi32.lib"
        $exeCmd = "cl $flags /Fe:probe-camera-winvcam.exe $src\probe.cpp $src\pattern.cpp " +
            '/link mfplat.lib mf.lib mfreadwrite.lib mfuuid.lib ole32.lib'
        # native tools first; on the Arm image fall back to the x64-hosted cross tools
        $hosts = if ($Arch -eq 'arm64') { @('arm64', 'x64_arm64') } else { @('x64') }
        $built = $false
        foreach ($h in $hosts) {
            $output = cmd /c "`"$vcvars`" $h >nul && cd /d $bin && $dllCmd && $exeCmd" 2>&1
            Save "build-$h.txt" $output
            if ($LASTEXITCODE -eq 0) { $built = $true; Say 'build' 'PASS' "MSVC vcvarsall $h"; break }
            Say 'build' 'INFO' "vcvarsall $h failed (exit $LASTEXITCODE), see build-$h.txt"
        }
        if (-not $built) {
            Say 'build' 'FAIL' 'no MSVC build (our code or the image), see build-*.txt'
            Get-Content (Join-Path $Out "build-$($hosts[-1]).txt") | Select-Object -Last 40
            exit 1
        }

        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Copy-Item -Path (Join-Path $bin 'probe-camera-source.dll') -Destination $dll -Force
        # LOCAL SERVICE (Frame Server), LOCAL SYSTEM (Frame Server Monitor), ALL APPLICATION PACKAGES
        $acl = icacls $installDir /grant '*S-1-5-19:(OI)(CI)RX' '*S-1-5-18:(OI)(CI)RX' '*S-1-15-2-1:(OI)(CI)RX' 2>&1
        Save 'icacls.txt' ($acl + (icacls $installDir 2>&1))
        Say 'install' 'INFO' "copied to $dll, read granted to Local Service, Local System, all app packages"
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
        $output = & $exe run $dll 2>&1
        $code = $LASTEXITCODE
        Save 'probe-exe.txt' $output
        foreach ($l in $output) {
            if ("$l" -match '^PROBE ') { Add-Content -Path $log -Value "$l" -Encoding utf8 }
            Write-Host "$l"
        }
        Save 'devices-camera.txt' (Get-PnpDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.Class -in @('Camera', 'Image', 'SoftwareComponent') -or $_.FriendlyName -match 'probe-camera' } |
            Format-Table -AutoSize Status, Class, FriendlyName, InstanceId | Out-String -Width 400)
        Get-WinEvent -LogName 'Microsoft-Windows-FrameServer/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue |
            Format-List TimeCreated, Id, LevelDisplayName, Message | Out-File (Join-Path $Out 'frameserver-events.txt') -Width 400
        Say 'probe-exit' 'INFO' "probe-camera-winvcam.exe exit code $code"
        if ($code -eq 1 -or $code -eq 2) {
            Say 'probe' 'FAIL' 'our media source failed in process (or the probe itself failed): see probe-exe.txt'
            exit 1
        }
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

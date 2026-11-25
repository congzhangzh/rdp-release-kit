# probe-iddcx: can a GitHub-hosted Windows runner get a second monitor from an IddCx
# virtual display driver, and does DXGI desktop duplication see real pictures on it?
# A record for the shadow server's "share all monitors" design (freerdp-comp-shadow-g5,
# 2026-11-25). Run by .github/workflows/probe-iddcx.yml; publishes nothing.
#
# Every stage writes its evidence into $Out and a line into $Out\verdict.txt. A stage
# that fails is recorded and the later stages still run where they can: black frames or
# a missing monitor are results, not errors to hide.
#
#   probe-iddcx.ps1 -Zip <driver zip> -Sha256 <expected> -Arch <x64|arm64> -Out <dir>
param(
    [Parameter(Mandatory)] [string] $Zip,
    [Parameter(Mandatory)] [string] $Sha256,
    [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string] $Arch,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$verdict = Join-Path $Out 'verdict.txt'
function Say([string] $line) {
    Write-Host $line
    Add-Content -Path $verdict -Value $line -Encoding utf8
}
function Save([string] $name, $value) {
    $value | Out-File -FilePath (Join-Path $Out $name) -Encoding utf8 -Width 400
}

Say "probe-iddcx arch=$Arch os=$([Environment]::OSVersion.VersionString) user=$env:USERNAME session=$((Get-Process -Id $PID).SessionId)"

# 1. test signing (the hosted images turn it on; catch a drift)
$bcd = (bcdedit /enum '{current}') 2>&1 | Out-String
Save 'bcdedit.txt' $bcd
$testsigning = $bcd -match '(?m)^testsigning\s+Yes'
Say "stage=testsigning ok=$testsigning"

# 2. the pinned driver package
$actual = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash.ToLowerInvariant()
if ($actual -ne $Sha256.ToLowerInvariant()) {
    Say "stage=sha256 ok=False expected=$Sha256 actual=$actual"
    exit 1
}
Say "stage=sha256 ok=True sha256=$actual"
$pkg = Join-Path $Out 'driver'
Expand-Archive -Path $Zip -DestinationPath $pkg -Force
$inf = Get-ChildItem -Path $pkg -Recurse -Filter 'MttVDD.inf' | Select-Object -First 1
$dir = $inf.DirectoryName
foreach ($f in @('MttVDD.dll', 'mttvdd.cat')) {
    $sig = Get-AuthenticodeSignature -FilePath (Join-Path $dir $f)
    Say ("stage=signature file=$f status=$($sig.Status) signer=""$($sig.SignerCertificate.Subject)"" " +
        "issuer=""$($sig.SignerCertificate.Issuer)"" thumbprint=$($sig.SignerCertificate.Thumbprint)")
}

# 3. before: what the runner has. Screen.AllScreens caches its list in a process, so the
# screens come from a new process each time and the count from GetSystemMetrics.
Add-Type -Namespace Probe -Name User32 -MemberDefinition '[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);'
function MonitorCount { [Probe.User32]::GetSystemMetrics(80) } # SM_CMONITORS
function Dump([string] $tag) {
    $screens = pwsh -NoProfile -Command 'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "$($_.DeviceName) primary=$($_.Primary) bounds=$($_.Bounds)" }'
    Save "screens-$tag.txt" $screens
    Say "stage=screens-$tag count=$(@($screens).Count) SM_CMONITORS=$(MonitorCount)"
    Save "pnp-display-$tag.txt" (Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Format-Table -AutoSize Status, FriendlyName, InstanceId | Out-String -Width 400)
    $probeDir = Join-Path $Out "dxgi-$tag"
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    $lines = & (Join-Path $Out 'bin\dxgi-probe.exe') $probeDir 2>&1
    Save "dxgi-$tag.txt" $lines
    foreach ($l in $lines) { if ("$l" -match '^(monitors|adapter|output)') { Say "dxgi-$tag $l" } }
    Add-Type -AssemblyName System.Drawing
    Get-ChildItem -Path $probeDir -Filter '*.bmp' | ForEach-Object {
        $img = [System.Drawing.Image]::FromFile($_.FullName)
        $img.Save([IO.Path]::ChangeExtension($_.FullName, '.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $img.Dispose()
        Remove-Item $_.FullName
    }
}
Dump 'before'

# 4. settings first (the driver reads them when it starts; no reboot to re-read)
New-Item -ItemType Directory -Force -Path 'C:\VirtualDisplayDriver' | Out-Null
Copy-Item -Path (Join-Path $dir 'vdd_settings.xml') -Destination 'C:\VirtualDisplayDriver\vdd_settings.xml' -Force
Save 'vdd_settings.xml' (Get-Content 'C:\VirtualDisplayDriver\vdd_settings.xml')

# 5. the driver package into the store. Run 1 (45653105707) hung in pnputil until the job
# timeout: Windows' "install this device software?" prompt, 🔎. So the signer is trusted
# first (TrustedPublisher skips that prompt for a signature that chains to a trusted root),
# and every installer step has a deadline: on a timeout the screen is captured (the prompt
# itself is the evidence) and the process is killed.
$cert = (Get-AuthenticodeSignature -FilePath (Join-Path $dir 'mttvdd.cat')).SignerCertificate
$s = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
$s.Open('ReadWrite'); $s.Add($cert); $s.Close()
Say "stage=trust store=LocalMachine\TrustedPublisher thumbprint=$($cert.Thumbprint)"

function Bounded([string] $name, [string] $exe, [string[]] $arguments, [int] $seconds) {
    $log = Join-Path $Out "$name.txt"
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError (Join-Path $Out "$name.err.txt")
    if ($p.WaitForExit($seconds * 1000)) {
        Say "stage=$name ok=$($p.ExitCode -eq 0) rc=$($p.ExitCode)"
        return
    }
    $shot = Join-Path $Out "hang-$name"
    New-Item -ItemType Directory -Force -Path $shot | Out-Null
    & (Join-Path $Out 'bin\dxgi-probe.exe') $shot *> (Join-Path $Out "hang-$name.txt")
    Get-ChildItem -Path $shot -Filter '*.bmp' | ForEach-Object {
        $img = [System.Drawing.Image]::FromFile($_.FullName)
        $img.Save([IO.Path]::ChangeExtension($_.FullName, '.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $img.Dispose(); Remove-Item $_.FullName
    }
    $windows = Get-Process | Where-Object { $_.MainWindowTitle } |
        ForEach-Object { "$($_.ProcessName) pid=$($_.Id) title=""$($_.MainWindowTitle)""" }
    Save "hang-$name-windows.txt" $windows
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Say "stage=$name ok=False timeout=${seconds}s windows=$(@($windows).Count) (screen in hang-$name)"
}
Add-Type -AssemblyName System.Drawing
Bounded 'pnputil' 'pnputil.exe' @('/add-driver', $inf.FullName, '/install') 120

# 6. the root device node
Bounded 'devnode' (Join-Path $Out 'bin\devnode.exe') @($inf.FullName, 'Root\MttVDD', 'Display') 120

# 7. wait for the monitor (up to 30 s), then after
$deadline = (Get-Date).AddSeconds(30)
while (((Get-Date) -lt $deadline) -and ((MonitorCount) -lt 2)) {
    Start-Sleep -Milliseconds 500
}
Say "stage=wait SM_CMONITORS=$(MonitorCount)"
Save 'pnp-mttvdd.txt' (Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'MttVDD|MTT1337' } |
    Format-List Status, Problem, ConfigManagerErrorCode, FriendlyName, InstanceId | Out-String -Width 400)
Dump 'after'

# 8. the verdict: a monitor of the driver, and a white window on it seen by duplication
$after = Get-Content (Join-Path $Out 'dxgi-after.txt')
$outputs = @($after | Where-Object { $_ -match '^output=' })
$white = @($outputs | Where-Object {
        ($_ -match ' pixels=(\d+) white=(\d+)') -and ([double]$Matches[2] -ge 0.5 * [double]$Matches[1]) })
Say "stage=verdict SM_CMONITORS=$(MonitorCount) dxgi_outputs=$($outputs.Count) outputs_white_ge_50pct=$($white.Count)"
exit 0

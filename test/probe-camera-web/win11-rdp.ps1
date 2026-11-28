# win11-rdp.ps1 (a probe: publishes nothing; every change it makes stays on the runner, which is
# thrown away): FreeRDP Web's camera into Windows 11's own Remote Desktop, on windows-11-arm.
# The page (served from http://localhost, a secure context) runs in headless Edge with Chromium's
# fake camera, ticks Camera and signs in as runneradmin through ws-gateway.py to this PC's own RDP
# (127.0.0.2:3389). As probe-camera-win's option A (f38db99), the sign-in takes the console
# session over, so this script's session becomes the RDP session, and mf-camera-reader.exe,
# started in it, opens the redirected camera (the browser's), reads its frames and names the type.
#
#   win11-rdp.ps1 -Page <page dir> -Reader <mf-camera-reader.exe> -Out <out dir>
#
# The password is random for this run, masked first, never logged; the browser gets it through
# its environment only. Checks: PASS/FAIL lines in <out>\checks.txt, one line in <out>\result.txt.
param([string]$Page, [string]$Reader, [string]$Out)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Page = (Resolve-Path $Page).Path
$Reader = (Resolve-Path $Reader).Path
$Out = (Resolve-Path $Out).Path
$Here = $PSScriptRoot
$user = "runneradmin"
$pass = "Camera-7" + [guid]::NewGuid().ToString("N").Substring(0, 12)
Write-Host "::add-mask::$pass"
$frames = 60
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

# --- the host: Windows' own Remote Desktop, camera redirection allowed (as probe-camera-win)
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$runner = "$env:ImageOS $($os.Caption) $($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)"
Fact "os: $runner"
$ts = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
$pol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
Set-ItemProperty -Path $pol -Name fDisableCameraRedir -Value 0 -Type DWord
foreach ($s in "FrameServer", "FrameServerMonitor") {
    try { Start-Service -Name $s -ErrorAction Stop; Fact "started $s`: $((Get-Service $s).Status)" }
    catch { Fact "start $s failed: $($_.Exception.Message)" }
}
Set-ItemProperty $ts fDenyTSConnections 0
if ($env:USERNAME -ne $user) {
    Result "$runner`: A failed: the job does not run as runneradmin but as $env:USERNAME"
    throw "A failed: the job does not run as runneradmin"
}
net user $user $pass | Out-Null
if ($LASTEXITCODE -ne 0) { Result "$runner`: A failed: net user exit $LASTEXITCODE"; throw "A failed: net user" }
Check "rdp: Windows' own Remote Desktop listens on 3389" (Until 30 { Listening 3389 })

# --- the browser: Chrome (else Edge), the page from localhost, the gateway to 127.0.0.2:3389
#     (this PC's own server refuses 127.0.0.1): ws-gateway.py, as websockify does not install on
#     Windows on Arm (its cryptography dependency: no wheel, no OpenSSL to build it; run
#     46139068111)
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$browser = if ($chrome) { $chrome } else { $edge }
Fact "browser: $browser $((Get-Item $browser).VersionInfo.ProductVersion) (Chrome there: $([bool]$chrome), Edge there: $([bool]$edge))"
$py = (Get-Command python -ErrorAction Stop).Source
& $py -m pip install --quiet --only-binary=:all: websockets==17.4 2>&1 | Out-File "$Out\pip.log"
Fact "gateway: ws-gateway.py with websockets $(& $py -c 'import websockets; print(websockets.__version__)' 2>&1)"
$http = Start-Process -FilePath $py -PassThru -WindowStyle Hidden -RedirectStandardOutput "$Out\http.log" -RedirectStandardError "$Out\http.err" `
    -ArgumentList "-m", "http.server", "8080", "--bind", "127.0.0.1", "-d", "`"$Page`""
$wsk = Start-Process -FilePath $py -PassThru -WindowStyle Hidden -RedirectStandardOutput "$Out\gateway.log" -RedirectStandardError "$Out\gateway.err" `
    -ArgumentList "`"$Here\ws-gateway.py`"", "127.0.0.1:13390", "127.0.0.2:3389"
Check "the page server and the gateway listen" (Until 30 { (Listening 8080) -and (Listening 13390) })

# --- the reader, the browser, the session
$dir = "C:\kitcam"
New-Item -ItemType Directory -Force -Path "$dir\out" | Out-Null
Copy-Item $Reader "$dir\mf-camera-reader.exe"
$readerLog = "$dir\out\reader.log"
# --match "": the first camera there; it logs them all, so the record says what Windows names the
# browser's redirected camera
$readerArgs = "camera --match `"`" --frames $frames --min-seconds 5 --wait 120 --timeout 200"
function UserSession { [bool]((quser 2>$null) -match "^\s*>?$user\s+rdp-tcp#[0-9]+\s+[0-9]+\s+Active") }
$env:CHROME = $browser
$env:WEB_USER = $user
$env:WEB_PASS = $pass
$node = $null
$result = $null
try {
    $node = Start-Process -FilePath (Get-Command node).Source -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$Out\browser.txt" -RedirectStandardError "$Out\browser.err" `
        -ArgumentList "`"$Here\web-camera.mjs`"", "http://localhost:8080/", "127.0.0.1:13390", "`"$Out`"", "`"$Out\reader-done`""
    $session = Until 120 { (UserSession) -or $node.HasExited }
    $session = $session -and (UserSession)
    Check "rdp: the runneradmin session on rdp-tcp, Active while the browser is connected" $session ((quser 2>$null) -join " | ")
    if ($session) {
        Start-Process -FilePath "$dir\mf-camera-reader.exe" -WindowStyle Hidden -ArgumentList "$readerArgs --log `"$readerLog`""
        $null = Until 30 { Test-Path $readerLog }
        $done = Until 150 { (Test-Path $readerLog) -and (Select-String -Path $readerLog -Pattern " RESULT " -Quiet) }
        Fact "the reader's RESULT came: $done"
    }
    New-Item -ItemType File -Force -Path "$Out\reader-done" | Out-Null
    $null = Until 60 { $node.HasExited }
    if (Test-Path $readerLog) {
        Copy-Item $readerLog "$Out\reader.log" -ErrorAction SilentlyContinue
        $result = Select-String -Path $readerLog -Pattern "^\S+ RESULT (.*)$" | Select-Object -Last 1 | ForEach-Object { $_.Matches[0].Groups[1].Value }
    }
}
finally {
    foreach ($p in $node, $wsk, $http) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    Fact "sessions at the end: $((quser 2>$null) -join ' | ')"
}

# --- the verdicts
$b = if (Test-Path "$Out\browser.txt") { Get-Content "$Out\browser.txt" -Raw } else { "" }
$p = if (Test-Path "$Out\page.log") { Get-Content "$Out\page.log" -Raw } else { "" }
$got = if ("$result" -match "frames=([0-9]+)") { [int]$Matches[1] } else { 0 }
$distinct = if ("$result" -match "distinct=([0-9]+)") { [int]$Matches[1] } else { 0 }
$open = if ("$result" -match "open=([0-9.]+) s") { [double]$Matches[1] } else { 0 }
$type = if ("$result" -match "type=(\S+)") { $Matches[1] } else { "" }
$errors = @([regex]::Matches($p, "\[(ERROR|WARN)\]\[com\.freerdp\.channels\.rdpecam[^\r\n]*|\[rdpecam\] camera [^\r\n]* failed[^\r\n]*") | ForEach-Object Value)
Check "page: Camera offered (the browser encodes H.264)" ($b -match '"checkboxDisabled":false')
Check "page: the browser allowed the camera after Camera was ticked" ($b -match '"permission":"allowed"')
Check "camera: the session's app read $frames frames, the camera open 5 s or more" ($got -ge $frames -and $open -ge 5) "$result"
Check "camera: the frames change (more than 10 distinct)" ($distinct -gt 10) "distinct=$distinct"
Check "camera: the media type is named" ($type -match "^[A-Z0-9]{4}$") "type=$type"
Check "client: H264 started and its first sample sent" (($p -match "camera web0: start H264 ") -and ($p -match "camera web0: first H264 sample")) `
    (([regex]::Match($p, "camera web0: first H264 sample[^\r\n`"]*")).Value)
Check "client: no camera error" ($errors.Count -eq 0) "$($errors.Count)$(if ($errors) { ': ' + $errors[0] })"
Fact "client: $(([regex]::Match($p, 'camera web0: start H264 [^\r\n"]*')).Value)"
Fact "client: $(([regex]::Match($p, 'camera web0 stopped: H264 [^\r\n"]*')).Value)"
Get-Content "$Out\checks.txt"
$verdict = if ($fails) { "$fails check(s) failed" } else { "the browser's camera reaches Windows 11's own Remote Desktop as H.264" }
Result "$runner`: $verdict; reader: $result"
if ($fails -gt 0) { throw "$fails check(s) failed" }

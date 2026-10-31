# The freerdp-tk demo on Windows: the kit's Windows client, unpacked from its
# zip in a PowerShell window as a user would, freerdp-tk started from it, and a
# connection to Windows' own Remote Desktop on this same PC (127.0.0.2, a
# session of its own for the user): Notepad and a line, then webdemo (Big Buck
# Bunny next to the WebGL Aquarium in Firefox, its sound through the session),
# disconnect, freerdp-tk again, the saved connection opened with the password
# from Windows' Credential Manager. Run by test/windows-host.ps1, after its
# web demo (whose webdemo.cmd and 127.0.0.1:8000 it uses):
#
#   windows.ps1 <client zip> <user> <password> <out dir>
#
# hook/drive.py works freerdp-tk's window from inside its process (wininput.py:
# SendInput), as run.sh's on Linux; the screen is recorded with ffmpeg
# (gdigrab), the sound with WASAPI loopback (winrec.py). Out: freerdp-tk-windows.mp4
# and .jpg in <out dir>, the driver's log and the raw files in <out dir>\tk-demo.
param([string]$Zip, [string]$User, [string]$Pass, [string]$Out)
$ErrorActionPreference = "Stop"
$Zip = (Resolve-Path $Zip).Path
$Out = (Resolve-Path $Out).Path
$here = $PSScriptRoot
$work = "$Out\tk-demo"
New-Item -ItemType Directory -Force -Path $work | Out-Null
function Say($what) { "$(Get-Date -Format HH:mm:ss) $what" | Tee-Object -FilePath "$work\run.log" -Append }
function Hands { & python "$here\hook\wininput.py" @args 2>&1 | ForEach-Object { Say "wininput: $_" } }

# (windows-host.ps1 has opened Windows' own Remote Desktop to the user, started the
# audio service and made the user's profile)
Say "Audiosrv: $((Get-Service Audiosrv).Status); profile: $(Test-Path "C:\Users\$User")"
& python -m pip install --quiet soundcard numpy 2>&1 | Out-File "$work\pip.log"

# the user's folder with the zip, and a PowerShell window there
$desk = "C:\Users\Public\Downloads"
Copy-Item $Zip $desk
$name = [IO.Path]::GetFileNameWithoutExtension($Zip)
$env:CLIENT_DEMO_DIR = $work
$env:CLIENT_DEMO_MODE = "windows"
$env:CLIENT_DEMO_USER = $User
$env:CLIENT_DEMO_PASSWORD = $Pass   # synthetic, made for this throwaway machine
Set-Content "$work\phase" "1"
$shell = Start-Process powershell -PassThru -WorkingDirectory $desk -ArgumentList "-NoLogo", "-NoExit", "-Command",
    "`$Host.UI.RawUI.WindowTitle = 'PowerShell'; function prompt { 'PS C:\Users\Public\Downloads> ' }"
Start-Sleep -Seconds 3
Hands place "^PowerShell$" 40 560 900 300

# the recording: the screen at 30 fps, the speakers alongside
$stop = "$work\stop"
$rec = New-Object System.Diagnostics.Process
$rec.StartInfo.FileName = (Get-Command ffmpeg).Source
$rec.StartInfo.Arguments = "-hide_banner -loglevel error -y -f gdigrab -draw_mouse 1 -framerate 30 -i desktop " +
    "-c:v libx264 -preset veryfast -crf 16 -pix_fmt yuv420p `"$work\raw.mp4`""
$rec.StartInfo.UseShellExecute = $false
$rec.StartInfo.RedirectStandardInput = $true
$videoStart = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000
$rec.Start() | Out-Null
$sound = Start-Process python -PassThru -NoNewWindow -RedirectStandardOutput "$work\winrec.log" -RedirectStandardError "$work\winrec.err" `
    -ArgumentList "$here\winrec.py", "$work\sound.wav", $stop
Start-Sleep -Seconds 2

function UntilMark($mark, $seconds) {
    for ($i = 0; $i -lt $seconds * 4; $i++) {
        if (Test-Path "$work\failed") { Say "the driver failed: $(Get-Content "$work\failed" -Raw)"; return $false }
        if (Test-Path "$work\$mark") { return $true }
        Start-Sleep -Milliseconds 250
    }
    Say "no $mark after $seconds s"; return $false
}
$ok = $false
try {
    # as a user: look, unpack, start freerdp-tk; the hook goes next to it (as run.sh does)
    Hands front "^PowerShell$"
    Hands type "dir"; Hands key Return
    Start-Sleep -Seconds 1.5
    Hands type "Expand-Archive $name.zip ."; Hands key Return
    # unpacked when the launcher, freerdp-tk's package and Python are there and the folder
    # stops growing (a zip's order varies: the round's own zip had freerdp-tk.cmd before
    # lib\, and the hook's copy failed, run 41184572213)
    $dir = "$desk\$name"
    $need = "$dir\freerdp-tk.cmd", "$dir\lib\freerdp-tk\freerdp_tk\__main__.py", "$dir\python\pythonw.exe"
    $last = -1
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if (@($need | Where-Object { -not (Test-Path $_) }).Count) { continue }
        $n = @(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($n -eq $last) { break }
        $last = $n
    }
    Say "unpacked: $last files"
    Start-Sleep -Seconds 1
    Copy-Item "$here\hook\*.py" "$desk\$name\lib\freerdp-tk\"
    Hands type ".\$name\freerdp-tk.cmd"; Hands key Return
    if (UntilMark "phase1-done" 300) {
        # freerdp-tk quits; started again, it lists the saved connection. The session it left
        # (disconnected, not signed out) still plays the video and draws the Aquarium in
        # software: closed now, or freerdp-tk's "/version" check of the client (5 s) timed
        # out on the busy runner and it refused the client (run 41180196907)
        Get-Process firefox -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like "*\$User" } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 40 -and (Get-Process pythonw -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
        Start-Sleep -Seconds 1.5
        Hands front "^PowerShell$"
        Hands key Up; Start-Sleep -Milliseconds 800; Hands key Return
        $ok = UntilMark "done" 150
    }
} finally {
    Start-Sleep -Seconds 1
    Set-Content $stop "stop"
    $rec.StandardInput.Write("q"); $rec.StandardInput.Close()
    $rec.WaitForExit(30000) | Out-Null
    $sound.WaitForExit(15000) | Out-Null
    Get-Process pythonw, sdl-freerdp, firefox, notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $shell.Id -Force -ErrorAction SilentlyContinue
    # the demo user's session on this PC's Remote Desktop: signed out
    (quser 2>$null) -match "^\s*$User\s" | ForEach-Object { $id = ($_ -split "\s+" | Where-Object { $_ -match "^\d+$" })[0]; if ($id) { logoff $id } }
}

# the site's form, as test/record-demos.sh makes it: 720p, H.264 CRF 28, AAC 96 kbit/s,
# a poster from 60 %; the sound at its measured offset from the video's start
if ((Test-Path "$work\raw.mp4") -and $ok) {
    $len = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 "$work\raw.mp4")
    $audio = @("-an")
    if ((Test-Path "$work\sound.wav") -and (Test-Path "$work\sound.wav.start")) {
        $offset = [double](Get-Content "$work\sound.wav.start") - $videoStart
        $audio = @("-itsoffset", ("{0:F3}" -f $offset), "-i", "$work\sound.wav", "-map", "0:v", "-map", "1:a")
        Say ("sound: {0:F2} s after the video's start" -f $offset)
    }
    & ffmpeg -v error -y -i "$work\raw.mp4" @audio -vf "scale=1280:720:flags=lanczos,format=yuv420p" `
        -c:v libx264 -crf 28 -preset slow -c:a aac -b:a 96k -shortest -movflags +faststart "$Out\freerdp-tk-windows.mp4"
    & ffmpeg -v error -y -ss ("{0:F1}" -f ($len * 0.6)) -i "$work\raw.mp4" -frames:v 1 `
        -vf "scale=1280:720:flags=lanczos" -q:v 4 "$Out\freerdp-tk-windows.jpg"
}
Say "done: $ok"
if (-not $ok) { exit 1 }

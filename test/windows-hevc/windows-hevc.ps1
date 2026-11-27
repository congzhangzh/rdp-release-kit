# The Windows client's HEVC decoders on a Windows runner:
#
#   ./test/windows-hevc/windows-hevc.ps1 <kit-hevc-decode exe> <streams dir> <out dir>
#
# Runs kit-hevc-decode.exe (built in the client's own build tree, build/build-windows-client.sh)
# on make-streams.sh's two pictures with FreeRDP's log at DEBUG, keeps each log in <out dir>.
# Which decoder takes HEVC 4:2:0 depends on the machine: Media Foundation when Windows has an
# HEVC decoder for it (the HEVC Video Extensions; GitHub's Windows 11 on ARM image has one, kit
# probe run 46029095346), else FFmpeg. So each run passes only when:
#  - 4:2:0: the exe says PASS (one picture, every quadrant within 24 of its colour), and either
#    Media Foundation decoded it ("HEVC decoder: MediaFoundation"), or FFmpeg did
#    ("HEVC decoder: libavcodec (software)") after Media Foundation said why not ("no
#    MediaFoundation HEVC decoder found"). Which one is printed: the record of this machine.
#  - 4:4:4: PASS, decoded by FFmpeg ("HEVC 4:4:4 decoder: libavcodec (software)") after Media
#    Foundation refused it at once ("MediaFoundation has no HEVC 4:4:4"; it outputs 4:2:0 only).
#  - 4:2:0 once more, the exe copied beside a planted "mfplat.dll" (not a DLL at all): the same
#    Media Foundation evidence as the run above. FreeRDP must load Windows' own (System32); with
#    the DLL search order (LoadLibraryA) the planted file comes first, its load fails, and Media
#    Foundation neither decodes nor reaches its decoder lookup. Whether mfplat.dll is one of
#    Windows' KnownDLLs (always the system copy, the hole closed anyway) is printed for the record.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Streams,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$env:WLOG_LEVEL = 'DEBUG'
$script:failed = 0

function Check([string] $name, [bool] $ok) {
    Write-Host ("{0} {1}" -f ($(if ($ok) { 'ok  ' } else { 'FAIL' })), $name)
    if (-not $ok) { $script:failed++ }
}

# decode <name> <profile> <exe>: runs it, keeps the exe's lines and FreeRDP's log in one file
function Decode([string] $name, [string] $prof, [string] $exe) {
    $log = Join-Path $Out "hevc-$name.log"
    $stream = Join-Path $Streams "quadrants-$prof.hevc"
    & $exe $stream $prof *>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log | Out-Host
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $log
    Check "${name}: exit code 0" ($code -eq 0)
    Check "${name}: PASS" ($text -match '(?m): PASS\s*$')
    return $text
}

$mfDecoded = 'HEVC decoder: MediaFoundation'
$mfDeclined = 'no MediaFoundation HEVC decoder found'
$ffDecoded = 'HEVC decoder: libavcodec (software)'

# 4:2:0: Media Foundation or FFmpeg, as this Windows has an HEVC decoder or not
$text = Decode '420' '420' $Exe
$viaMF = $text.Contains($mfDecoded)
if ($viaMF) {
    Write-Host "420: decoded by Media Foundation (this Windows has an HEVC decoder)"
    Check "420: $mfDecoded" $true
} else {
    Write-Host "420: decoded by FFmpeg (this Windows has no HEVC decoder for Media Foundation)"
    Check "420: $ffDecoded" $text.Contains($ffDecoded)
    Check "420: $mfDeclined" $text.Contains($mfDeclined)
}

# 4:4:4: always FFmpeg, Media Foundation refuses it
$text = Decode '444' '444' $Exe
Check "444: HEVC 4:4:4 decoder: libavcodec (software)" $text.Contains('HEVC 4:4:4 decoder: libavcodec (software)')
Check "444: MediaFoundation has no HEVC 4:4:4" $text.Contains('MediaFoundation has no HEVC 4:4:4')

# a planted mfplat.dll beside the program is not loaded: the same Media Foundation evidence
$known = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\KnownDLLs').PSObject.Properties |
    Where-Object { "$($_.Value)" -ieq 'mfplat.dll' }
Write-Host "mfplat.dll among the KnownDLLs: $(if ($known) { 'yes' } else { 'no' })"
$planted = Join-Path $Out 'planted'
New-Item -ItemType Directory -Force -Path $planted | Out-Null
$plantedExe = Join-Path $planted (Split-Path -Leaf $Exe)
Copy-Item $Exe $plantedExe
Set-Content -Path (Join-Path $planted 'mfplat.dll') -Value 'not a DLL: planted beside the program' -Encoding ascii
$text = Decode '420-planted-mfplat' '420' $plantedExe
if ($viaMF) {
    Check "420-planted-mfplat: $mfDecoded (Windows' own mfplat.dll)" $text.Contains($mfDecoded)
} else {
    Check "420-planted-mfplat: $mfDeclined (Windows' own mfplat.dll)" $text.Contains($mfDeclined)
}

"failed: $script:failed" | Tee-Object -FilePath (Join-Path $Out 'summary.txt') -Append | Out-Host
exit $(if ($script:failed -eq 0) { 0 } else { 1 })

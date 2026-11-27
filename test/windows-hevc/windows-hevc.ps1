# The Windows client's HEVC decoders on a Windows runner (no HEVC Video Extensions there):
#
#   ./test/windows-hevc/windows-hevc.ps1 <kit-hevc-decode exe> <streams dir> <out dir>
#
# Runs kit-hevc-decode.exe (built in the client's own build tree, build/build-windows-client.sh)
# on make-streams.sh's two pictures with FreeRDP's log at DEBUG, keeps each log in <out dir>, and
# passes only when, for each:
#  - the exe says PASS (one picture, every quadrant within 24 of its colour);
#  - FFmpeg decoded it: "decoder libavcodec (software)", and FreeRDP's shared INFO line
#    "HEVC decoder: libavcodec (software)" ("HEVC 4:4:4 decoder: ..." for 4:4:4);
#  - the log shows why Media Foundation did not: 4:2:0 "no MediaFoundation HEVC decoder found"
#    (no HEVC MFT on this Windows), 4:4:4 "MediaFoundation has no HEVC 4:4:4" (refused at once).
# A machine with the HEVC Video Extensions would decode 4:2:0 with Media Foundation instead: this
# script then fails on purpose, it proves the FFmpeg path only.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Streams,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$env:WLOG_LEVEL = 'DEBUG'
$failed = 0
$cases = @(
    @{ Profile = '420'; Codec = 'HEVC'; Why = 'no MediaFoundation HEVC decoder found' },
    @{ Profile = '444'; Codec = 'HEVC 4:4:4'; Why = 'MediaFoundation has no HEVC 4:4:4' }
)
foreach ($c in $cases) {
    $log = Join-Path $Out "hevc-$($c.Profile).log"
    $stream = Join-Path $Streams "quadrants-$($c.Profile).hevc"
    # the exe's own lines and FreeRDP's log, both streams, in one file
    & $Exe $stream $c.Profile *>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log | Out-Host
    $code = $LASTEXITCODE
    $text = Get-Content -Raw $log
    $checks = [ordered]@{
        "exit code 0"                                     = ($code -eq 0)
        "PASS"                                            = ($text -match '(?m): PASS\s*$')
        "decoder libavcodec (software)"                   = $text.Contains('decoder libavcodec (software)')
        "$($c.Codec) decoder: libavcodec (software)"      = $text.Contains("$($c.Codec) decoder: libavcodec (software)")
        "$($c.Why)"                                       = $text.Contains($c.Why)
    }
    foreach ($k in $checks.Keys) {
        $ok = $checks[$k]
        Write-Host ("{0} {1}: {2}" -f ($(if ($ok) { 'ok  ' } else { 'FAIL' })), $c.Profile, $k)
        if (-not $ok) { $failed++ }
    }
}
"failed: $failed" | Tee-Object -FilePath (Join-Path $Out 'summary.txt') -Append | Out-Host
exit $(if ($failed -eq 0) { 0 } else { 1 })

# Does Windows' own OpenSSH server forward to a Unix socket (AF_UNIX)? The
# question behind a Windows host that listens on a socket file, whose ACL says
# who may connect, instead of 127.0.0.1 (branch win-shadow, 2026-10-30):
#
#   win-ssh-unix.ps1 <out dir>
#
# On this (throwaway) runner: the OpenSSH server capability, a key for this
# user, an echo server on a socket file (.NET's UnixDomainSocketEndPoint), then
# ssh -L <port>:<socket file> to this machine, and a line through it. It
# reports what happened, with sshd's and ssh's own words; it never fails.
param([string]$Out)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
function Say($text) { $text | Tee-Object -FilePath "$Out\report.txt" -Append }

Say "OS: $((Get-CimInstance Win32_OperatingSystem).Caption) $((Get-CimInstance Win32_OperatingSystem).Version)"
$cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
Say "capability $($cap.Name): $($cap.State)"
if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Say "ssh client: $((& ssh -V) 2>&1)"
Say "sshd: $((Get-Item "$env:WINDIR\System32\OpenSSH\sshd.exe" -ErrorAction SilentlyContinue).VersionInfo.ProductVersion)"

# a key for this user; an administrator's keys live in administrators_authorized_keys
$key = "$Out\id_ed25519"
& ssh-keygen -q -t ed25519 -N '""' -f $key | Out-Null
if (-not (Test-Path $key)) { & ssh-keygen -q -t ed25519 -N "" -f $key | Out-Null }
$auth = "$env:ProgramData\ssh\administrators_authorized_keys"
New-Item -ItemType Directory -Force -Path "$env:ProgramData\ssh" | Out-Null
Get-Content "$key.pub" | Set-Content -Path $auth -Encoding ascii
& icacls $auth /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
Start-Service sshd
Say "sshd service: $((Get-Service sshd).Status)"

# the echo server on a socket file: one connection, one line back
$sock = "$env:TEMP\kit-echo.sock"
Remove-Item $sock -ErrorAction SilentlyContinue
$echo = Start-ThreadJob -ArgumentList $sock -ScriptBlock {
    param($path)
    $s = [System.Net.Sockets.Socket]::new([System.Net.Sockets.AddressFamily]::Unix,
        [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Unspecified)
    $s.Bind([System.Net.Sockets.UnixDomainSocketEndPoint]::new($path))
    $s.Listen(1)
    $c = $s.Accept()
    $buf = New-Object byte[] 64
    $n = $c.Receive($buf)
    [void]$c.Send([System.Text.Encoding]::ASCII.GetBytes("pong:" + [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)))
    $c.Close(); $s.Close()
}
Start-Sleep -Seconds 2
Say "socket file there: $(Test-Path $sock)"

# the socket directly first (does AF_UNIX work here at all?), then through ssh
function Ping($endpoint, $family) {
    try {
        $c = [System.Net.Sockets.Socket]::new($family, [System.Net.Sockets.SocketType]::Stream,
            [System.Net.Sockets.ProtocolType]::Unspecified)
        $c.ReceiveTimeout = 5000
        $c.Connect($endpoint)
        [void]$c.Send([System.Text.Encoding]::ASCII.GetBytes("ping"))
        $buf = New-Object byte[] 64
        $n = $c.Receive($buf)
        $c.Close()
        return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } catch { return "error: $($_.Exception.Message)" }
}
$port = 5599
# ssh reads "C:" as a separator ("Bad local forwarding specification" on the
# first run): the path without its drive letter, which sshd may resolve on
# its own drive, as written and in lower case
$noDrive = $sock.Substring(2).Replace("\", "/")
$forms = @($noDrive, $noDrive.ToLower())
foreach ($form in $forms) {
    $err = "$Out\ssh-$($forms.IndexOf($form)).err"
    $ssh = Start-Process -FilePath ssh -PassThru -NoNewWindow -RedirectStandardError $err -ArgumentList `
        "-N", "-v", "-i", $key, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=$Out\known_hosts",
        "-L", "${port}:$form", "$env:USERNAME@localhost"
    Start-Sleep -Seconds 5
    $reply = Ping ([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, $port)) ([System.Net.Sockets.AddressFamily]::InterNetwork)
    Say "ssh -L ${port}:$form -> $reply"
    Get-Content $err -ErrorAction SilentlyContinue | Select-String -Pattern "forward|open failed|channel|streamlocal|prohibited|denied|refused|Authenticated" |
        Select-Object -First 12 | ForEach-Object { Say "   ssh: $($_.Line)" }
    if (-not $ssh.HasExited) { Stop-Process -Id $ssh.Id -Force }
    $port++
}
# if ssh never reached it, the echo server is still waiting: try it directly
if ($echo.State -eq "Running") {
    Say "direct AF_UNIX connect -> $(Ping ([System.Net.Sockets.UnixDomainSocketEndPoint]::new($sock)) ([System.Net.Sockets.AddressFamily]::Unix))"
}
Receive-Job $echo -ErrorAction SilentlyContinue 2>&1 | ForEach-Object { Say "echo server: $_" }
Remove-Job $echo -Force -ErrorAction SilentlyContinue
# sshd's own log, when it wrote one
Get-WinEvent -LogName "OpenSSH/Operational" -MaxEvents 30 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "forward|streamlocal|channel|refused|denied" } |
    ForEach-Object { Say "   sshd: $($_.Message)" }
exit 0

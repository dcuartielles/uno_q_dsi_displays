# Same contract as run-on-board.ps1, but over SSH instead of ADB.
#
# Needed once the UNO Q's USB-C port is used for power rather than a PC data
# connection - ADB disappears, SSH over Wi-Fi does not.
#
# Secrets are read locally and piped straight into the board's stdin: never
# printed, never on a command line, never written to the board's disk.
#
#   .\scripts\run-on-board-ssh.ps1 -Script .\scripts\board-blink-slow.sh

param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$SecretsFile = "$env:USERPROFILE\.unoq-secrets.txt",
    [string]$BoardIp = "<BOARD-IP>",
    [string]$User    = "arduino",
    [string]$KeyPath = "$env:LOCALAPPDATA\Temp\claude\C--Users-dcuar-Documents-development-arduino-uno-q-screen\84a22c73-80fc-4720-9db5-768ebe4e2925\scratchpad\unoq_key"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $KeyPath))      { throw "ssh key not found: $KeyPath" }
if (-not (Test-Path $Script))       { throw "script not found: $Script" }
if (-not (Test-Path $SecretsFile))  { throw "secrets file not found: $SecretsFile" }

$known = Join-Path (Split-Path $KeyPath) "known_hosts"
$sshOpts = @(
    '-i', $KeyPath,
    '-o', 'StrictHostKeyChecking=no',
    '-o', "UserKnownHostsFile=$known",
    '-o', 'ConnectTimeout=20',
    '-o', 'BatchMode=yes'
)

# --- parse secrets (values never echoed) ---
$cfg = @{}
foreach ($line in Get-Content -LiteralPath $SecretsFile) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $cfg[$matches[1]] = $matches[2] }
}
foreach ($k in 'SUDO_PASS', 'WIFI_SSID', 'WIFI_PASS') {
    if (-not $cfg.ContainsKey($k) -or [string]::IsNullOrEmpty($cfg[$k])) {
        throw "Secrets file is missing a value for $k"
    }
}
Write-Output ("secrets loaded: SUDO_PASS ({0} chars), WIFI_SSID '{1}', WIFI_PASS ({2} chars)" -f `
    $cfg.SUDO_PASS.Length, $cfg.WIFI_SSID, $cfg.WIFI_PASS.Length)

# --- copy the script over ---
$remote = "/home/$User/" + (Split-Path $Script -Leaf)
Write-Output "copying $Script -> $remote"
& scp @sshOpts $Script "${User}@${BoardIp}:$remote" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "scp failed" }

# --- run it, secrets on stdin, LF endings ---
$payload = (($cfg.SUDO_PASS, $cfg.WIFI_SSID, $cfg.WIFI_PASS) -join "`n") + "`n"

Write-Output "running $remote ..."
Write-Output "----------------------------------------------------------------"
$payload | & ssh @sshOpts "${User}@${BoardIp}" "sh $remote"
Write-Output "----------------------------------------------------------------"
Write-Output "done."

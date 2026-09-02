# Pushes a shell script to the UNO Q over ADB and runs it, feeding the three
# secrets in on stdin.
#
# The secrets file is read here and piped directly into the board's stdin.
# It is never printed, never passed as a command-line argument, never written
# to the board's disk, and never enters the shell history on either side.
#
# Usage:
#   .\scripts\run-on-board.ps1 -Script .\scripts\board-stage1-wifi-aptupdate.sh
#   .\scripts\run-on-board.ps1 -Script .\scripts\board-stage2-upgrade.sh
#
# Secrets file default: C:\Users\<you>\.unoq-secrets.txt  (outside this repo)
# Format - three lines, keys exactly as shown:
#   SUDO_PASS=your-linux-password
#   WIFI_SSID=your-network-name
#   WIFI_PASS=your-wifi-password

param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$SecretsFile = "$env:USERPROFILE\.unoq-secrets.txt",
    [string]$Adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Adb))         { throw "adb not found at $Adb" }
if (-not (Test-Path $Script))      { throw "script not found: $Script" }
if (-not (Test-Path $SecretsFile)) {
    throw @"
Secrets file not found: $SecretsFile

Create it with three lines:
  SUDO_PASS=your-linux-password
  WIFI_SSID=your-network-name
  WIFI_PASS=your-wifi-password
"@
}

# --- parse secrets (values are never echoed) ---
$cfg = @{}
foreach ($line in Get-Content -LiteralPath $SecretsFile) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $cfg[$matches[1]] = $matches[2] }
}
foreach ($k in 'SUDO_PASS', 'WIFI_SSID', 'WIFI_PASS') {
    if (-not $cfg.ContainsKey($k) -or [string]::IsNullOrEmpty($cfg[$k])) {
        throw "Secrets file is missing a value for $k"
    }
}
# report only that they were found, never what they are
Write-Output ("secrets loaded: SUDO_PASS ({0} chars), WIFI_SSID '{1}', WIFI_PASS ({2} chars)" -f `
    $cfg.SUDO_PASS.Length, $cfg.WIFI_SSID, $cfg.WIFI_PASS.Length)

# --- push the script ---
$remote = "/home/arduino/" + (Split-Path $Script -Leaf)
Write-Output "pushing $Script -> $remote"
& $Adb push $Script $remote | Out-Null
& $Adb shell "chmod +x $remote"

# --- run it, secrets on stdin, LF line endings ---
$payload = ($cfg.SUDO_PASS, $cfg.WIFI_SSID, $cfg.WIFI_PASS) -join "`n"
$payload += "`n"

Write-Output "running $remote ..."
Write-Output "----------------------------------------------------------------"
$payload | & $Adb shell "sh $remote"
Write-Output "----------------------------------------------------------------"
Write-Output "done. (the script is left on the board at $remote and contains no secrets)"

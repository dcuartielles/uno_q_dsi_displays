# Same contract as run-on-board.ps1 / run-on-board-ssh.ps1, over ADB.
# Kept because Wi-Fi (and therefore SSH) drops out across power changes, while
# ADB comes back as soon as the USB-C cable is on the PC.
#
#   .\scripts\run-on-board-adb.ps1 -Script .\scripts\some-board-script.sh

param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$SecretsFile = "$env:USERPROFILE\.unoq-secrets.txt",
    [string]$Adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Adb))        { throw "adb not found at $Adb" }
if (-not (Test-Path $Script))     { throw "script not found: $Script" }
if (-not (Test-Path $SecretsFile)){ throw "secrets file not found: $SecretsFile" }

$cfg = @{}
foreach ($line in Get-Content -LiteralPath $SecretsFile) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $cfg[$matches[1]] = $matches[2] }
}
foreach ($k in 'SUDO_PASS','WIFI_SSID','WIFI_PASS') {
    if (-not $cfg.ContainsKey($k) -or [string]::IsNullOrEmpty($cfg[$k])) {
        throw "Secrets file is missing a value for $k"
    }
}
Write-Output ("secrets loaded: SUDO_PASS ({0} chars), WIFI_SSID '{1}', WIFI_PASS ({2} chars)" -f `
    $cfg.SUDO_PASS.Length, $cfg.WIFI_SSID, $cfg.WIFI_PASS.Length)

$remote = "/home/arduino/" + (Split-Path $Script -Leaf)
& $Adb push $Script $remote | Out-Null
& $Adb shell "chmod +x $remote"

$payload = (($cfg.SUDO_PASS, $cfg.WIFI_SSID, $cfg.WIFI_PASS) -join "`n") + "`n"
Write-Output "running $remote ..."
Write-Output "----------------------------------------------------------------"
$payload | & $Adb shell "sh $remote"
Write-Output "----------------------------------------------------------------"
Write-Output "done."

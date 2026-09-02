# Waits for the UNO Q to complete a FRESH boot (detected by a small uptime),
# then immediately runs the display check + colour test.
#
# Intended to be started BEFORE a power cycle, so the panel is exercised as soon
# as the board is up - useful when the panel's I2C is only healthy on some boots.

param(
    [string]$BoardIp  = "<BOARD-IP>",
    [string]$User     = "arduino",
    [int]$TimeoutSec  = 900,
    [int]$FreshBootSec = 120
)

$ErrorActionPreference = 'Continue'
$SC  = "$env:LOCALAPPDATA\Temp\claude\C--Users-dcuar-Documents-development-arduino-uno-q-screen\84a22c73-80fc-4720-9db5-768ebe4e2925\scratchpad"
$key = "$SC\unoq_key"
$P   = "C:\Users\dcuar\Documents\development\arduino\uno_q_screen"
$sshOpts = @('-i',$key,'-o','StrictHostKeyChecking=no','-o',"UserKnownHostsFile=$SC\known_hosts",
             '-o','ConnectTimeout=5','-o','BatchMode=yes')

Write-Output "watching $BoardIp for a fresh boot (uptime < ${FreshBootSec}s)..."
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$sawDown = $false
$fresh   = $false

while ((Get-Date) -lt $deadline) {
    $up = & ssh @sshOpts "$User@$BoardIp" "cut -d. -f1 /proc/uptime" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $up) {
        if (-not $sawDown) { Write-Output "  board is down (power off detected)" }
        $sawDown = $true
        Start-Sleep -Seconds 3
        continue
    }
    $uptime = 0
    [int]::TryParse(($up | Select-Object -First 1).Trim(), [ref]$uptime) | Out-Null
    if ($sawDown -and $uptime -lt $FreshBootSec) {
        Write-Output "  FRESH BOOT detected (uptime ${uptime}s)"
        $fresh = $true
        break
    }
    Start-Sleep -Seconds 3
}

if (-not $fresh) { Write-Output "no fresh boot seen within ${TimeoutSec}s"; exit 1 }

# let userspace settle a moment, then exercise the panel
Start-Sleep -Seconds 8
Write-Output "================ running display check ================"
& pwsh -NoProfile -ExecutionPolicy Bypass -File "$P\scripts\run-on-board-ssh.ps1" `
      -Script "$P\scripts\board-check-parity.sh"

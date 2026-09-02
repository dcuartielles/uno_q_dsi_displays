# Convenience wrapper: run a command on the UNO Q over SSH (key auth, no password).
#
# Set up 2026-09-01 so the board stays reachable when the USB-C cable is used for
# power rather than for a PC data connection. ADB needs the PC cable; this does not.
#
#   .\scripts\ssh-board.ps1 "uname -a"
#   .\scripts\ssh-board.ps1 -Script .\scripts\some-board-script.sh    (needs secrets for sudo)
#
# The private key lives in the session scratchpad, not in this repo.

param(
    [Parameter(Position = 0)][string]$Command = "uname -a",
    [string]$BoardIp = "<BOARD-IP>",
    [string]$User    = "arduino",
    [string]$KeyPath = "$env:LOCALAPPDATA\Temp\claude\C--Users-dcuar-Documents-development-arduino-uno-q-screen\84a22c73-80fc-4720-9db5-768ebe4e2925\scratchpad\unoq_key"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $KeyPath)) { throw "ssh key not found: $KeyPath" }
$known = Join-Path (Split-Path $KeyPath) "known_hosts"

ssh -i $KeyPath `
    -o StrictHostKeyChecking=no `
    -o UserKnownHostsFile=$known `
    -o ConnectTimeout=15 `
    -o BatchMode=yes `
    "$User@$BoardIp" $Command

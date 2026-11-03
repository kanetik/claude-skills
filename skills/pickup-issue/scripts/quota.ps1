#Requires -Version 7
param([string] $StateDir)

. (Join-Path $PSScriptRoot 'decide.ps1')
if (-not $StateDir) { $StateDir = Get-PickupStateDir }
$hold = Get-QuotaHold -Now (Get-Date) -RateLimits (Read-RateLimits $StateDir)
if ($hold) { $hold; exit 1 }

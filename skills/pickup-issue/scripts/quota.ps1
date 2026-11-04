#Requires -Version 7
param([string] $StateDir)

. (Join-Path $PSScriptRoot 'decide.ps1')
if (-not $StateDir) { $StateDir = Get-PickupStateDir }
$now = Get-Date
$rateLimits = Read-RateLimits $StateDir
if (-not $rateLimits) { 'usage not checked: no readable usage.json'; exit 0 }
$hold = Get-QuotaHold -Now $now -RateLimits $rateLimits
if ($hold) { $hold; exit 1 }

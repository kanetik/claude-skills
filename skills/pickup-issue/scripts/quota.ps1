#Requires -Version 7
param([string] $StateDir)

. (Join-Path $PSScriptRoot 'decide.ps1')
if (-not $StateDir) { $StateDir = Get-PickupStateDir }
$now = Get-Date
$rateLimits = Read-RateLimits $StateDir $now
if (-not $rateLimits) { "usage not checked: no usage.json written in the last $($usageMaxAge.TotalMinutes) minutes"; exit 0 }
$hold = Get-QuotaHold -Now $now -RateLimits $rateLimits
if ($hold) { $hold; exit 1 }

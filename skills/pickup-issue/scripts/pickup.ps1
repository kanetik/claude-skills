#Requires -Version 7
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory)][string] $RepoDir,
    [Parameter(ParameterSetName = 'Run')][Parameter(ParameterSetName = 'Register')][string] $NightlyAt = '01:00',
    [Parameter(ParameterSetName = 'Register', Mandatory)][switch] $Register,
    [Parameter(ParameterSetName = 'Register')][int] $PollMinutes = 15,
    [Parameter(ParameterSetName = 'Unregister', Mandatory)][switch] $Unregister,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'decide.ps1')

$RepoDir = (Resolve-Path -LiteralPath $RepoDir).ProviderPath
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir '.git'))) { throw "$RepoDir is not a git checkout." }
$name = Split-Path -Leaf $RepoDir
$taskPath = '\pickup-issue\'
$taskName = "$name pickup"
$stateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'pickup-issue'
$launchStamp = Join-Path $stateDir "$name.last-launch"
$nightlyStamp = Join-Path $stateDir "$name.last-nightly"
$usageFile = Join-Path $stateDir 'usage.json'

function Get-Exe([string] $cmd) {
    $c = Get-Command $cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { throw "$cmd not found on PATH." }
    $c.Source
}

if ($Register) {
    $pwsh = Get-Exe 'pwsh'
    $taskArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$PSCommandPath`" -RepoDir `"$RepoDir`" -NightlyAt $NightlyAt"
    if ($DryRun) { "register $taskPath${taskName} every $PollMinutes min: $pwsh $taskArgs"; return }
    # One task, so Task Scheduler's IgnoreNew is what keeps two launches from ever running at once.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $PollMinutes)
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $taskArgs -WorkingDirectory $RepoDir
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    "registered $taskPath$taskName"
    return
}

if ($Unregister) {
    if ($DryRun) { "unregister $taskPath$taskName"; return }
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    "unregistered $taskPath$taskName"
    return
}

$claude = Get-Exe 'claude'
$claudeArgs = @('--bg', '--permission-mode', 'auto', '/pickup-issue')
if ($DryRun) { "launch in ${RepoDir}: $claude $($claudeArgs -join ' ')"; return }

$lastLaunch = if (Test-Path -LiteralPath $launchStamp) { (Get-Item -LiteralPath $launchStamp).LastWriteTime } else { $null }
$lastNightly = if (Test-Path -LiteralPath $nightlyStamp) { (Get-Content -LiteralPath $nightlyStamp -Raw).Trim() } else { '' }
$hasGo = {
    Push-Location $RepoDir
    try {
        $n = gh issue list --state open --label agent-go --json number --jq length
        if ($LASTEXITCODE -ne 0) { throw 'gh issue list failed.' }
        [int]$n -gt 0
    } finally { Pop-Location }
}
$now = Get-Date
$reason = Get-LaunchReason -Now $now -NightlyAt ([timespan]::Parse($NightlyAt)) -LastNightlyDate $lastNightly -LastLaunch $lastLaunch -HasGoIssue $hasGo
if (-not $reason) { return }
$rateLimits = if (Test-Path -LiteralPath $usageFile) { try { Get-Content -LiteralPath $usageFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
if (Get-QuotaHold -Now $now -RateLimits $rateLimits) { return }

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
Set-Content -LiteralPath $launchStamp -Value ($now.ToString('o'))
if ($reason -eq 'nightly') { Set-Content -LiteralPath $nightlyStamp -Value ($now.ToString('yyyy-MM-dd')) }
Push-Location $RepoDir
try { & $claude @claudeArgs } finally { Pop-Location }

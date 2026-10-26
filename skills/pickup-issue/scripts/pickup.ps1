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

function Get-Exe([string] $cmd) {
    $c = Get-Command $cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { throw "$cmd not found on PATH." }
    $c.Source
}

if ($Register) {
    $pwsh = Get-Exe 'pwsh'
    # conhost --headless: a console program started directly by the task flashes a window on every poll.
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $taskArgs = "--headless `"$pwsh`" -NoProfile -NonInteractive -File `"$PSCommandPath`" -RepoDir `"$RepoDir`" -NightlyAt $NightlyAt"
    if ($DryRun) { "register $taskPath${taskName} every $PollMinutes min: $conhost $taskArgs"; return }
    # One task, so Task Scheduler's IgnoreNew is what keeps two launches from ever running at once.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $PollMinutes)
    $action = New-ScheduledTaskAction -Execute $conhost -Argument $taskArgs -WorkingDirectory $RepoDir
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
$launchArgs = { param($reason) @('--bg', '--permission-mode', 'auto', '--name', (Get-SessionName $name $reason (Get-Date)), '/pickup-issue') }
if ($DryRun) { "launch in ${RepoDir}: $claude $((& $launchArgs 'nightly') -join ' ')"; return }

$hasGo = {
    Push-Location $RepoDir
    try {
        $n = gh issue list --state open --label agent-go --json number --jq length
        if ($LASTEXITCODE -ne 0) { throw 'gh issue list failed.' }
        [int]$n -gt 0
    } finally { Pop-Location }
}
$reason = Resolve-Launch -Now (Get-Date) -StateDir $stateDir -Name $name -NightlyAt ([timespan]::Parse($NightlyAt)) -HasGoIssue $hasGo
if (-not $reason) { return }
$claudeArgs = & $launchArgs $reason
Push-Location $RepoDir
try { & $claude @claudeArgs } finally { Pop-Location }

#Requires -Version 7
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory)][string] $RepoDir,
    [Parameter(ParameterSetName = 'Run')][switch] $OnlyIfGo,
    [Parameter(ParameterSetName = 'Register', Mandatory)][switch] $Register,
    [Parameter(ParameterSetName = 'Register')][string] $NightlyAt = '01:00',
    [Parameter(ParameterSetName = 'Register')][int] $PollMinutes = 15,
    [Parameter(ParameterSetName = 'Unregister', Mandatory)][switch] $Unregister,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoDir = (Resolve-Path -LiteralPath $RepoDir).ProviderPath
if (-not (Test-Path -LiteralPath (Join-Path $RepoDir '.git'))) { throw "$RepoDir is not a git checkout." }
$name = Split-Path -Leaf $RepoDir
$taskPath = '\pickup-issue\'
$stateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'pickup-issue'
$stamp = Join-Path $stateDir "$name.last-launch"
# A run normally claims its issue within minutes; this stops the poller relaunching while it does.
$relaunchGuard = [TimeSpan]::FromMinutes(30)

function Get-Exe([string] $cmd) {
    $c = Get-Command $cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { throw "$cmd not found on PATH." }
    $c.Source
}

function Test-GoIssue {
    Push-Location $RepoDir
    try {
        $n = gh issue list --state open --label agent-go --json number --jq length
        if ($LASTEXITCODE -ne 0) { throw 'gh issue list failed.' }
        [int]$n -gt 0
    } finally { Pop-Location }
}

if ($Register) {
    $pwsh = Get-Exe 'pwsh'
    $self = $PSCommandPath
    $base = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$self`" -RepoDir `"$RepoDir`""
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $tasks = @(
        @{ Name = "$name nightly"; Args = $base; Trigger = New-ScheduledTaskTrigger -Daily -At $NightlyAt }
        @{ Name = "$name agent-go"; Args = "$base -OnlyIfGo"
           Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $PollMinutes) }
    )
    foreach ($t in $tasks) {
        if ($DryRun) { "register $taskPath$($t.Name): $pwsh $($t.Args)"; continue }
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument $t.Args -WorkingDirectory $RepoDir
        Register-ScheduledTask -TaskPath $taskPath -TaskName $t.Name -Action $action -Trigger $t.Trigger -Settings $settings -Force | Out-Null
        "registered $taskPath$($t.Name)"
    }
    return
}

if ($Unregister) {
    foreach ($t in "$name nightly", "$name agent-go") {
        if ($DryRun) { "unregister $taskPath$t"; continue }
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        "unregistered $taskPath$t"
    }
    return
}

if ($OnlyIfGo) {
    if ((Test-Path -LiteralPath $stamp) -and ((Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime) -lt $relaunchGuard) { return }
    if (-not (Test-GoIssue)) { return }
}

$claude = Get-Exe 'claude'
$claudeArgs = @('--bg', '--permission-mode', 'auto', '/pickup-issue')
if ($DryRun) { "launch in ${RepoDir}: $claude $($claudeArgs -join ' ')"; return }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
Set-Content -LiteralPath $stamp -Value (Get-Date -Format o)
Push-Location $RepoDir
try { & $claude @claudeArgs } finally { Pop-Location }

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
$stateDir = Get-PickupStateDir

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
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
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
$launchArgs = {
    param($reason, $chosen)
    $prompt = if ($chosen) { "/pickup-issue chosen $($chosen.Number)" } else { '/pickup-issue' }
    @('--bg', '--permission-mode', 'auto', '--name', (Get-SessionName $name $reason (Get-Date) $chosen), $prompt)
}
if ($DryRun) { "launch in ${RepoDir}: $claude $((& $launchArgs 'nightly') -join ' ')"; return }

$hasGo = {
    Push-Location $RepoDir
    try {
        $n = gh issue list --state open --label agent-go --json number --jq length
        if ($LASTEXITCODE -ne 0) { throw 'gh issue list failed.' }
        [int]$n -gt 0
    } finally { Pop-Location }
}
$repoState = {
    $PSNativeCommandUseErrorActionPreference = $true
    $repo = gh repo view --json nameWithOwner --jq .nameWithOwner
    $issues = @{}
    foreach ($q in 'per_page=100&page=1', 'per_page=100&page=2', 'labels=agent-go&per_page=100') {
        gh api "repos/$repo/issues?state=open&$q" --jq '.[] | select(has("pull_request") | not) | {number, title, body, created_at, author: .user.login, author_type: .user.type, labels: [.labels[].name], assignees: [.assignees[].login], blocked_by: .issue_dependencies_summary.blocked_by}' |
            ConvertFrom-Json | ForEach-Object { $issues[$_.number] = $_ }
    }
    foreach ($i in $issues.Values) {
        if ($i.labels -contains 'agent-go') {
            $i | Add-Member agent_go_last_added_by (gh api "repos/$repo/issues/$($i.number)/timeline" --paginate --jq '.[] | select(.event == "labeled" and .label.name == "agent-go") | {login: .actor.login, type: .actor.type}' | Select-Object -Last 1 | ConvertFrom-Json)
        }
        if ($i.labels -contains 'agent-pickup') {
            $i | Add-Member last_claim_comment_at (gh api "repos/$repo/issues/$($i.number)/comments" --paginate --jq '.[] | select(.body | startswith("Claimed by an automated pickup run.")) | .created_at' | Select-Object -Last 1)
        }
    }
    $triage = Join-Path $RepoDir 'docs/agents/triage-labels.md'
    [ordered]@{
        repository = $repo
        today = (Get-Date).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
        now_utc = (Get-Date).ToUniversalTime().ToString('o')
        collaborators = @(gh api "repos/$repo/collaborators" --paginate --jq '.[] | {login, permission: .role_name}' | ConvertFrom-Json)
        agent_prs = @(gh pr list --state all --label agent-pickup --limit 200 --json number,state,mergedAt,createdAt,body,labels --jq '.[] | .body |= ((. // "") | split("\n")[0]) | .labels |= map(.name)' | ConvertFrom-Json)
        triage_labels_md = if (Test-Path -LiteralPath $triage) { Get-Content -LiteralPath $triage -Raw }
        open_issues = @($issues.Values | Sort-Object number)
    } | ConvertTo-Json -Depth 6
}
$now = Get-Date
$reason = Resolve-Launch -Now $now -StateDir $stateDir -Name $name -NightlyAt ([timespan]::Parse($NightlyAt)) -HasGoIssue $hasGo
if (-not $reason) { return }
Push-Location $RepoDir
try {
    # A running session cannot rename itself, so the name's issue is picked before launch.
    $chooseError = $null
    $chosen = try { Read-ChosenIssue ((& $repoState) | & $claude -p --model haiku --permission-mode dontAsk --strict-mcp-config '--tools=' '/pickup-issue choose-only' 2>$null) } catch { $chooseError = "choose-only failed: $_"; $null }
    if (-not $chooseError -and $LASTEXITCODE) { $chooseError = "choose-only exited $LASTEXITCODE"; $chosen = $null }
    if ($chosen -and $chosen.Number -eq 0) {
        Add-Content -LiteralPath (Join-Path $stateDir "$name.log") -Value "$($now.ToString('o')) $reason PICKUP none`n"
        Complete-Launch -Now $now -StateDir $stateDir -Name $name -Reason $reason
        return
    }
    $claudeArgs = & $launchArgs $reason $chosen
    $sessionName = $claudeArgs[$claudeArgs.IndexOf('--name') + 1]
    $out = & $claude @claudeArgs 2>&1 | Out-String
    $exit = $LASTEXITCODE
    $started = $exit -eq 0 -and (Test-SessionStarted (& $claude agents --json 2>$null | Out-String) $sessionName)
} finally { Pop-Location }
$hint = if (-not $started) { Get-LaunchFailureHint $out }
Add-Content -LiteralPath (Join-Path $stateDir "$name.log") -Value "$($now.ToString('o')) $reason exit=$exit started=$started`n$(if ($chooseError) { "$chooseError`n" })$($out.TrimEnd())`n$(if ($hint) { "$hint`n" })"
if (-not $started) { throw "launch of '$sessionName' failed (exit $exit). $hint See $(Join-Path $stateDir "$name.log")" }
Complete-Launch -Now $now -StateDir $stateDir -Name $name -Reason $reason

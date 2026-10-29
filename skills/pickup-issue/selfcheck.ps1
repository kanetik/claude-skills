#Requires -Version 7
# Self-check for scripts/pickup.ps1 and scripts/decide.ps1. Run it directly: pwsh selfcheck.ps1
# Every pickup.ps1 case uses -DryRun, so nothing is registered and no session starts.

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'scripts/pickup.ps1'
. (Join-Path $PSScriptRoot 'scripts/decide.ps1')
$fails = 0
function Check([string] $label, [bool] $ok, [string] $detail = '') {
    if ($ok) { "ok   $label" } else { "FAIL $label`n     $detail"; $script:fails++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "pickup-selfcheck-$PID"
$repo = Join-Path $tmp 'demo-repo'
New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git') | Out-Null
try {
    foreach ($f in $script, (Join-Path $PSScriptRoot 'scripts/decide.ps1')) {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
        Check "parses: $(Split-Path -Leaf $f)" ($errs.Count -eq 0) ($errs -join '; ')
    }

    $out = (& $script -RepoDir $repo -Register -NightlyAt '03:00' -DryRun) -join "`n"
    Check 'register makes exactly one task, named after the repo folder' (([regex]::Matches($out, 'register ')).Count -eq 1 -and $out -match 'demo-repo pickup') $out
    Check 'the task carries the nightly time' ($out -match '-NightlyAt 03:00') $out
    Check 'the task is never registered elevated' ((Get-Content $script -Raw) -notmatch 'RunLevel\s+Highest') 'an elevated task runs user-writable scripts with admin rights'

    $out = (& $script -RepoDir $repo -Unregister -DryRun) -join "`n"
    Check 'unregister names the task' ($out -match 'demo-repo pickup') $out

    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $out = (& $script -RepoDir $repo -DryRun) -join "`n"
        Check 'launch is a background auto-mode pickup' ($out -match '--bg --permission-mode auto --name demo-repo pickup \(nightly, .+\) /pickup-issue') $out
    } else { 'skip launch case: claude not on PATH' }

    $notRepo = Join-Path $tmp 'plain'
    New-Item -ItemType Directory -Force -Path $notRepo | Out-Null
    $msg = ''
    try { & $script -RepoDir $notRepo -Unregister -DryRun | Out-Null } catch { $msg = "$_" }
    Check 'refuses a folder that is not a git checkout' ($msg -match 'not a git checkout') $msg

    # Get-LaunchReason
    $at = [timespan]'01:00'
    $no = { $false }; $yes = { $true }
    $boom = { throw 'go query must not run' }
    $d = [datetime]'2026-10-25 01:07'
    Check 'nightly due after the time, not yet run today' ((Get-LaunchReason -Now $d -NightlyAt $at -LastNightlyDate '2026-10-24' -HasGoIssue $boom) -eq 'nightly')
    Check 'nightly not repeated the same day' ($null -eq (Get-LaunchReason -Now $d -NightlyAt $at -LastNightlyDate '2026-10-25' -HasGoIssue $no))
    Check 'nightly not due before the time' ($null -eq (Get-LaunchReason -Now ([datetime]'2026-10-25 00:52') -NightlyAt $at -LastNightlyDate '2026-10-24' -HasGoIssue $no))
    Check 'agent-go launches when nightly is not due' ((Get-LaunchReason -Now ([datetime]'2026-10-25 00:52') -NightlyAt $at -LastNightlyDate '2026-10-24' -HasGoIssue $yes) -eq 'go')
    Check 'nothing within 30 minutes of the last launch' ($null -eq (Get-LaunchReason -Now $d -NightlyAt $at -LastNightlyDate '2026-10-24' -LastLaunch ([datetime]'2026-10-25 00:52') -HasGoIssue $boom))
    Check 'a nightly suppressed by the guard runs on a later poll' ((Get-LaunchReason -Now ([datetime]'2026-10-25 01:22') -NightlyAt $at -LastNightlyDate '2026-10-24' -LastLaunch ([datetime]'2026-10-25 00:52') -HasGoIssue $no) -eq 'nightly')

    # Get-FiveHourCap / Get-QuotaHold. 2026-10-26 is a Monday, 2026-10-24 a Saturday.
    $mon = [datetime]'2026-10-26 10:00'; $monLate = [datetime]'2026-10-26 19:00'; $monEarly = [datetime]'2026-10-26 00:30'; $sat = [datetime]'2026-10-24 10:00'
    Check 'weekday daytime cap is 30' ((Get-FiveHourCap $mon) -eq 30)
    Check 'weekday evening cap is 50' ((Get-FiveHourCap $monLate) -eq 50)
    Check 'weekday before 01:00 cap is 50' ((Get-FiveHourCap $monEarly) -eq 50)
    Check 'weekend cap is 50' ((Get-FiveHourCap $sat) -eq 50)
    $future = [DateTimeOffset]::new($mon).AddHours(2).ToUnixTimeSeconds()
    $past = [DateTimeOffset]::new($mon).AddHours(-1).ToUnixTimeSeconds()
    $rl = { param($fh, $fhr, $sd, $sdr) [pscustomobject]@{ five_hour = [pscustomobject]@{ used_percentage = $fh; resets_at = $fhr }; seven_day = [pscustomobject]@{ used_percentage = $sd; resets_at = $sdr } } }
    Check 'no reading allows a launch' ($null -eq (Get-QuotaHold -Now $mon -RateLimits $null))
    Check 'weekday 35% five-hour holds' ($null -ne (Get-QuotaHold -Now $mon -RateLimits (& $rl 35 $future 10 $future)))
    Check 'evening 35% five-hour allows' ($null -eq (Get-QuotaHold -Now $monLate -RateLimits (& $rl 35 ([DateTimeOffset]::new($monLate).AddHours(2).ToUnixTimeSeconds()) 10 $future)))
    Check 'weekly 70% holds' ($null -ne (Get-QuotaHold -Now $mon -RateLimits (& $rl 5 $future 70 $future)))
    Check 'a window past its reset does not hold' ($null -eq (Get-QuotaHold -Now $mon -RateLimits (& $rl 90 $past 10 $future)))
    # Resolve-Launch: the composed decision pickup.ps1 runs, against a scratch state directory.
    $state = Join-Path $tmp 'state'
    $over = (& $rl 40 $future 10 $future) | ConvertTo-Json -Compress
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    Set-Content (Join-Path $state 'usage.json') $over
    Check 'over the cap: no launch' ($null -eq (Resolve-Launch -Now $mon -StateDir $state -Name demo -NightlyAt $at -HasGoIssue $no))
    Check 'a held nightly writes no stamps' (-not (Test-Path (Join-Path $state 'demo.last-nightly')) -and -not (Test-Path (Join-Path $state 'demo.last-launch')))
    Remove-Item (Join-Path $state 'usage.json')
    Check 'no usage file: nightly launches' ((Resolve-Launch -Now $mon -StateDir $state -Name demo -NightlyAt $at -HasGoIssue $no) -eq 'nightly')
    Check 'deciding to launch does not mark the nightly done' (-not (Test-Path (Join-Path $state 'demo.last-nightly')))
    Check 'a nightly whose launch failed is retried after the guard' ((Resolve-Launch -Now $mon.AddMinutes(31) -StateDir $state -Name demo -NightlyAt $at -HasGoIssue $no) -eq 'nightly')
    Complete-Launch -Now $mon -StateDir $state -Name demo -Reason 'go'
    Check 'a completed agent-go launch does not mark the nightly done' (-not (Test-Path (Join-Path $state 'demo.last-nightly')))
    Complete-Launch -Now $mon -StateDir $state -Name demo -Reason 'nightly'
    Check 'a completed nightly launch stamps the date' ((Get-Content (Join-Path $state 'demo.last-nightly') -Raw).Trim() -eq '2026-10-26')
    Check 'a completed nightly is not repeated the same day' ($null -eq (Resolve-Launch -Now $mon.AddMinutes(62) -StateDir $state -Name demo -NightlyAt $at -HasGoIssue $no))
    $agents = '[{"pid":1,"kind":"interactive","name":"other"},{"id":"ab12","kind":"background","name":"wakey pickup (nightly, Oct 26 01:00)"},{"pid":2,"kind":"interactive"}]'
    Check 'the launched session is found by name' (Test-SessionStarted $agents 'wakey pickup (nightly, Oct 26 01:00)')
    Check 'a session that never registered is a failed launch' (-not (Test-SessionStarted $agents 'wakey pickup (nightly, Oct 27 01:00)'))
    Check 'unreadable agents output is a failed launch' (-not (Test-SessionStarted 'not json' 'x'))
    Set-Content (Join-Path $state 'demo.last-launch') ''
    Check 'an empty launch stamp does not stop the decision' ($null -ne (Resolve-Launch -Now $mon.AddDays(1) -StateDir $state -Name demo -NightlyAt $at -HasGoIssue $no))
    Check 'a second poll within 30 minutes does not launch' ($null -eq (Resolve-Launch -Now $mon.AddMinutes(15) -StateDir $state -Name demo -NightlyAt $at -HasGoIssue $yes))
    Check 'session name says which trigger launched it' ((Get-SessionName 'wakey' 'go' ([datetime]'2026-10-25 21:30')) -eq 'wakey pickup (agent-go, Oct 25 21:30)')
    Check 'session name for a nightly run' ((Get-SessionName 'wakey' 'nightly' ([datetime]'2026-10-26 01:15')) -eq 'wakey pickup (nightly, Oct 26 01:15)')
    Check 'a missing window does not hold' ($null -eq (Get-QuotaHold -Now $mon -RateLimits ([pscustomobject]@{ seven_day = [pscustomobject]@{ used_percentage = 10; resets_at = $future } })))
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($fails) { "$fails failed"; exit 1 } else { 'all passed' }

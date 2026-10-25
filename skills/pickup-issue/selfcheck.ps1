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

    $out = (& $script -RepoDir $repo -Unregister -DryRun) -join "`n"
    Check 'unregister names the task' ($out -match 'demo-repo pickup') $out

    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $out = (& $script -RepoDir $repo -DryRun) -join "`n"
        Check 'launch is a background auto-mode pickup' ($out -match '--bg --permission-mode auto /pickup-issue') $out
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
    Check 'a missing window does not hold' ($null -eq (Get-QuotaHold -Now $mon -RateLimits ([pscustomobject]@{ seven_day = [pscustomobject]@{ used_percentage = 10; resets_at = $future } })))
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($fails) { "$fails failed"; exit 1 } else { 'all passed' }

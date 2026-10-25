#Requires -Version 7
# Self-check for scripts/pickup.ps1. Run it directly: pwsh selfcheck.ps1
# Every case uses -DryRun, so nothing is registered and no session starts.

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'scripts/pickup.ps1'
$fails = 0
function Check([string] $label, [bool] $ok, [string] $detail = '') {
    if ($ok) { "ok   $label" } else { "FAIL $label`n     $detail"; $script:fails++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "pickup-selfcheck-$PID"
$repo = Join-Path $tmp 'demo-repo'
New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git') | Out-Null
try {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errs)
    Check 'parses' ($errs.Count -eq 0) ($errs -join '; ')

    $out = (& $script -RepoDir $repo -Register -NightlyAt '03:00' -DryRun) -join "`n"
    Check 'register names both tasks after the repo folder' ($out -match 'demo-repo nightly' -and $out -match 'demo-repo agent-go') $out
    Check 'poll task passes -OnlyIfGo' ($out -match 'agent-go:.*-OnlyIfGo') $out
    Check 'nightly task does not pass -OnlyIfGo' (-not ($out -match 'nightly:.*-OnlyIfGo')) $out

    $out = (& $script -RepoDir $repo -Unregister -DryRun) -join "`n"
    Check 'unregister names both tasks' ($out -match 'demo-repo nightly' -and $out -match 'demo-repo agent-go') $out

    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $out = (& $script -RepoDir $repo -DryRun) -join "`n"
        Check 'launch is a background auto-mode pickup' ($out -match '--bg --permission-mode auto /pickup-issue') $out
    } else { 'skip launch case: claude not on PATH' }

    $notRepo = Join-Path $tmp 'plain'
    New-Item -ItemType Directory -Force -Path $notRepo | Out-Null
    $threw = $false
    try { & $script -RepoDir $notRepo -DryRun | Out-Null } catch { $threw = $true }
    Check 'refuses a folder that is not a git checkout' $threw
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($fails) { "$fails failed"; exit 1 } else { 'all passed' }

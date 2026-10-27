function Get-LaunchReason {
    param(
        [Parameter(Mandatory)][datetime] $Now,
        [Parameter(Mandatory)][timespan] $NightlyAt,
        [string] $LastNightlyDate,
        [Nullable[datetime]] $LastLaunch,
        [timespan] $Guard = [TimeSpan]::FromMinutes(30),
        [Parameter(Mandatory)][scriptblock] $HasGoIssue
    )
    if ($null -ne $LastLaunch -and ($Now - $LastLaunch) -lt $Guard) { return $null }
    if ($Now.TimeOfDay -ge $NightlyAt -and $LastNightlyDate -ne $Now.ToString('yyyy-MM-dd')) { return 'nightly' }
    if (& $HasGoIssue) { return 'go' }
    $null
}

function Resolve-Launch {
    param(
        [Parameter(Mandatory)][datetime] $Now,
        [Parameter(Mandatory)][string] $StateDir,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][timespan] $NightlyAt,
        [Parameter(Mandatory)][scriptblock] $HasGoIssue
    )
    $launchStamp = Join-Path $StateDir "$Name.last-launch"
    $nightlyStamp = Join-Path $StateDir "$Name.last-nightly"
    $usageFile = Join-Path $StateDir 'usage.json'
    $lastLaunch = try { [datetime]::Parse((Get-Content -LiteralPath $launchStamp -Raw -ErrorAction Stop).Trim()) } catch { $null }
    $lastNightly = try { (Get-Content -LiteralPath $nightlyStamp -Raw -ErrorAction Stop).Trim() } catch { '' }
    $reason = Get-LaunchReason -Now $Now -NightlyAt $NightlyAt -LastNightlyDate $lastNightly -LastLaunch $lastLaunch -HasGoIssue $HasGoIssue
    if (-not $reason) { return $null }
    $rateLimits = if (Test-Path -LiteralPath $usageFile) { try { Get-Content -LiteralPath $usageFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
    if (Get-QuotaHold -Now $Now -RateLimits $rateLimits) { return $null }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Set-Content -LiteralPath $launchStamp -Value ($Now.ToString('o'))
    if ($reason -eq 'nightly') { Set-Content -LiteralPath $nightlyStamp -Value ($Now.ToString('yyyy-MM-dd')) }
    $reason
}

function Get-SessionName([string] $Name, [string] $Reason, [datetime] $Now, $Chosen) {
    $label = if ($Reason -eq 'go') { 'agent-go' } else { $Reason }
    $subject = if ($Chosen) { "#$($Chosen.Number) $($Chosen.Title)" } else { 'pickup' }
    "$Name $subject ($label, $($Now.ToString('MMM d HH:mm', [cultureinfo]::InvariantCulture)))"
}

function Read-ChosenIssue([string[]] $Lines) {
    $line = @($Lines | Where-Object { $_ -match '^\s*PICKUP\s+(none|#?\d+\s+\S.*)\s*$' })[-1]
    if (-not $line) { return $null }
    if ($line -match '^\s*PICKUP\s+none') { return [pscustomobject]@{ Number = 0; Title = '' } }
    $null = $line -match '^\s*PICKUP\s+#?(\d+)\s+(.+?)\s*$'
    # Model-written from outside issue text.
    $title = (($Matches[2] -replace '[^\p{L}\p{N} \-]', ' ') -replace '\s+', ' ').Trim()
    if ($title.Length -gt 40) { $title = $title.Substring(0, 40).Trim() }
    [pscustomobject]@{ Number = [int]$Matches[1]; Title = $title }
}

function Get-FiveHourCap([datetime] $Now, [int] $Workday = 30, [int] $Otherwise = 50) {
    $weekday = $Now.DayOfWeek -notin 'Saturday', 'Sunday'
    if ($weekday -and $Now.Hour -ge 1 -and $Now.Hour -lt 18) { $Workday } else { $Otherwise }
}

function Get-QuotaHold {
    param(
        [Parameter(Mandatory)][datetime] $Now,
        $RateLimits,
        [int] $WeeklyCap = 70
    )
    if ($null -eq $RateLimits) { return $null }
    $epoch = [DateTimeOffset]::new($Now).ToUnixTimeSeconds()
    $caps = @{ five_hour = (Get-FiveHourCap $Now); seven_day = $WeeklyCap }
    foreach ($window in 'five_hour', 'seven_day') {
        $w = $RateLimits.PSObject.Properties[$window]
        if (-not $w -or $null -eq $w.Value) { continue }
        $resets = $w.Value.PSObject.Properties['resets_at']
        if ($resets -and [double]$resets.Value -le $epoch) { continue }
        $used = $w.Value.PSObject.Properties['used_percentage']
        if ($used -and [double]$used.Value -ge $caps[$window]) { return "$window at $([double]$used.Value)% (cap $($caps[$window])%)" }
    }
    $null
}

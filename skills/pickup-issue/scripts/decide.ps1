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

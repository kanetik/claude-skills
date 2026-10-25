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

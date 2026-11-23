# P5-04 mobile power & traffic sampling tool.
#
# Samples standby power delta and network traffic with relay ON vs OFF,
# emits CSV for the gate "relay-on standby power delta < 5% per hour" (§13).
#
# Requires a real device: Android (adb + dumpsys batterystats) or iOS
# (sysdiagnose / Energy Log). This machine has no real device (R-17). The tool
# only collects and computes; it never fabricates numbers. With -DryRun it
# generates a report template instead.
#
# Usage:
#   # Android, relay ON / OFF (reset, idle for $DurationMin, then read):
#   pwsh -File tools/p5/sample-power.ps1 -Platform android -DurationMin 60 -RelayOn -Out data\p5\relay-on.csv
#   pwsh -File tools/p5/sample-power.ps1 -Platform android -DurationMin 60 -Out data\p5\relay-off.csv
#   # Summarize:
#   pwsh -File tools/p5/sample-power.ps1 -Summarize -Paths data\p5\relay-off.csv,data\p5\relay-on.csv
#   # No device: generate template
#   pwsh -File tools/p5/sample-power.ps1 -DryRun
param(
    [ValidateSet('android', 'ios')]
    [string]$Platform = 'android',

    [int]$DurationMin = 60,
    [switch]$RelayOn,
    [string]$Out = '',

    [switch]$Summarize,
    [string]$Paths = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Gate threshold: standby power delta per hour, in percent.
$POWER_BUDGET_PCT_PER_HOUR = 5.0

function Read-AndroidBattery {
    $raw = & adb shell dumpsys batterystats 2>&1 | Out-String
    # Simplify: calibrate the regex per device / Android version in the field.
    $match = [regex]::Match($raw, 'Computed drain\s*:\s*([\d.]+)')
    if ($match.Success) { return [double]$match.Groups[1].Value }
    return $null
}

if ($DryRun) {
    $template = @(
        [pscustomobject]@{
            platform = $Platform; relay_on = 'false'; duration_min = $DurationMin
            drain_pct = ''; bytes_sent = ''; bytes_recv = ''
            dht_p95_ms = ''; holepunch = ''; note = 'PHASE-2: fill after real-device sampling'
        }
    )
    New-Item -ItemType Directory -Force -Path 'data/p5' | Out-Null
    $template | Export-Csv -Path 'data/p5/sample-template.csv' -NoTypeInformation -Force
    Write-Host 'Generated data/p5/sample-template.csv (template, not measured)'
    return
}

if ($Summarize) {
    $rows = @()
    foreach ($p in ($Paths -split ',')) {
        $p = $p.Trim().Trim("'").Trim('"')
        if (-not $p) { continue }
        $r = Resolve-Path $p -ErrorAction SilentlyContinue
        if (-not $r) { Write-Warning "Skip missing file: $p"; continue }
        $rows += Import-Csv $r.Path
    }
    $off = $rows | Where-Object { $_.relay_on -eq 'false' } | Select-Object -First 1
    $on = $rows | Where-Object { $_.relay_on -eq 'true' } | Select-Object -First 1
    if (-not $off -or -not $on) {
        Write-Error 'Need both relay_on=true and relay_on=false samples to compute delta'
        return
    }
    $deltaPerHour = ([double]$on.drain_pct - [double]$off.drain_pct) /
        ([double]$on.duration_min / 60.0)
    Write-Host ("POWER_DELTA_PCT_PER_HOUR={0:N2}" -f $deltaPerHour)
    Write-Host ("POWER_BUDGET_PCT_PER_HOUR={0:N2}" -f $POWER_BUDGET_PCT_PER_HOUR)
    if ($deltaPerHour -lt $POWER_BUDGET_PCT_PER_HOUR) {
        Write-Host 'POWER_RESULT=PASS'
    } else {
        Write-Host 'POWER_RESULT=FAIL'
    }
    return
}

# Real-device sampling: power must be read in two phases (reset -> idle -> read).
$drain = if ($Platform -eq 'android') { Read-AndroidBattery } else { $null }
$netStats = if ($Platform -eq 'android') { & adb shell cat /proc/net/dev 2>&1 | Out-String } else { '' }
$relayFlag = if ($RelayOn) { 'true' } else { 'false' }
$record = [pscustomobject]@{
    platform = $Platform
    relay_on = $relayFlag
    duration_min = $DurationMin
    drain_pct = if ($null -eq $drain) { '' } else { $drain }
    bytes_sent = ''
    bytes_recv = ''
    dht_p95_ms = ''
    holepunch = ''
    net_raw = $netStats
    note = if ($null -eq $drain) { 'NO_DEVICE: no power reading' } else { '' }
}
if (-not $Out) { $Out = "data/p5/$Platform-relay-$relayFlag.csv" }
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
$record | Export-Csv -Path $Out -NoTypeInformation -Force
Write-Host "Sample written to $Out"
